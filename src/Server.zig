const std = @import("std");
const c = @import("c.zig").c;
const Stream = @import("Stream.zig").Stream;
const posix = std.posix;
const protocol = @import("protocol.zig");
const loop_mod = @import("loop.zig");
pub const Loop = loop_mod.Loop;
const WorkspaceManager = @import("WorkspaceManager.zig");
const Workspace = @import("Workspace.zig");
const Pane = @import("Pane.zig");
const Renderer = @import("Renderer.zig").Renderer;
const Config = @import("Config.zig");
const CopyMode = @import("CopyMode.zig").CopyMode;

const MAX_CLIENTS = 64;
const BUF_SIZE = 64 * 1024;

/// Frames are chunked so a single rendered screen can never exceed the
/// client's receive buffer (a frame larger than it wedges the client).
const MAX_FRAME_SIZE = 60 * 1024;

/// Worst-case bytes emitted per cell on a full redraw (cursor move +
/// style reset with truecolor fg/bg + UTF-8 glyph), used to size the
/// render buffer from the terminal dimensions.
const RENDER_BYTES_PER_CELL = 64;

// Tag encoding for the event loop (server-specific).
// bit 0 set  → *Pane  (real ptr = tag & ~TAG_PANE)
// bit 0 clear, non-zero → *Client
// zero → listen fd
const TAG_PANE: usize = 1;
const LISTEN_TAG: usize = 0;
const RENDER_BUF_SIZE = 256 * 1024;

const Client = struct {
    fd: posix.fd_t,
    stream: Stream(BUF_SIZE),
    cols: u16 = 80,
    rows: u16 = 24,
    // Only attached clients participate in layout sizing; probe
    // connections (e.g. sessionExists) never send an attach request.
    attached: bool = false,
};

/// Mode of operation for input handling
const InputMode = enum {
    normal,
    scroll,
    copy,
};

const ServerState = struct {
    alloc: std.mem.Allocator,
    listen_fd: posix.fd_t,
    loop: *Loop,
    clients: *[MAX_CLIENTS]?Client,
    workspace_manager: *WorkspaceManager,
    renderer: *Renderer,
    config: Config,
    render_buf: []u8,
    term_cols: u16,
    term_rows: u16,
    prefix_mode: bool,
    input_mode: InputMode = .normal,
    copy_mode: ?CopyMode = null,
    clipboard: ?[]u8 = null,
    // Set when a client leaves so the layout can grow back to the
    // remaining clients' minimum outside of broadcast iteration.
    layout_stale: bool = false,
};

