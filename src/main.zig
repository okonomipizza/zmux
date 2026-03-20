const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const zmux = @import("zmux");
const ghostty_vt = @import("ghostty-vt");
const clap = @import("clap");

const version = "0.0.0";

const Renderer = @import("Renderer.zig");

const c = @import("c.zig").c;

const CopyMode = @import("CopyMode.zig");
const Pty = @import("Pty.zig");
const StatusBar = @import("StatusBar.zig");
const Workspace = @import("Workspace.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");

var original_termios: c.termios = undefined;
const BUF_SIZE: usize = 4096;

/// zmux メインプロセス用の termios 設定
/// 端末を non-canonical mode に設定し、
/// 入力を行単位にまとめず1文字ずつ読み取れるようにする
fn enableRawMode() !void {
    //zmux メインプロセスを実行している端末の属性を取得する
    if (c.tcgetattr(c.STDIN_FILENO, &original_termios) < 0)
        return error.TcgetattrFailed;

    var raw = original_termios;

    // non-canonical + エコーOFF + シグナル無効
    // ICANON: Canonical-mode (入力を行単位にまとめる)
    // ECHO: 入力文字のエコー
    // ISIG: シグナルを生成する文字の有効化 (Ctrl-C etc...)
    // IEXTEN: 入力の拡張処理 (zmuxは、ptyに入力をそのまま流したいため不要)
    raw.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ISIG | c.IEXTEN);
    // CR→LF変換など無効
    // IXON: 出力フロー制御
    // ICRNL: CR -> NL へのマッピング
    // BRKINT: BREAK 時に SIGINT を生成
    // INPCK: 入力パリティチェック
    // ISTRIP: 入力の8 bit 目をクリア(マルチバイト文字を扱うためにoff)
    raw.c_iflag &= ~@as(c_uint, c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP);
    // マルチバイト文字の有効化
    raw.c_cflag |= @as(c_uint, c.CS8);
    // read() が返ってくるタイミングを制御
    // 1文字来たら返す、タイムアウトなし
    raw.c_cc[c.VMIN] = 1; // 1文字受け取るまで待機
    raw.c_cc[c.VTIME] = 0; // タイムアウトなし

    // 端末設定を適用
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) < 0)
        return error.TcsetattrFailed;
}

// zmux が変更した端末属性を元に戻す
fn disableRawMode() void {
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &original_termios);
}

fn epollAdd(epoll_fd: c_int, fd: c_int, events: u32) !void {
    var ev = c.epoll_event{
        .events = events,
        .data = .{ .fd = fd },
    };
    if (c.epoll_ctl(epoll_fd, c.EPOLL_CTL_ADD, fd, &ev) < 0)
        return error.EpollCtlFailed;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-v, --version  Output version information and exit.
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = alloc,
    });
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(std.fs.File.stderr(), clap.Help, &params, .{});
    }

    if (res.args.version != 0) {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll("zmux " ++ version ++ "\n");
        return;
    }

    try spawnServer(alloc);
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

