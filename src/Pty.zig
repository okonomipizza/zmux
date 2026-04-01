const std = @import("std");
const posix = std.posix;
const c = @import("c.zig").c;

/// Pseudoterminal
pub const Pty = @This();

const MAX_SNAME: usize = 1000;

master_fd: posix.fd_t,
pid: posix.pid_t,

/// Create a new PTY and run the shell
/// Use termios to create a shell with the same configuration as the shell
/// that invoked zmux
pub fn init(cols: u16, row: u16, termios: c.termios) !Pty {
    var slave_name: [MAX_SNAME:0]u8 = undefined;
    const ws = std.posix.winsize{
        .col = cols,
        .row = row,
        .xpixel = 0,
        .ypixel = 0,
    };

    return try ptyFork(&slave_name, termios, ws);
}

pub fn deinit(self: *Pty) void {
    _ = c.close(self.master_fd);
    _ = c.kill(self.pid, c.SIGHUP);
}

fn ptyMasterOpen(slave_name: [:0]u8) !posix.fd_t {
    const mfd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
    if (mfd < 0) return error.OpenPtFailed;
    errdefer _ = std.c.close(mfd);

    if (c.grantpt(mfd) < 0) return error.GrantPtFailed;
    if (c.unlockpt(mfd) < 0) return error.UnlockPtFailed;

    const sname = c.ptsname(mfd) orelse return error.PtsnameFailed;
    const len = std.mem.len(sname);

    if (len >= slave_name.len) return error.SlaveNameTooLong;

    @memcpy(slave_name[0..len], sname[0..len]);
    slave_name[len] = 0;

    return @intCast(mfd);
}

fn ptyFork(slave_name: [:0]u8, termios: c.termios, ws: std.posix.winsize) !Pty {
    const mfd = try ptyMasterOpen(slave_name);
    errdefer _ = std.c.close(mfd);

    const child_pid = c.fork();
    if (child_pid < 0) return error.ForkFailed;

    if (child_pid != 0) {
        // parent
        return Pty{
            .master_fd = @intCast(mfd),
            .pid = @intCast(child_pid),
        };
    }

    // child
    if (c.setsid() < 0) std.process.exit(1);

    // child process does not need master fd
    _ = std.c.close(mfd);

    const slave_fd = c.open(slave_name.ptr, c.O_RDWR);
    if (slave_fd < 0) std.process.exit(1);

    _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));
    _ = c.tcsetattr(slave_fd, c.TCSANOW, &termios);
    _ = c.ioctl(slave_fd, c.TIOCSWINSZ, &ws);

    _ = std.c.dup2(slave_fd, c.STDIN_FILENO);
    _ = std.c.dup2(slave_fd, c.STDOUT_FILENO);
    _ = std.c.dup2(slave_fd, c.STDERR_FILENO);
    _ = c.close(slave_fd);

    _ = c.setenv("TERM", "xterm-256color", 1);

    const shell: [*:0]const u8 = c.getenv("SHELL") orelse "/bin/bash";
    const i_flag: [*:0]const u8 = "-i";
    _ = c.execlp(shell, shell, i_flag, @as([*c]u8, null));

    std.process.exit(1);
}

pub fn write(self: *Pty, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = c.write(self.master_fd, buf[written..].ptr, buf[written..].len);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
    const ws = posix.winsize{
        .col = cols,
        .row = rows,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws) < 0) {
        return error.ResizeFailed;
    }
}
