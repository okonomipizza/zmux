const std = @import("std");
const c = @import("c.zig").c;
const Stream = @import("Stream.zig").Stream;
const posix = std.posix;
const linux = std.os.linux;
const protocol = @import("protocol.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const Workspace = @import("Workspace.zig");
const Pane = @import("Pane.zig");
const Renderer = @import("Renderer.zig").Renderer;
const Config = @import("Config.zig");
const CopyMode = @import("CopyMode.zig").CopyMode;

const MAX_CLIENTS = 64;
const BUF_SIZE = 64 * 1024;
const RENDER_BUF_SIZE = 256 * 1024;

const Client = struct {
    fd: posix.fd_t,
    stream: Stream(BUF_SIZE),
    cols: u16 = 80,
    rows: u16 = 24,
};

/// Mode of operation for input handling
const InputMode = enum {
    normal,
    scroll,
    copy,
};

/// Server state passed to helper functions
const ServerState = struct {
    alloc: std.mem.Allocator,
    listen_fd: posix.fd_t,
    epoll_fd: posix.fd_t,
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
};

pub fn server(alloc: std.mem.Allocator, socket_path: []const u8, termios: c.termios) !void {
    // Ignore SIGPIPE to prevent crash when writing to closed sockets
    // This can happen when sessionExists() checks for session existence
    // by connecting and immediately disconnecting
    var act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = @splat(0),
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
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(listen_fd, 128);

    // Setup epoll
    const epoll_fd = try posix.epoll_create1(0);
    defer posix.close(epoll_fd);

    var listen_ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listen_fd },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &listen_ev);

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

    // Allocate render buffer
    const render_buf = try alloc.alloc(u8, RENDER_BUF_SIZE);
    defer alloc.free(render_buf);

    // Register initial pane fds with epoll
    const active_ws = workspace_manager.getActiveWorkspace() orelse return error.NoActiveWorkspace;
    try epollAdd(epoll_fd, active_ws.active_pane.pty.master_fd, linux.EPOLL.IN);
    try epollAdd(epoll_fd, active_ws.floating_pane.pty.master_fd, linux.EPOLL.IN);

    // Client storage
    var clients: [MAX_CLIENTS]?Client = [_]?Client{null} ** MAX_CLIENTS;

    // Server state for helpers
    var state = ServerState{
        .alloc = alloc,
        .listen_fd = listen_fd,
        .epoll_fd = epoll_fd,
        .clients = &clients,
        .workspace_manager = &workspace_manager,
        .renderer = &renderer,
        .config = config,
        .render_buf = render_buf,
        .term_cols = term_cols,
        .term_rows = term_rows,
        .prefix_mode = false,
    };

    var events: [64]linux.epoll_event = undefined;

    // Main event loop
    while (true) {
        const n = posix.epoll_wait(epoll_fd, &events, -1);

        for (events[0..n]) |ev| {
            const fd: posix.fd_t = ev.data.fd;

            if (fd == listen_fd) {
                // New client connection
                const client_fd = posix.accept(listen_fd, null, null, 0) catch continue;
                addClient(&state, client_fd);
            } else {
                // Check for disconnect
                if (ev.events & (linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                    // Check if it's a PTY fd first - don't close it, just ignore
                    // (PTY HUP means shell exited, but we keep the pane)
                    if (findPaneByFd(&state, fd) == null) {
                        removeClient(&state, fd);
                    }
                    continue;
                }

                // Check if this is pane pty output
                if (findPaneByFd(&state, fd)) |pane| {
                    var pty_buf: [4096]u8 = undefined;
                    const pty_n = posix.read(fd, &pty_buf) catch continue;
                    if (pty_n > 0) {
                        pane.feed(pty_buf[0..pty_n]) catch {};
                        renderAndBroadcast(&state, false) catch {};
                    }
                } else if (getClient(&state, fd)) |client| {
                    // Client data
                    const data = client.stream.read(client.fd) catch |err| {
                        if (err == error.Closed) {
                            removeClient(&state, fd);
                        }
                        continue;
                    };
                    // Handle client request - errors should not crash the server
                    handleClient(&state, client, data) catch {
                        removeClient(&state, fd);
                    };
                }
            }
        }
    }
}

fn epollAdd(epoll_fd: posix.fd_t, fd: posix.fd_t, events: u32) !void {
    var ev = linux.epoll_event{
        .events = events,
        .data = .{ .fd = fd },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
}

fn addClient(state: *ServerState, fd: posix.fd_t) void {
    for (&state.clients.*) |*slot| {
        if (slot.* == null) {
            slot.* = Client{ .fd = fd, .stream = Stream(BUF_SIZE).init() };

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .fd = fd },
            };
            posix.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev) catch {};
            return;
        }
    }
    posix.close(fd);
}

fn removeClient(state: *ServerState, fd: posix.fd_t) void {
    posix.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    posix.close(fd);

    for (&state.clients.*) |*slot| {
        if (slot.*) |client| {
            if (client.fd == fd) {
                slot.* = null;
                return;
            }
        }
    }
}