fn spawnServer(alloc: std.mem.Allocator) !void {
    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll("\x1b[2J\x1b[H");

    const output_slice = try alloc.alloc(u8, 2 * 1024 * 1024); // 2MB
    defer alloc.free(output_slice);
    var output_fbs = std.io.fixedBufferStream(output_slice);
    const buf_writer = output_fbs.writer();

    const original_term = getTermSize();
    const term = .{
        .cols = original_term.cols,
        .rows = original_term.rows - 1, // -1 for bottom bar
    };

    try enableRawMode();
    defer disableRawMode();

    var workspace_manager = try WorkspaceManager.init(alloc, term.cols, term.rows, original_termios);
    defer workspace_manager.deinit(alloc);

    var active_workspace: *Workspace = workspace_manager.getActiveWorkspace() orelse return;

    var renderer = try Renderer.init(alloc, term.cols, term.rows);
    defer renderer.deinit();

    // Monitor each process by epoll
    const epoll_fd = c.epoll_create1(0);
    if (epoll_fd < 0) return error.EpollCreateFailed;
    defer _ = c.close(epoll_fd);
    try epollAdd(epoll_fd, c.STDIN_FILENO, c.EPOLLIN);
    // Register the initial panes into the epoll watch list
    try epollAdd(epoll_fd, active_workspace.active_pane.pty.master_fd, c.EPOLLIN);
    try epollAdd(epoll_fd, active_workspace.floating_pane.pty.master_fd, c.EPOLLIN);

    var events: [16]c.epoll_event = undefined;
    var buf: [BUF_SIZE]u8 = undefined;

    // Enable bracketed paste mode on the outer terminal
    try stdout_file.writeAll("\x1b[?2004h");
    defer stdout_file.writeAll("\x1b[?2004l") catch {};

    // Key input handling state
    var prefix_mode: bool = false;
    var move_pane_mode: bool = false;
    var scroll_mode: bool = false;
    var copy_mode_state: ?CopyMode = null;
    var bracketed_paste: bool = false;

    // Internal clipboard buffer
    var clipboard: std.ArrayList(u8) = .empty;
    defer clipboard.deinit(alloc);

    while (true) {
        const n = c.epoll_wait(epoll_fd, &events, @intCast(events.len), -1);
        if (n < 0) continue;

        for (events[0..@intCast(n)]) |ev| {
            const fd = ev.data.fd;

            if (fd == c.STDIN_FILENO) {
                // Read from stdin and forward to the active pane
                const nr = c.read(c.STDIN_FILENO, &buf, BUF_SIZE);
                if (nr <= 0) return;
                const input = buf[0..@intCast(nr)];

                // Bracketed paste: detect \x1b[200~ (start) and \x1b[201~ (end)
                // Forward pasted content directly to PTY without interpretation
                if (bracketed_paste) {
                    // Check for end of bracketed paste: \x1b[201~
                    if (std.mem.indexOf(u8, input, "\x1b[201~")) |end_pos| {
                        const active = active_workspace.activePane();
                        if (end_pos > 0) {
                            active.pty.write(input[0..end_pos]) catch {};
                        }
                        bracketed_paste = false;
                        // Forward any remaining input after the paste end marker
                        const after = end_pos + 6; // len of "\x1b[201~"
                        if (after < input.len) {
                            active.pty.write(input[after..]) catch {};
                        }
                    } else {
                        const active = active_workspace.activePane();
                        active.pty.write(input) catch {};
                    }
                    continue;
                }

                // Check for bracketed paste start: \x1b[200~
                if (std.mem.indexOf(u8, input, "\x1b[200~")) |start_pos| {
                    const active = active_workspace.activePane();
                    // Forward anything before the paste marker
                    if (start_pos > 0) {
                        active.pty.write(input[0..start_pos]) catch {};
                    }
                    // Forward the paste content after the marker
                    const after = start_pos + 6; // len of "\x1b[200~"
                    if (after < input.len) {
                        // Check if paste end is also in this chunk
                        const rest = input[after..];
                        if (std.mem.indexOf(u8, rest, "\x1b[201~")) |end_pos| {
                            if (end_pos > 0) {
                                active.pty.write(rest[0..end_pos]) catch {};
                            }
                            const final_after = end_pos + 6;
                            if (final_after < rest.len) {
                                active.pty.write(rest[final_after..]) catch {};
                            }
                        } else {
                            active.pty.write(rest) catch {};
                            bracketed_paste = true;
                        }
                    } else {
                        bracketed_paste = true;
                    }
                    continue;
                }

                // Ctrl-b (0x02) activates zmux prefix mode
                if (input.len == 1 and input[0] == 0x02) {
                    prefix_mode = true;
                    continue;
                }

                // Handle scroll mode input for the active pane
                if (scroll_mode) {
                    switch (input[0]) {
                        '\r' => {
                            // enter key deactivates scroll mode
                            scroll_mode = false;
                        },
                        'j' => {
                            // Scroll down
                            workspace_manager.getActiveWorkspace().?.active_pane.terminal.scrollViewport(.{ .delta = 1 });
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                        },
                        'k' => {
                            // Scroll up
                            workspace_manager.getActiveWorkspace().?.active_pane.terminal.scrollViewport(.{ .delta = -1 });
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                        },
                        else => {},
                    }
                    continue;
                }

                // Handle move_pane mode input for the moving pane
                if (move_pane_mode) {
                    move_pane_mode = false;
                    if (input.len == 1 and input[0] >= '1' and input[0] <= '9') {
                        const target_idx: usize = input[0] - '1';
                        workspace_manager.movePaneToWorkspace(alloc, target_idx) catch {
                            continue;
                        };
                        active_workspace = workspace_manager.getActiveWorkspace() orelse return;
                        try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                    }
                    continue;
                }

                // Handle copy mode input
                if (copy_mode_state != null) {
                    var cm = &copy_mode_state.?;
                    const pane = active_workspace.activePane();
                    switch (input[0]) {
                        'h' => cm.moveLeft(),
                        'j' => cm.moveDown(pane),
                        'k' => cm.moveUp(pane),
                        'l' => cm.moveRight(pane),
                        'v' => cm.startSelection(),
                        '0' => cm.beginOfLine(),
                        '$' => cm.endOfLine(pane),
                        'g' => cm.topOfScreen(),
                        'G' => cm.bottomOfScreen(pane),
                        'w' => cm.nextWord(pane),
                        'b' => cm.prevWord(pane),
                        0x15 => cm.halfPageUp(pane), // Ctrl-u
                        0x04 => cm.halfPageDown(pane), // Ctrl-d
                        'y' => {
                            if (cm.selecting) {
                                const text = cm.getSelectedText(alloc, pane) catch null;
                                if (text) |t| {
                                    // Store in internal clipboard
                                    clipboard.clearRetainingCapacity();
                                    clipboard.appendSlice(alloc, t) catch {};
                                    // Send to macOS clipboard via OSC 52
                                    setOsc52Clipboard(stdout_file, t) catch {};
                                    alloc.free(t);
                                }
                            }
                            copy_mode_state = null;
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            continue;
                        },
                        'q', 0x1b => { // q or Escape
                            copy_mode_state = null;
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            continue;
                        },
                        else => {},
                    }
                    // Re-render with copy mode overlay
                    try refreshScreenCopyMode(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, &copy_mode_state.?);
                    continue;
                }

                // Handle prefix mode key bindings
                if (prefix_mode) {
                    prefix_mode = false; // Reset prefix mode regardless of which key follows
                    switch (input[0]) {
                        '\r' => {
                            // Exit prefix mode
                        },
                        'm' => {
                            // Activate move_pane mode
                            move_pane_mode = true;
                        },
                        's' => {
                            // Activate scroll_mode
                            scroll_mode = true;
                        },
                        'c' => {
                            const pane = active_workspace.activePane();
                            copy_mode_state = CopyMode.init(pane);
                            try refreshScreenCopyMode(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, &copy_mode_state.?);
                            continue;
                        },
                        'p' => {
                            // Paste from internal clipboard
                            if (clipboard.items.len > 0) {
                                const active = active_workspace.activePane();
                                active.pty.write(clipboard.items) catch {};
                            }
                        },
                        // ----- Workspace control -----
                        'n' => {
                            // Append a new workspace
                            const MAX_WORKSPACE_NUM: usize = 9;
                            if (workspace_manager.workspaces.items.len < MAX_WORKSPACE_NUM) {
                                try workspace_manager.appendWorkspace(alloc);
                                workspace_manager.switchWorkspace(workspace_manager.workspaces.items.len - 1);
                                active_workspace = workspace_manager.getActiveWorkspace() orelse return;
                                try epollAdd(epoll_fd, active_workspace.active_pane.pty.master_fd, c.EPOLLIN);
                                try epollAdd(epoll_fd, active_workspace.floating_pane.pty.master_fd, c.EPOLLIN);

                                try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            }
                        },
                        'f' => {
                            active_workspace.toggleFloating();
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'i' => {
                            active_workspace = workspace_manager.nextWorkspace() orelse return;
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);

                            // Keep prefix mode active so workspace can be cycled with repeated presses
                            prefix_mode = true;
                        },
                        'u' => {
                            active_workspace = workspace_manager.prevWorkspace() orelse return;
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);

                            // Keep prefix mode active so workspace can be cycled with repeated presses
                            prefix_mode = true;
                        },
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                            const idx = input[0] - '1';
                            if (idx < workspace_manager.workspaces.items.len) {
                                workspace_manager.switchWorkspace(idx);
                                active_workspace = workspace_manager.getActiveWorkspace() orelse return;
                                try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            }
                        },
                        // ----- Pane control -----
                        '\\' => {
                            const new_fd = try active_workspace.splitPane(alloc, .vertical);
                            try epollAdd(epoll_fd, new_fd, c.EPOLLIN);

                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        '-' => {
                            const new_fd = try active_workspace.splitPane(alloc, .horizontal);
                            try epollAdd(epoll_fd, new_fd, c.EPOLLIN);

                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'h' => {
                            active_workspace.focusPane(.left);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        'j' => {
                            active_workspace.focusPane(.down);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        'k' => {
                            active_workspace.focusPane(.up);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        'l' => {
                            active_workspace.focusPane(.right);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        'J' => {
                            try active_workspace.swapPane(alloc, .down);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'H' => {
                            try active_workspace.swapPane(alloc, .left);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'L' => {
                            try active_workspace.swapPane(alloc, .right);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'K' => {
                            try active_workspace.swapPane(alloc, .up);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        '>' => {
                            try active_workspace.resizePane(alloc, 0.05);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        '<' => {
                            try active_workspace.resizePane(alloc, -0.05);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'x' => {
                            try active_workspace.closePane(alloc);
                            try refreshScreen(&output_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'q' => {
                            // exit zmux
                            return;
                        },
                        else => {
                            const active = active_workspace.activePane();
                            active.pty.write(input) catch continue;
                        },
                    }
                    continue;
                }

                // No matching key binding — forward input to the active pty
                const active = active_workspace.activePane();
                active.pty.write(input) catch continue;
            } else {
                // Received output from the pane - read and feed it to the pane's buffer
                const pane = active_workspace.getPane(ev.data.fd) orelse continue;
                const nr = c.read(pane.pty.master_fd, &buf, BUF_SIZE);
                if (nr <= 0) return;

                try pane.feed(buf[0..@intCast(nr)]);

                output_fbs.reset();

                if (active_workspace.show_floating and pane == active_workspace.floating_pane) {
                    try renderer.renderFloatingOnly(active_workspace, &workspace_manager, original_term.rows, buf_writer);
                } else {
                    try renderer.renderAll(active_workspace, &workspace_manager, original_term.rows, buf_writer);
                }

                try stdout_file.writeAll(output_fbs.getWritten());
            }
        }

        const active = active_workspace.activePane();

        // If the shell process has exited, return
        const result = c.waitpid(active.pty.pid, null, c.WNOHANG);
        if (result == active.pty.pid) {
            return;
        }
    }
}

/// Call this function once terminal changes are complete.
fn refreshScreen(
    fbs: *std.io.FixedBufferStream([]u8),
    renderer: *Renderer,
    active_workspace: *Workspace,
    workspace_manager: *WorkspaceManager,
    original_rows: u16,
    stdout_file: std.fs.File,
    comptime clear: bool,
) !void {
    fbs.reset();
    if (clear) {
        fbs.writer().writeAll("\x1b[2J") catch {};
    }
    renderer.invalidate();
    try renderer.renderAll(active_workspace, workspace_manager, original_rows, fbs.writer());
    try stdout_file.writeAll(fbs.getWritten());
}

/// Refresh screen with copy mode overlay
fn refreshScreenCopyMode(
    fbs: *std.io.FixedBufferStream([]u8),
    renderer: *Renderer,
    active_workspace: *Workspace,
    workspace_manager: *WorkspaceManager,
    original_rows: u16,
    stdout_file: std.fs.File,
    cm: *const CopyMode,
) !void {
    fbs.reset();
    const writer = fbs.writer();
    renderer.invalidate();
    try renderer.renderAllWithMode(active_workspace, workspace_manager, original_rows, writer, "COPY");
    try renderer.renderCopyModeOverlay(active_workspace.activePane(), cm, writer);
    try stdout_file.writeAll(fbs.getWritten());
}

/// Send text to the outer terminal's clipboard via OSC 52
fn setOsc52Clipboard(stdout_file: std.fs.File, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(text.len);

    // Build the OSC 52 sequence: \x1b]52;c;<base64>\x1b\\
    // Use a stack buffer for small payloads, heap for large
    var stack_buf: [4096]u8 = undefined;
    const header = "\x1b]52;c;";
    const trailer = "\x1b\\";
    const total_len = header.len + encoded_len + trailer.len;

    if (total_len <= stack_buf.len) {
        @memcpy(stack_buf[0..header.len], header);
        _ = encoder.encode(stack_buf[header.len .. header.len + encoded_len], text);
        @memcpy(stack_buf[header.len + encoded_len ..][0..trailer.len], trailer);
        try stdout_file.writeAll(stack_buf[0..total_len]);
    } else {
        // For very large payloads, write in parts
        try stdout_file.writeAll(header);
        // Encode in chunks
        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_end = @min(offset + 2048, text.len);
            // Base64 encode needs to work on 3-byte boundaries for intermediate chunks
            const aligned_end = if (chunk_end < text.len)
                offset + ((chunk_end - offset) / 3) * 3
            else
                chunk_end;
            if (aligned_end == offset) break;
            const chunk = text[offset..aligned_end];
            const chunk_enc_len = encoder.calcSize(chunk.len);
            var enc_buf: [2800]u8 = undefined; // 2048 * 4/3 + padding
            _ = encoder.encode(enc_buf[0..chunk_enc_len], chunk);
            try stdout_file.writeAll(enc_buf[0..chunk_enc_len]);
            offset = aligned_end;
        }
        try stdout_file.writeAll(trailer);
    }
}
