const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const zmux = @import("zmux");
const clap = @import("clap");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "600");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/wait.h");
});

const Pty = @import("Pty.zig");
const StatusBar = @import("StatusBar.zig");

var original_termios: c.termios = undefined;
const BUF_SIZE: usize = 4096;

fn enableRawMode() !void {
    if (c.tcgetattr(c.STDIN_FILENO, &original_termios) < 0)
        return error.TcgetattrFailed;

    var raw = original_termios;

    // non-canonical + エコーOFF + シグナル無効
    raw.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ISIG | c.IEXTEN);
    // CR→LF変換など無効
    raw.c_iflag &= ~@as(c_uint, c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP);
    // 出力変換無効
    // raw.c_oflag &= ~@as(c_uint, c.OPOST);
    // 8bit
    raw.c_cflag |= @as(c_uint, c.CS8);
    // 1文字来たら即返す、タイムアウトなし
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) < 0)
        return error.TcsetattrFailed;
}

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

    try spawnServer(init.io);
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

fn spawnServer(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const term = getTermSize();
    var pty = try Pty.init(term.cols, term.rows);
    defer pty.deinit();

    // enableRawMode の前に追加
    try enableRawMode();
    defer disableRawMode();

    // スクロール領域をrows-1行に制限 + 初回描画
    const bar = StatusBar.init(term.cols, term.rows);
    try StatusBar.setScrollRegion(term.rows, stdout_writer);
    try bar.draw(stdout_writer);
    try stdout_writer.flush();

    // 終了時にスクロール領域をリセット
    defer {
        StatusBar.resetScrollRegion(stdout_writer) catch {};
        stdout_writer.flush() catch {};
    }

    // epollセットアップ
    const epoll_fd = c.epoll_create1(0);
    if (epoll_fd < 0) return error.EpollCreateFailed;
    defer _ = c.close(epoll_fd);

    try epollAdd(epoll_fd, c.STDIN_FILENO, c.EPOLLIN);
    try epollAdd(epoll_fd, pty.master_fd, c.EPOLLIN);

    var buf: [BUF_SIZE]u8 = undefined;
    var events: [4]c.epoll_event = undefined;

    // イベントループ
    while (true) {
        const n = c.epoll_wait(epoll_fd, &events, 4, -1);
        if (n < 0) continue;

        for (events[0..@intCast(n)]) |ev| {
            const fd = ev.data.fd;

            if (fd == c.STDIN_FILENO) {
                // キー入力 → PTY masterへ
                const nr = c.read(c.STDIN_FILENO, &buf, BUF_SIZE);
                if (nr <= 0) {
                    return;
                }
                const valid_nr: usize = @intCast(nr);
                // PTY master へ書き込む
                pty.write(buf[0..valid_nr]) catch return;
            } else if (fd == pty.master_fd) {
                // 入力を受け取る
                const nr = c.read(pty.master_fd, &buf, BUF_SIZE);
                if (nr <= 0) {
                    return;
                }
                try stdout_writer.writeAll(buf[0..@intCast(nr)]);
                try bar.draw(stdout_writer);
                try stdout_writer.flush();
            }
        }

        // shellが終了していたら抜ける
        const result = c.waitpid(pty.pid, null, c.WNOHANG);
        if (result == pty.pid) {
            return;
        }
    }
}