fn getClient(state: *ServerState, fd: posix.fd_t) ?*Client {
    for (&state.clients.*) |*slot| {
        if (slot.*) |*client| {
            if (client.fd == fd) return client;
        }
    }
    return null;
}

fn findPaneByFd(state: *ServerState, fd: posix.fd_t) ?*Pane {
    for (state.workspace_manager.workspaces.items) |*ws| {
        if (ws.floating_pane.pty.master_fd == fd) return ws.floating_pane;
        if (ws.getPane(fd)) |pane| return pane;
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

    for (&state.clients.*) |*slot| {
        if (slot.*) |*client| {
            client.stream.write(rendered, client.fd) catch {};
        }
    }
}

fn handleClient(state: *ServerState, client: *Client, data: []const u8) !void {
    const request = try protocol.Request.decode(data);

    switch (request) {
        .attach => |d| {
            client.cols = d.cols;
            client.rows = d.rows;
            state.term_cols = d.cols;
            state.term_rows = d.rows;
            const pane_rows = d.rows -| 1;

            state.workspace_manager.cols = d.cols;
            state.workspace_manager.rows = pane_rows;

            // Resize all workspaces to match client terminal size
            for (state.workspace_manager.workspaces.items) |*ws| {
                try ws.resizeWorkspace(state.alloc, d.cols, pane_rows);
            }

            state.renderer.deinit();
            state.renderer.* = try Renderer.init(state.alloc, d.cols, d.rows, state.config);

            var resp_buf: [256]u8 = undefined;
            const resp = protocol.Response{ .attach_ok = .{ .cols = d.cols, .rows = d.rows } };
            const resp_data = try resp.encode(&resp_buf);
            try client.stream.write(resp_data, client.fd);

            state.renderer.invalidate();
            try renderAndBroadcast(state, false);
        },
        .detach => {
            // Remove client from epoll and close fd
            posix.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_DEL, client.fd, null) catch {};
            posix.close(client.fd);

            // Remove from clients array
            for (&state.clients.*) |*slot| {
                if (slot.*) |*cl| {
                    if (cl.fd == client.fd) {
                        slot.* = null;
                        break;
                    }
                }
            }
        },
        .input => |d| {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            try active_ws.activePane().pty.write(d.input);
        },
        .resize => |d| {
            client.cols = d.cols;
            client.rows = d.rows;
            state.term_cols = d.cols;
            state.term_rows = d.rows;
            const pane_rows = d.rows -| 1;

            state.workspace_manager.cols = d.cols;
            state.workspace_manager.rows = pane_rows;

            // Resize all workspaces to match new terminal size
            for (state.workspace_manager.workspaces.items) |*ws| {
                try ws.resizeWorkspace(state.alloc, d.cols, pane_rows);
            }

            state.renderer.deinit();
            state.renderer.* = try Renderer.init(state.alloc, d.cols, d.rows, state.config);

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
            try epollAdd(state.epoll_fd, new_fd, linux.EPOLL.IN);

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
            try posix.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_DEL, pty_fd, null);

            try active_ws.closePane(state.alloc);

            state.renderer.invalidate();
            try renderAndBroadcast(state, true);
        },
        .new_workspace => {
            try state.workspace_manager.appendWorkspace(state.alloc);
            state.workspace_manager.switchWorkspace(state.workspace_manager.workspaces.items.len - 1);

            const new_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            try epollAdd(state.epoll_fd, new_ws.active_pane.pty.master_fd, linux.EPOLL.IN);
            try epollAdd(state.epoll_fd, new_ws.floating_pane.pty.master_fd, linux.EPOLL.IN);

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
        .yank => {
            const active_ws = state.workspace_manager.getActiveWorkspace() orelse return;
            const pane = active_ws.activePane();

            // Try to yank selected text if in copy mode with selection
            if (state.copy_mode) |*cm| {
                if (cm.selecting) {
                    if (cm.getSelectedText(state.alloc, pane)) |text| {
                        // Free old clipboard if any
                        if (state.clipboard) |old| {
                            state.alloc.free(old);
                        }
                        state.clipboard = text;

                        // Send OSC 52 to set system clipboard (include in render output)
                        var osc_buf: [65536]u8 = undefined;
                        const encoded = encodeOsc52(text, &osc_buf);
                        if (encoded.len > 0) {
                            for (&state.clients.*) |*slot| {
                                if (slot.*) |*cli| {
                                    cli.stream.write(encoded, cli.fd) catch {};
                                }
                            }
                        }
                    } else |_| {
                        // Ignore error, just skip clipboard
                    }
                }
            }

            // Always exit copy mode after yank attempt
            state.input_mode = .normal;
            state.copy_mode = null;
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
    const encoded = encoder.encode(buf[prefix.len..][0..encoded_len], text);
    _ = encoded;
    @memcpy(buf[prefix.len + encoded_len ..][0..suffix.len], suffix);

    return buf[0 .. prefix.len + encoded_len + suffix.len];
}
