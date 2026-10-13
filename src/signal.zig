//! Signal delivery as a file descriptor.
//!
//! zmux has to notice `SIGWINCH`, because the terminal zmux is running inside is
//! not the terminal the programs in sessions are attached to. When the user
//! resizes their window the kernel signals the *client*, not the `vim` on the far
//! side of a pty, so the client has to read the new size and pass it on.
//!
//! `signalfd` is used rather than a handler for one reason: it turns a signal into
//! an ordinary readable descriptor, which drops straight into the epoll loop that
//! is already there. A handler would have to communicate with that loop through an
//! atomic flag, and the loop would then have to poll the flag, which either blocks
//! for up to some timeout or busy-loops. zmux's loop has no timeout, because one
//! would wake it forever for nothing.
//!
//! The signal must be *blocked* before the signalfd is created. A blocked signal
//! is not delivered to its default action and is not dropped; it stays pending
//! until a signalfd reads it. Without the block, the default action is taken and
//! the signalfd may never see anything.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// The descriptor could not be created or read.
    SyscallFailed,
};

/// A set of signals delivered through a descriptor.
pub const Source = struct {
    fd: i32,
    /// The signals this source claims, so they can be unblocked again.
    mask: std.posix.sigset_t,

    /// Claim `signals` and return a descriptor that reports them.
    ///
    /// The signals are blocked in this process first. Blocking is per-thread, so
    /// in a program with several threads the mask would have to be set on each;
    /// zmux's loops are single-threaded, and the threads the standard library
    /// starts for I/O never install a signalfd.
    ///
    /// The mask type is `std.posix.sigset_t` rather than `std.os.linux.sigset_t`.
    /// These are not the same type when linking libc: the kernel's is a 64-byte
    /// array of `c_ulong`, while glibc's is a smaller struct, and `std.posix`
    /// resolves to the libc one so that its own wrappers and the raw syscall agree
    /// on what they are passing.
    pub fn init(signals: []const linux.SIG) Error!Source {
        var mask = std.posix.sigemptyset();
        for (signals) |signal| std.posix.sigaddset(&mask, signal);

        // SIG_BLOCK adds these to the current mask rather than replacing it, so
        // anything already blocked stays blocked.
        std.posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

        const fd = std.posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC) catch
            return Error.SyscallFailed;

        return .{ .fd = fd, .mask = mask };
    }

    pub fn deinit(self: *Source) void {
        _ = linux.close(self.fd);
        // Unblocking on the way out leaves the process's disposition as it was
        // found, which matters if zmux is ever run in-process by a test.
        std.posix.sigprocmask(linux.SIG.UNBLOCK, &self.mask, null);
    }

    /// Read and discard whatever is pending.
    ///
    /// The signal number is not inspected: this is called because a descriptor in
    /// the epoll set became readable, and for `SIGWINCH` the payload carries no
    /// size anyway. The new size is read from the terminal, which is the only
    /// thing that knows it.
    ///
    /// Returns how many signals were consumed, which is what the caller uses to
    /// decide whether anything needs re-reading.
    pub fn drain(self: Source) Error!usize {
        var buffer: [8]linux.signalfd_siginfo = undefined;
        var consumed: usize = 0;

        while (true) {
            const read = linux.read(
                self.fd,
                @ptrCast(&buffer),
                @sizeOf(linux.signalfd_siginfo) * buffer.len,
            );
            switch (linux.errno(read)) {
                .SUCCESS => {
                    if (read == 0) return consumed;
                    consumed += read / @sizeOf(linux.signalfd_siginfo);
                    // Looping once more is harmless and covers a signal that
                    // arrived while this was running.
                },
                .AGAIN => return consumed,
                .INTR => continue,
                else => return Error.SyscallFailed,
            }
        }
    }
};

/// Whether `signal` is present in `mask`.
///
/// Signal numbers are 1-based: a signal set uses bit `N-1` for signal `N`, so the
/// enum value is decremented before it is used as an index. Getting this wrong is
/// off by one and silently reports the neighbouring signal.
///
/// The element type is taken from the mask rather than assumed, because the two
/// `sigset_t` definitions in the standard library have different widths.
pub fn isBlocked(mask: std.posix.sigset_t, signal: linux.SIG) bool {
    const Element = std.meta.Elem(std.posix.sigset_t);
    const index = @intFromEnum(signal) - 1;
    const bits = @bitSizeOf(Element);
    const word = index / bits;
    const bit = index % bits;
    return (mask[word] & (@as(Element, 1) << @intCast(bit))) != 0;
}

test "a signalfd reports a signal sent to this process" {
    // SIGWINCH is used because its default action is to be ignored, so a mistake
    // in this test cannot kill the test runner.
    var source = try Source.init(&.{linux.SIG.WINCH});
    defer source.deinit();

    try std.testing.expect(isBlocked(source.mask, linux.SIG.WINCH));

    // Nothing pending yet, and the descriptor is non-blocking, so this drains
    // zero rather than blocking.
    try std.testing.expectEqual(@as(usize, 0), try source.drain());

    // A blocked signal stays pending instead of being delivered, and the signalfd
    // is how it is collected.
    std.posix.raise(linux.SIG.WINCH) catch return error.RaiseFailed;

    var consumed: usize = 0;
    var attempts: usize = 0;
    while (attempts < 1000 and consumed == 0) : (attempts += 1) {
        consumed = try source.drain();
        if (consumed == 0) {
            const request = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = linux.nanosleep(&request, null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), consumed);
}

test "signals that were not claimed are left unblocked" {
    var source = try Source.init(&.{linux.SIG.WINCH});
    defer source.deinit();

    try std.testing.expect(isBlocked(source.mask, linux.SIG.WINCH));
    try std.testing.expect(!isBlocked(source.mask, linux.SIG.TERM));
}

test "the mask is cleared on deinit" {
    {
        var source = try Source.init(&.{linux.SIG.WINCH});
        defer source.deinit();
        try std.testing.expect(isBlocked(source.mask, linux.SIG.WINCH));
    }

    // After the source is gone the signal is unblocked again, so the process is
    // left the way it was found.
    var current: std.posix.sigset_t = std.posix.sigemptyset();
    std.posix.sigprocmask(linux.SIG.SETMASK, null, &current);
    try std.testing.expect(!isBlocked(current, linux.SIG.WINCH));
}
