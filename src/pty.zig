//! PTY allocation and child process spawning.
//!
//! Zig 0.16 removed nearly all of `std.posix`, so this module is deliberately
//! split between the surviving checked wrappers (`std.posix.openatZ`, `read`)
//! and the raw syscalls in `std.os.linux`. Raw calls return `usize` and report
//! failure as a negative errno, so every one of them is decoded with
//! `linux.errno` before the result is narrowed to the type we want.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// The kernel reported a failure for a raw syscall.
    SyscallFailed,
    /// The child could not be started.
    SpawnFailed,
    /// The slave side of the pty closed.
    Closed,
};

/// A pty pair plus the child process attached to its slave side.
///
/// The owner reads and writes `master`. The slave is closed in the parent
/// immediately after the fork, so the master is the only handle kept here.
pub const Pty = struct {
    master: i32,
    child: linux.pid_t,

    /// Open a new pty pair and start `argv` on the slave side.
    ///
    /// `argv` and `envp` are the null-terminated vectors `execve` wants, built
    /// by the caller as `[_:null]?[*:0]const u8`. The slave is opened here, in
    /// the parent, so that a failure to open it comes back as an ordinary
    /// error rather than needing a channel out of the child.
    pub fn spawn(
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        size: Size,
    ) Error!Pty {
        const master = try openMaster();
        errdefer _ = linux.close(master);

        const slave = try openSlave(master);
        // The child inherits its own descriptor via dup2, so the parent's copy
        // is no longer needed once the fork has happened.
        defer _ = linux.close(slave);

        try setSize(master, size);

        const pid = try fork();
        if (pid == 0) {
            // Child. This runs in a forked copy of the process, so it may only
            // call async-signal-safe things. Anything that allocates is out.
            childExec(master, slave, argv, envp);
        }

        return .{ .master = master, .child = pid };
    }

    pub fn deinit(self: *Pty) void {
        _ = linux.close(self.master);
    }

    pub fn setNonBlocking(self: Pty) void {
        makeNonBlocking(self.master);
    }

    /// Resize the pty. The kernel sends SIGWINCH to the foreground process
    /// group, which is what makes full-screen programs re-layout.
    pub fn setWindowSize(self: Pty, size: Size) Error!void {
        try setSize(self.master, size);
    }

    /// Read available output.
    ///
    /// A closed slave surfaces as `EIO`, which `std.posix.read` reports as
    /// `error.InputOutput`. Nothing distinguishes it from a real I/O error at
    /// this layer, but in practice it is how a pty reports end of file, so it
    /// is mapped to `error.Closed` for the caller.
    pub fn read(self: Pty, buffer: []u8) Error!usize {
        return std.posix.read(self.master, buffer) catch |err| switch (err) {
            error.WouldBlock => return 0,
            error.InputOutput => return Error.Closed,
            else => return Error.SyscallFailed,
        };
    }

    pub fn write(self: Pty, bytes: []const u8) Error!usize {
        const written = linux.write(self.master, bytes.ptr, bytes.len);
        return switch (linux.errno(written)) {
            .SUCCESS => written,
            .AGAIN => 0,
            else => Error.SyscallFailed,
        };
    }

    /// Reap the child if it has exited, without blocking.
    ///
    /// Returns the exit status when the child was collected, or null when it
    /// is still running.
    pub fn reap(self: Pty) ?ExitStatus {
        var status: u32 = 0;
        const result = linux.waitpid(self.child, &status, linux.W.NOHANG);
        if (linux.errno(result) != .SUCCESS) return null;
        // A pid of zero means the child exists but has not changed state.
        if (result == 0) return null;
        return decodeStatus(status);
    }
};

pub const Size = struct {
    rows: u16,
    cols: u16,
    /// Pixel dimensions, used by programs that draw graphics. Zero is fine.
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const ExitStatus = struct {
    code: u8,
    signaled: bool,
    signal: u32,
};

fn decodeStatus(status: u32) ExitStatus {
    if (linux.W.IFSIGNALED(status)) {
        return .{ .code = 0, .signaled = true, .signal = @intFromEnum(linux.W.TERMSIG(status)) };
    }
    return .{ .code = linux.W.EXITSTATUS(status), .signaled = false, .signal = 0 };
}

/// Open the master side of a new pty.
///
/// `O.NOCTTY` keeps the server from adopting the pty as its own controlling
/// terminal, which would break the moment the server needed its stdin back.
fn openMaster() Error!i32 {
    const fd = std.posix.openatZ(
        linux.AT.FDCWD,
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    ) catch return Error.SyscallFailed;
    return fd;
}

/// Unlock the slave and open it by its `/dev/pts/N` path.
fn openSlave(master: i32) Error!i32 {
    // The slave starts locked; unlocking is what allows it to be opened.
    var unlock: c_int = 0;
    try ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock));

    var number: c_uint = 0;
    try ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number));

    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/dev/pts/{d}", .{number}) catch
        return Error.SyscallFailed;

    // The slave must NOT be opened with NOCTTY: the child opens it as its
    // controlling terminal, which the kernel refuses for a NOCTTY descriptor.
    const fd = std.posix.openatZ(
        linux.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDWR },
        0,
    ) catch return Error.SyscallFailed;
    return fd;
}

