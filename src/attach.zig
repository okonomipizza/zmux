/// Client-side attach: connects to the zmux server and proxies
/// stdin/stdout over the Unix socket using the wire protocol.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("c.zig").c;
const protocol = @import("protocol.zig");
const Stream = @import("stream.zig");

const BUF_SIZE = 4096;

var original_termios: c.termios = undefined;

fn enableRawMode() !void {
    if (c.tcgetattr(c.STDIN_FILENO, &original_termios) < 0)
        return error.TcgetattrFailed;

    var raw = original_termios;
    raw.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ISIG | c.IEXTEN);
    raw.c_iflag &= ~@as(c_uint, c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP);
    raw.c_cflag |= @as(c_uint, c.CS8);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) < 0)
        return error.TcsetattrFailed;
}

fn disableRawMode() void {
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &original_termios);
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

pub fn attach(alloc: std.mem.Allocator, socket_path: []const u8, session_name: []const u8) !void {
    // Connect to server.
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    const address = try std.net.Address.initUnix(socket_path);
    try posix.connect(sock, &address.any, address.getOsSockLen());

    // Get terminal size and send attach request.
    const size = getTermSize();
    var msg_buf: [BUF_SIZE]u8 = undefined;

    const stream_buf = try alloc.alloc(u8, BUF_SIZE);
    defer alloc.free(stream_buf);
    var stream = Stream.init(stream_buf);

    {
        const payload = try (protocol.ClientMsg{ .attach = .{
            .cols = size.cols,
            .rows = size.rows,
            .session_name = session_name,
        } }).encode(&msg_buf);
        try stream.writeMessage(payload, sock);
    }

    // Wait for attached confirmation.
    {
        const frame = try stream.readMessage(sock);
        const resp = try protocol.ServerMsg.decode(frame);
        switch (resp) {
            .attached => {},
            .err => |errmsg| {
                std.debug.print("server error: {s}\n", .{errmsg});
                return error.ServerError;
            },
            .output => {},
        }
    }

    // Enter raw mode.
    try enableRawMode();
    defer disableRawMode();

    // Clear screen.
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("\x1b[2J\x1b[H");

    // Setup epoll: stdin + socket + signalfd(SIGWINCH).
    const epfd = try posix.epoll_create1(0);
    defer posix.close(epfd);

    {
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = posix.STDIN_FILENO } };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, posix.STDIN_FILENO, &ev);
    }
    {
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .fd = sock } };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock, &ev);
    }

    // Block SIGWINCH and create signalfd for resize detection.
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.WINCH);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sig_fd = linux.signalfd(-1, &mask, 0);
    if (@as(isize, @bitCast(sig_fd)) < 0) return error.SignalfdFailed;
    const sig_fd_i: posix.fd_t = @intCast(sig_fd);
    defer posix.close(sig_fd_i);
    {
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = sig_fd_i } };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sig_fd_i, &ev);
    }

    // Event loop.
    var events: [16]linux.epoll_event = undefined;
    var buf: [BUF_SIZE]u8 = undefined;

    while (true) {
        const n = posix.epoll_wait(epfd, &events, -1);

        for (events[0..n]) |ev| {
            const fd = ev.data.fd;

            if (fd == posix.STDIN_FILENO) {
                // Forward stdin to server as input messages.
                const nr = posix.read(posix.STDIN_FILENO, &buf) catch return;
                if (nr == 0) return;
                const payload = try (protocol.ClientMsg{ .input = buf[0..nr] }).encode(&msg_buf);
                stream.writeMessage(payload, sock) catch return;
            } else if (fd == sock) {
                // Server message → write output to stdout.
                if (ev.events & linux.EPOLL.RDHUP != 0) {
                    std.debug.print("server disconnected\n", .{});
                    return;
                }
                const frame = stream.readMessage(sock) catch |err| switch (err) {
                    error.Closed => return,
                    else => return err,
                };
                const msg = protocol.ServerMsg.decode(frame) catch continue;
                switch (msg) {
                    .output => |data| {
                        stdout.writeAll(data) catch return;
                    },
                    .attached => {},
                    .err => |errmsg| {
                        std.debug.print("server error: {s}\n", .{errmsg});
                    },
                }
            } else if (fd == sig_fd_i) {
                // SIGWINCH → send resize message.
                var siginfo: linux.signalfd_siginfo = undefined;
                _ = posix.read(sig_fd_i, std.mem.asBytes(&siginfo)) catch continue;
                const new_size = getTermSize();
                const payload = try (protocol.ClientMsg{ .resize = .{
                    .cols = new_size.cols,
                    .rows = new_size.rows,
                } }).encode(&msg_buf);
                stream.writeMessage(payload, sock) catch {};
            }
        }
    }
}
