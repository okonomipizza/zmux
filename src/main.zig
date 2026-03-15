const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const zmux = @import("zmux");
const ghostty_vt = @import("ghostty-vt");

const Renderer = @import("Renderer.zig");

const c = @import("c.zig").c;

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

    try spawnServer(alloc);
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

fn spawnServer(alloc: std.mem.Allocator) !void {
    // 画面クリア
    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll("\x1b[2J\x1b[H");

    var stdout_buf: [65536]u8 = undefined;
    var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
    const buf_writer = stdout_fbs.writer();

    const original_term = getTermSize();
    const term = .{
        .cols = original_term.cols,
        .rows = original_term.rows - 1, // workspace monitor用
    };

    try enableRawMode();
    defer disableRawMode();

    var workspace_manager = try WorkspaceManager.init(alloc, term.cols, term.rows, original_termios);
    defer workspace_manager.deinit(alloc);

    var active_workspace: *Workspace = workspace_manager.getActiveWorkspace() orelse return;

    var renderer = try Renderer.init(alloc, term.cols, term.rows);
    defer renderer.deinit();

    // epollセットアップ
    const epoll_fd = c.epoll_create1(0);
    if (epoll_fd < 0) return error.EpollCreateFailed;
    defer _ = c.close(epoll_fd);

    try epollAdd(epoll_fd, c.STDIN_FILENO, c.EPOLLIN);
    // 最初のpaneをepollの監視リストに追加
    try epollAdd(epoll_fd, active_workspace.active_pane.pty.master_fd, c.EPOLLIN);

    var events: [16]c.epoll_event = undefined;
    var buf: [BUF_SIZE]u8 = undefined;
    var prefix_mode: bool = false;

    while (true) {
        const n = c.epoll_wait(epoll_fd, &events, @intCast(events.len), -1);
        if (n < 0) continue;

        for (events[0..@intCast(n)]) |ev| {
            const fd = ev.data.fd;

            if (fd == c.STDIN_FILENO) {
                // 標準入力からキー入力を読み取りアクティブPaneへ送信
                const nr = c.read(c.STDIN_FILENO, &buf, BUF_SIZE);
                if (nr <= 0) return;
                const input = buf[0..@intCast(nr)];

                // Ctrl-b (0x02)
                if (input.len == 1 and input[0] == 0x02) {
                    prefix_mode = true;
                    continue;
                }

                if (prefix_mode) {
                    prefix_mode = false;
                    switch (input[0]) {
                        '\r' => {
                            // enter でprefix modeから抜ける
                        },
                        'n' => {
                            try workspace_manager.appendWorkspace(alloc);
                            // 新しいワークスペースに切り替え
                            workspace_manager.switchWorkspace(workspace_manager.workspaces.items.len - 1);
                            active_workspace = workspace_manager.getActiveWorkspace() orelse return;
                            // 新ワークスペースの最初のペインをepoll登録
                            try epollAdd(epoll_fd, active_workspace.active_pane.pty.master_fd, c.EPOLLIN);

                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'l' => {
                            active_workspace = workspace_manager.nextWorkspace() orelse return;
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);

                            // l, h 連打でワークスペースを選べるように
                            prefix_mode = true;
                        },
                        'h' => {
                            active_workspace = workspace_manager.prevWorkspace() orelse return;
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);

                            // l, h 連打でワークスペースを選べるように
                            prefix_mode = true;
                        },
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                            const idx = input[0] - '1';
                            if (idx < workspace_manager.workspaces.items.len) {
                                workspace_manager.switchWorkspace(idx);
                                active_workspace = workspace_manager.getActiveWorkspace() orelse return;
                                try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            }
                        },
                        '|' => {
                            const new_fd = try active_workspace.splitPane(alloc, .vertical);
                            try epollAdd(epoll_fd, new_fd, c.EPOLLIN);

                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        '-' => {
                            const new_fd = try active_workspace.splitPane(alloc, .horizontal);
                            try epollAdd(epoll_fd, new_fd, c.EPOLLIN);

                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'x' => {
                            try active_workspace.closePane(alloc);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                        },
                        'j' => {
                            active_workspace.nextPane();
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        'k' => {
                            active_workspace.prevPane();
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, false);
                            prefix_mode = true;
                        },
                        '>' => {
                            try active_workspace.resizePane(alloc, 0.05);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        '<' => {
                            try active_workspace.resizePane(alloc, -0.05);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'J' => {
                            try active_workspace.swapPane(alloc, .down);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'H' => {
                            try active_workspace.swapPane(alloc, .left);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'L' => {
                            try active_workspace.swapPane(alloc, .right);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'K' => {
                            try active_workspace.swapPane(alloc, .up);
                            try refreshScreen(&stdout_fbs, &renderer, active_workspace, &workspace_manager, original_term.rows, stdout_file, true);
                            prefix_mode = true;
                        },
                        'q' => {
                            return;
                        },
                        else => {
                            const active = active_workspace.activePane();
                            active.pty.write(input) catch continue;
                        },
                    }
                    continue;
                }
                // 通常入力はアクティブペインへ送信
                const active = active_workspace.activePane();
                active.pty.write(input) catch continue;
            } else {
                // paneから受け取った情報を出力
                const pane = active_workspace.getPane(ev.data.fd) orelse continue;
                const nr = c.read(pane.pty.master_fd, &buf, BUF_SIZE);
                if (nr <= 0) return;

                try pane.feed(buf[0..@intCast(nr)]);

                stdout_fbs.reset();
                try renderer.renderAll(active_workspace, &workspace_manager, original_term.rows, buf_writer);
                try stdout_file.writeAll(stdout_fbs.getWritten());
            }
        }

        const active = active_workspace.activePane();
        // shellが終了していたら抜ける
        const result = c.waitpid(active.pty.pid, null, c.WNOHANG);
        if (result == active.pty.pid) {
            return;
        }
    }
}

fn refreshScreen(
    stdout_fbs: *std.io.FixedBufferStream([]u8),
    renderer: *Renderer,
    active_workspace: *Workspace,
    workspace_manager: *WorkspaceManager,
    original_rows: u16,
    stdout_file: std.fs.File,
    comptime clear: bool,
) !void {
    stdout_fbs.reset();
    if (clear) {
        stdout_fbs.writer().writeAll("\x1b[2J") catch {};
    }
    renderer.invalidate();
    try renderer.renderAll(active_workspace, workspace_manager, original_rows, stdout_fbs.writer());
    try stdout_file.writeAll(stdout_fbs.getWritten());
}
