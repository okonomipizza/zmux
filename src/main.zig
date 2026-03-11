const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const zmux = @import("zmux");
const clap = @import("clap");

const c = @import("c.zig").c;

const Pty = @import("Pty.zig");
const StatusBar = @import("StatusBar.zig");
const Workspace = @import("Workspace.zig");

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

pub fn main(init: std.process.Init) !void {
    // zig-clap の設定
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-v, --version         Display zmux version.
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});

    try spawnServer(init.gpa, init.io);
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

fn spawnServer(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const term = getTermSize();

    try enableRawMode();
    defer disableRawMode();

    var workspace = try Workspace.init(allocator, term.cols, term.rows, original_termios);
    defer workspace.deinit(allocator);

    // epollセットアップ
    const event_count = 1 + workspace.panes.items.len; // stdin + number of panes
    var events = try allocator.alloc(c.epoll_event, event_count);
    defer allocator.free(events);

    const epoll_fd = c.epoll_create1(0);
    if (epoll_fd < 0) return error.EpollCreateFailed;
    defer _ = c.close(epoll_fd);

    try epollAdd(epoll_fd, c.STDIN_FILENO, c.EPOLLIN);
    // 最初のpaneをepollの監視リストに追加
    try epollAdd(epoll_fd, workspace.panes.items[0].pty.master_fd, c.EPOLLIN);

    var buf: [BUF_SIZE]u8 = undefined;

    while (true) {
        const n = c.epoll_wait(epoll_fd, events.ptr, @intCast(events.len), -1);
        if (n < 0) continue;

        const active_pane = workspace.activePane();

        for (events[0..@intCast(n)]) |ev| {
            const fd = ev.data.fd;

            if (fd == c.STDIN_FILENO) {
                // 標準入力からキー入力を読み取りアクティブPaneへ送信
                const nr = c.read(c.STDIN_FILENO, &buf, BUF_SIZE);
                if (nr <= 0) return;
                active_pane.pty.write(buf[0..@intCast(nr)]) catch return;
            } else {
                // paneから受け取った情報を出力
                const pane = workspace.getPane(ev.data.fd) orelse return error.FdNotFoundInWorkspace;
                const nr = c.read(pane.pty.master_fd, &buf, BUF_SIZE);
                if (nr <= 0) return;

                try stdout_writer.writeAll(buf[0..@intCast(nr)]);
                try stdout_writer.flush();
            }
        }

        // shellが終了していたら抜ける
        const result = c.waitpid(active_pane.pty.pid, null, c.WNOHANG);
        if (result == active_pane.pty.pid) {
            return;
        }
    }
}