fn setSize(fd: i32, size: Size) Error!void {
    const ws = std.posix.winsize{
        .row = size.rows,
        .col = size.cols,
        .xpixel = size.xpixel,
        .ypixel = size.ypixel,
    };
    try ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws));
}

fn ioctl(fd: i32, request: u32, argument: usize) Error!void {
    const result = linux.ioctl(fd, request, argument);
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        else => Error.SyscallFailed,
    };
}

fn makeNonBlocking(fd: i32) void {
    const current = linux.fcntl(fd, linux.F.GETFL, 0);
    var flags: linux.O = @bitCast(@as(u32, @truncate(current)));
    flags.NONBLOCK = true;
    _ = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(flags)));
}

/// Sleep for a short interval.
///
/// Zig 0.16 has no `std.Thread.sleep`; the sleep entry points all live on
/// `std.Io`, which this module deliberately does not depend on.
fn sleepMillis(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}

fn fork() Error!linux.pid_t {
    const result = linux.fork();
    switch (linux.errno(result)) {
        .SUCCESS => {},
        else => return Error.SpawnFailed,
    }
    // A raw fork returns 0 in the child and the pid in the parent. The value
    // arrives as a usize, so it round-trips through isize to recover the sign.
    const pid: linux.pid_t = @intCast(@as(isize, @bitCast(result)));
    return pid;
}

/// Become the session leader, adopt the pty, and exec.
///
/// Never returns. Every step past the fork must avoid allocation, so the
/// argument vectors are passed through unchanged from the caller.
fn childExec(
    master: i32,
    slave: i32,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    _ = linux.close(master);

    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(1);

    // Making the pty the controlling terminal requires being a session leader
    // first, which setsid above just did. The zero argument means "do not
    // steal the terminal from another session".
    if (linux.errno(linux.ioctl(slave, linux.T.IOCSCTTY, 0)) != .SUCCESS) linux.exit(1);

    _ = linux.dup2(slave, 0);
    _ = linux.dup2(slave, 1);
    _ = linux.dup2(slave, 2);
    if (slave > 2) _ = linux.close(slave);

    // argv[0] is the program to execute; the rest is its argument list.
    _ = linux.execve(argv[0].?, argv, envp);

    // exec only returns on failure.
    linux.exit(127);
}

test "open a pty pair and resize it" {
    // Exercises master allocation, IOCSPTLCK, IOCGPTN, the slave open and
    // TIOCSWINSZ, without starting a child.
    const master = try openMaster();
    defer _ = linux.close(master);

    const slave = try openSlave(master);
    defer _ = linux.close(slave);

    try setSize(master, .{ .rows = 24, .cols = 80 });

    var got: std.posix.winsize = undefined;
    try ioctl(master, linux.T.IOCGWINSZ, @intFromPtr(&got));
    try std.testing.expectEqual(@as(u16, 24), got.row);
    try std.testing.expectEqual(@as(u16, 80), got.col);
}

test "spawn a child on the pty and read its output" {
    const argv = [_:null]?[*:0]const u8{ "/bin/echo", "pty works" };
    const envp = [_:null]?[*:0]const u8{"PATH=/bin:/usr/bin"};

    var pty = try Pty.spawn(&argv, &envp, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();
    pty.setNonBlocking();

    // Read until the slave closes. The child's output is only a few bytes, but
    // the read may race with its exit, so poll a bounded number of times.
    var collected: [256]u8 = undefined;
    var len: usize = 0;
    var attempts: usize = 0;
    while (attempts < 10_000 and len == 0) : (attempts += 1) {
        len = pty.read(&collected) catch |err| switch (err) {
            Error.Closed => break,
            else => return err,
        };
        if (len == 0) sleepMillis(1);
    }

    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, collected[0..len], "pty works") != null);

    const status = pty.reap() orelse return error.TestChildNotReaped;
    try std.testing.expectEqual(@as(u8, 0), status.code);
    try std.testing.expect(!status.signaled);
}