pub fn server(alloc: std.mem.Allocator, socket_path: []const u8, termios: c.termios, ready_fd: ?posix.fd_t) !void {
    // Ignore SIGPIPE to prevent crash when writing to closed sockets
    // This can happen when sessionExists() checks for session existence
    // by connecting and immediately disconnecting
    var act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);

    // Create parent directory if it doesn't exist
    if (std.fs.path.dirname(socket_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    posix.unlink(socket_path) catch {};

    // Setup socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(listen_fd);

    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(listen_fd, 128);

    // Signal readiness to the parent (if any) now that the socket is accepting.
    // On any earlier failure the fd stays open and the kernel closes it on
    // process exit, so the parent sees EOF instead of a ready byte.
    if (ready_fd) |fd| {
        _ = posix.write(fd, "\x01") catch {};
        posix.close(fd);
    }

    var loop = try Loop.init();
    defer loop.deinit();
    try loop.addFd(listen_fd, LISTEN_TAG, false);

    // Terminal size
    const term_cols: u16 = 80;
    const term_rows: u16 = 24;
    const pane_rows = term_rows - 1;

    // Load config
    const config = Config.load(alloc);

    // Initialize workspace manager (heap allocated for stable pointer)
    var workspace_manager = try WorkspaceManager.init(alloc, term_cols, pane_rows, termios);
    defer workspace_manager.deinit(alloc);

    // Initialize renderer
    var renderer = try Renderer.init(alloc, term_cols, term_rows, config);
    defer renderer.deinit();

    // Allocate render buffer (grown on attach/resize to fit the terminal)
    const render_buf = try alloc.alloc(u8, RENDER_BUF_SIZE);

    const active_ws = workspace_manager.getActiveWorkspace() orelse return error.NoActiveWorkspace;
    try loop.addFd(active_ws.active_pane.pty.master_fd, @intFromPtr(active_ws.active_pane) | TAG_PANE, false);
    try loop.addFd(active_ws.floating_pane.pty.master_fd, @intFromPtr(active_ws.floating_pane) | TAG_PANE, false);

    var clients: [MAX_CLIENTS]?Client = [_]?Client{null} ** MAX_CLIENTS;

    var state = ServerState{
        .alloc = alloc,
        .listen_fd = listen_fd,
        .loop = &loop,
        .clients = &clients,
        .workspace_manager = &workspace_manager,
        .renderer = &renderer,
        .config = config,
        .render_buf = render_buf,
        .term_cols = term_cols,
        .term_rows = term_rows,
        .prefix_mode = false,
    };
    defer alloc.free(state.render_buf);

    while (true) {
        var iter = loop.wait(-1);
        // Coalesce pane output: feed every readable PTY in this batch
        // first and render once at the end, instead of running a full
        // diff render per read.
        var panes_fed = false;
        while (iter.next()) |event| {
            switch (event) {
                .readable => |tag| {
                    if (tag == LISTEN_TAG) {
                        const client_fd = posix.accept(listen_fd, null, null, 0) catch continue;
                        addClient(&state, client_fd);
                    } else if (tag & TAG_PANE != 0) {
                        const pane: *Pane = @ptrFromInt(tag & ~TAG_PANE);
                        var pty_buf: [64 * 1024]u8 = undefined;
                        // Stop polling on EOF or any error; otherwise the
                        // level-triggered loop redelivers the event forever
                        // and the server pegs a core. We leave the pane in
                        // place so the user still sees the final output.
                        const n = posix.read(pane.pty.master_fd, &pty_buf) catch {
                            state.loop.remove(pane.pty.master_fd);
                            continue;
                        };
                        if (n == 0) {
                            state.loop.remove(pane.pty.master_fd);
                            continue;
                        }
                        pane.feed(pty_buf[0..n]);
                        // Forward any OSC 52 (clipboard) sequences the pane
                        // intercepted so they reach the user's real terminal.
                        if (pane.pending_clipboard.items.len > 0) {
                            broadcast(&state, pane.pending_clipboard.items);
                            pane.pending_clipboard.clearRetainingCapacity();
                        }
                        panes_fed = true;
                    } else {
                        const client = activeClient(&state, tag) orelse continue;
                        client.stream.receiveData(client.fd) catch |err| {
                            // EAGAIN/EWOULDBLOCK is benign with level-triggered
                            // events: the kernel will redeliver once more data
                            // arrives. Anything else means the connection is
                            // unusable.
                            if (err == error.WouldBlock) continue;
                            removeClient(&state, client);
                            continue;
                        };
                        while (client.stream.nextMessage()) |msg| {
                            handleClient(&state, client, msg) catch {
                                removeClient(&state, client);
                                break;
                            };
                        }
                    }
                },
                .disconnect => |tag| {
                    if (tag == LISTEN_TAG) continue;
                    if (tag & TAG_PANE != 0) {
                        // Shell exited. Stop polling the PTY but leave the
                        // pane alive so the final output stays on screen.
                        const pane: *Pane = @ptrFromInt(tag & ~TAG_PANE);
                        state.loop.remove(pane.pty.master_fd);
                    } else if (activeClient(&state, tag)) |client| {
                        removeClient(&state, client);
                    }
                },
                .signal => {},
            }
        }
        if (state.layout_stale) {
            state.layout_stale = false;
            if (applyClientLayout(&state) catch false) {
                state.renderer.invalidate();
                renderAndBroadcast(&state, false) catch {};
                panes_fed = false;
            }
        }
        if (panes_fed) renderAndBroadcast(&state, false) catch {};
    }
}

/// Send data to every attached client, split into frames the client's
/// receive buffer can always hold. A client whose socket cannot accept
/// the data is dropped: continuing after a truncated frame would desync
/// the length-prefixed protocol for good.
fn broadcast(state: *ServerState, data: []const u8) void {
    for (&state.clients.*) |*slot| {
        if (slot.*) |*client| {
            var off: usize = 0;
            while (off < data.len) {
                const end = @min(off + MAX_FRAME_SIZE, data.len);
                client.stream.write(data[off..end], client.fd) catch {
                    removeClient(state, client);
                    break;
                };
                off = end;
            }
        }
    }
}

fn addClient(state: *ServerState, fd: posix.fd_t) void {
    // Switch to non-blocking so the event-loop path never accidentally
    // blocks the server when a client sends a partial message.
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch {
        posix.close(fd);
        return;
    };
    _ = posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {
        posix.close(fd);
        return;
    };

    for (&state.clients.*) |*slot| {
        if (slot.* == null) {
            slot.* = Client{ .fd = fd, .stream = Stream(BUF_SIZE).init() };
            if (slot.*) |*client| {
                state.loop.addFd(fd, @intFromPtr(client), true) catch {};
            }
            return;
        }
    }
    posix.close(fd);
}

// Idempotent: the fd is only closed when the client still occupies a
// slot, so a second remove (e.g. broadcast dropped the client and the
// caller removes it again on error) can't close an unrelated fd that
// reused the number.
fn removeClient(state: *ServerState, client: *Client) void {
    for (&state.clients.*) |*slot| {
        if (slot.*) |*cl| {
            if (cl.fd == client.fd) {
                state.loop.remove(cl.fd);
                posix.close(cl.fd);
                slot.* = null;
                // The layout may grow back to the remaining clients'
                // minimum; recomputed at the end of the event batch to
                // avoid re-entering render paths from here.
                state.layout_stale = true;
                return;
            }
        }
    }
}

/// Resolve a client tag to a still-active *Client. Returns null if the
/// client was already removed earlier in this poll iteration, preventing
/// use-after-free when multiple events for the same client (e.g. readable
/// + disconnect on close) arrive in the same wait batch.
fn activeClient(state: *ServerState, tag: usize) ?*Client {
    const target: *Client = @ptrFromInt(tag);
    for (&state.clients.*) |*slot| {
        if (slot.*) |*cl| {
            if (cl == target) return cl;
        }
    }
    return null;
}

fn renderAndBroadcast(state: *ServerState, clear_screen: bool) !void {
    const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;

    var writer = std.Io.Writer.fixed(state.render_buf);

    const mode_label: ?[]const u8 = switch (state.input_mode) {
        .scroll => "SCROLL",
        .copy => "COPY",
        .normal => if (state.prefix_mode) "PREFIX" else null,
    };

    try state.renderer.renderAll(
        active_ws,
        state.workspace_manager,
        state.term_rows,
        &writer,
        mode_label,
        clear_screen,
        state.copy_mode,
    );

    const rendered = writer.buffered();
    broadcast(state, rendered);
}

/// Size the session to the smallest attached client (tmux-style) so
/// every attached client can display the full layout. Returns true if
/// the size changed and a full redraw is needed.
fn applyClientLayout(state: *ServerState) !bool {
    var min_cols: u16 = 0;
    var min_rows: u16 = 0;
    var any = false;
    for (state.clients.*) |slot| {
        const cl = slot orelse continue;
        if (!cl.attached) continue;
        if (!any) {
            min_cols = cl.cols;
            min_rows = cl.rows;
            any = true;
        } else {
            min_cols = @min(min_cols, cl.cols);
            min_rows = @min(min_rows, cl.rows);
        }
    }

    if (!any) return false;

    // Guard against degenerate sizes from misreported terminals
    min_cols = @max(min_cols, 10);
    min_rows = @max(min_rows, 4);

    if (min_cols == state.term_cols and min_rows == state.term_rows) return false;

    state.term_cols = min_cols;
    state.term_rows = min_rows;
    const pane_rows = min_rows - 1; // status bar takes the last row
    state.workspace_manager.cols = min_cols;
    state.workspace_manager.rows = pane_rows;
    for (state.workspace_manager.workspaces.items) |*ws| {
        try ws.resizeWorkspace(state.alloc, min_cols, pane_rows);
    }
    try reinitRenderer(state, min_cols, min_rows);
    return true;
}

/// Replace the renderer and grow the render buffer for a new terminal
/// size. The new renderer is built before the old one is torn down so a
/// failure leaves the previous (still valid) state in place.
fn reinitRenderer(state: *ServerState, cols: u16, rows: u16) !void {
    const cells = @as(usize, cols) * @as(usize, rows);
    const needed = @max(RENDER_BUF_SIZE, cells * RENDER_BYTES_PER_CELL);
    if (needed > state.render_buf.len) {
        state.render_buf = try state.alloc.realloc(state.render_buf, needed);
    }

    const new_renderer = try Renderer.init(state.alloc, cols, rows, state.config);
    state.renderer.deinit();
    state.renderer.* = new_renderer;
}

fn handleClient(state: *ServerState, client: *Client, data: []const u8) !void {
    const request = try protocol.Request.decode(data);

    switch (request) {
        .attach => |d| {
            client.cols = d.cols;
            client.rows = d.rows;
            client.attached = true;

            // Session size follows the smallest attached client so the
            // layout stays visible everywhere.
            _ = try applyClientLayout(state);

            var resp_buf: [256]u8 = undefined;
            const resp = protocol.Response{ .attach_ok = .{ .cols = d.cols, .rows = d.rows } };
            const resp_data = try resp.encode(&resp_buf);
            try client.stream.write(resp_data, client.fd);

            // Full redraw even when the size didn't change: the new
            // client starts from an empty screen.
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .detach => {
            removeClient(state, client);
        },
        .input => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            try active_ws.activePane().pty.write(d.input);
        },
        .resize => |d| {
            client.cols = d.cols;
            client.rows = d.rows;

            _ = try applyClientLayout(state);

            // The resized client's terminal cleared its content, so
            // force a full redraw even if the session size is unchanged.
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .split_pane => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const ws_dir: Workspace.SplitDir = switch (d.direction) {
                .vertical => .vertical,
                .horizontal => .horizontal,
            };
            const new_fd = try active_ws.splitPane(state.alloc, ws_dir);
            if (active_ws.getPane(new_fd)) |new_pane| {
                try state.loop.addFd(new_fd, @intFromPtr(new_pane) | TAG_PANE, false);
            }

            state.prefix_mode = false;

            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .focus_pane => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const ws_dir: Workspace.Direction = switch (d.direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            };
            active_ws.focusPane(ws_dir);
            try renderAndBroadcast(state, false);
        },
        .close_pane => {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;

            const pty_fd = active_ws.active_pane.pty.master_fd;
            state.loop.remove(pty_fd);

            try active_ws.closePane(state.alloc);

            state.renderer.invalidate();
            try renderAndBroadcast(state, true);
        },
        .new_workspace => {
            try state.workspace_manager.appendWorkspace(state.alloc);
            state.workspace_manager.switchWorkspace(state.workspace_manager.workspaces.items.len - 1);

            const new_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            try state.loop.addFd(new_ws.active_pane.pty.master_fd, @intFromPtr(new_ws.active_pane) | TAG_PANE, false);
            try state.loop.addFd(new_ws.floating_pane.pty.master_fd, @intFromPtr(new_ws.floating_pane) | TAG_PANE, false);

            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .switch_workspace => |d| {
            state.workspace_manager.switchWorkspace(d.index);

            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .toggle_floating => {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            active_ws.toggleFloating();

            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .set_prefix_mode => |d| {
            state.prefix_mode = d.enabled;
            try renderAndBroadcast(state, false);
        },
        .scroll_mode_start => {
            state.input_mode = .scroll;
            state.prefix_mode = false;
            try renderAndBroadcast(state, false);
        },
        .scroll_mode_input => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();
            const half_page: isize = @intCast(pane.rows / 2);
            switch (d.key) {
                .scroll_up => pane.terminal.scrollViewport(.{ .delta = -1 }),
                .scroll_down => pane.terminal.scrollViewport(.{ .delta = 1 }),
                .half_page_up => pane.terminal.scrollViewport(.{ .delta = -half_page }),
                .half_page_down => pane.terminal.scrollViewport(.{ .delta = half_page }),
            }
            pane.is_dirty = true; // Mark pane dirty after scrolling
            try renderAndBroadcast(state, false);
        },
        .scroll_mode_exit => {
            state.input_mode = .normal;
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();
            // Reset viewport to bottom
            pane.terminal.scrollViewport(.{ .bottom = {} });
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .copy_mode_start => {
            state.input_mode = .copy;
            state.prefix_mode = false;
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            state.copy_mode = CopyMode.init(active_ws.activePane());
            try renderAndBroadcast(state, false);
        },
        .copy_mode_input => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();
            if (state.copy_mode) |*cm| {
                switch (d.key) {
                    .move_left => cm.moveLeft(),
                    .move_right => cm.moveRight(pane),
                    .move_up => cm.moveUp(pane),
                    .move_down => cm.moveDown(pane),
                    .next_word => cm.nextWord(pane),
                    .prev_word => cm.prevWord(pane),
                    .begin_of_line => cm.beginOfLine(),
                    .end_of_line => cm.endOfLine(pane),
                    .top_of_screen => cm.topOfScreen(),
                    .bottom_of_screen => cm.bottomOfScreen(pane),
                    .half_page_up => cm.halfPageUp(pane),
                    .half_page_down => cm.halfPageDown(pane),
                    .start_selection => cm.startSelection(),
                }
            }
            pane.is_dirty = true; // Mark pane dirty after copy mode input
            try renderAndBroadcast(state, false);
        },
        .copy_mode_exit => {
            state.input_mode = .normal;
            state.copy_mode = null;
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();
            pane.terminal.scrollViewport(.{ .bottom = {} });
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .paste => {
            if (state.clipboard) |text| {
                const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
                const pane = active_ws.activePane();
                // Send bracketed paste
                try pane.pty.write("\x1b[200~");
                try pane.pty.write(text);
                try pane.pty.write("\x1b[201~");
            }
        },
        .swap_pane => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const ws_dir: Workspace.Direction = switch (d.direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            };
            try active_ws.swapPane(state.alloc, ws_dir);
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .resize_pane => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const delta: f32 = if (d.grow) 0.05 else -0.05;
            try active_ws.resizePane(state.alloc, delta);
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .move_pane_to_workspace => |d| {
            try state.workspace_manager.movePaneToWorkspace(state.alloc, d.index);
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .cycle_workspace => |d| {
            if (d.next) {
                _ = state.workspace_manager.nextWorkspace();
            } else {
                _ = state.workspace_manager.prevWorkspace();
            }
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .mouse_select_start => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;

            // Select in the pane that was clicked, not whichever pane
            // happens to be active. Clicks on borders or the status bar
            // hit no pane and are ignored.
            const pane = active_ws.paneAt(d.x, d.y) orelse return;
            active_ws.active_pane = pane;

            // Convert screen coordinates to pane-relative coordinates;
            // paneAt guarantees they are in bounds.
            const x = d.x - pane.x;
            const y = d.y - pane.y;

            // Enter copy mode with selection started at mouse position
            state.input_mode = .copy;
            state.prefix_mode = false;
            state.copy_mode = CopyMode.initAtPosition(x, y);
            try renderAndBroadcast(state, false);
        },
        .mouse_select_update => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();

            if (state.copy_mode) |*cm| {
                // Convert screen coordinates to pane-relative coordinates
                const pane_x = d.x -| pane.x;
                const pane_y = d.y -| pane.y;

                // Clamp to pane bounds
                const x = @min(pane_x, pane.cols -| 1);
                const y = @min(pane_y, pane.rows -| 1);

                cm.setCursorPosition(x, y);
                try renderAndBroadcast(state, false);
            }
        },
        .mouse_select_end => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();

            if (state.copy_mode) |*cm| {
                // Convert screen coordinates to pane-relative coordinates
                const pane_x = d.x -| pane.x;
                const pane_y = d.y -| pane.y;

                // Clamp to pane bounds
                const x = @min(pane_x, pane.cols -| 1);
                const y = @min(pane_y, pane.rows -| 1);

                cm.setCursorPosition(x, y);
                // Keep copy mode active - user can press Ctrl+C to copy or Esc to cancel
                try renderAndBroadcast(state, false);
            }
        },
        .clipboard_copy => {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();

            // Copy selected text if in copy mode with selection
            if (state.copy_mode) |*cm| {
                if (cm.selecting) {
                    if (cm.getSelectedText(state.alloc, pane)) |text| {
                        // Free old clipboard if any
                        if (state.clipboard) |old| {
                            state.alloc.free(old);
                        }
                        state.clipboard = text;

                        // Send OSC 52 to set system clipboard
                        var osc_buf: [65536]u8 = undefined;
                        const encoded = encodeOsc52(text, &osc_buf);
                        if (encoded.len > 0) broadcast(state, encoded);
                    } else |_| {}
                }
            }

            // Exit copy mode
            state.input_mode = .normal;
            state.copy_mode = null;
            pane.terminal.scrollViewport(.{ .bottom = {} });
            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
    }
}

/// Encode text to OSC 52 clipboard escape sequence
fn encodeOsc52(text: []const u8, buf: []u8) []u8 {
    const prefix = "\x1b]52;c;";
    const suffix = "\x1b\\";

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(text.len);

    if (prefix.len + encoded_len + suffix.len > buf.len) {
        return buf[0..0];
    }

    @memcpy(buf[0..prefix.len], prefix);
    _ = encoder.encode(buf[prefix.len..][0..encoded_len], text);
    @memcpy(buf[prefix.len + encoded_len ..][0..suffix.len], suffix);

    return buf[0 .. prefix.len + encoded_len + suffix.len];
}

