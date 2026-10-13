//! Unix domain sockets and the message framing the client and server speak.
//!
//! This is written on the raw syscalls in `std.os.linux` rather than on
//! `std.Io.net`, for one specific reason: everything `std.Io.net` builds is
//! blocking. Its `netRead` retries `EINTR` and never surfaces `EAGAIN`, and
//! `accept` loops until a connection arrives. That is the right shape for a
//! thread-per-connection program and the wrong shape for an epoll loop, where
//! every fd must return immediately with nothing to report. The fds here are
//! therefore non-blocking from the moment they are created, and callers are
//! expected to consult the readiness epoll already gave them.
//!
//! Framing is a four-byte little-endian length followed by that many bytes of
//! payload. The first payload byte is the message tag. A length of zero is not
//! a valid message, and a length above `max_message` is treated as a protocol
//! error rather than being allocated, so a peer cannot make the process
//! allocate an arbitrary amount of memory by sending one header.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// A raw syscall reported failure.
    SyscallFailed,
    /// The peer closed the connection, or the socket was hung up.
    Closed,
    /// A message header declared a length outside the permitted range.
    BadFrame,
    /// The address is too long for `sockaddr_un`.
    NameTooLong,
};

/// Largest message zmux will read from a peer.
///
/// The number bounds the allocation a single header can provoke. Pty output is
/// forwarded in chunks no larger than this, so it only has to exceed one read
/// from a pty.
pub const max_message = 1024 * 1024;

/// Largest payload that fits in one write without a partial write, so that the
/// writer can avoid holding partially sent messages.
pub const max_frame = 4 + max_message;

/// Largest socket path the kernel accepts, counting the terminating NUL.
///
/// This is the size of `sun_path`, which is where the limit comes from rather
/// than from any zmux policy. A path at or above this length cannot be encoded
/// at all, so it is rejected before an attempt is made.
pub const max_path = @sizeOf(@FieldType(linux.sockaddr.un, "path"));

/// The socket addresses zmux uses.
///
/// A unix socket is addressed by a path, but the kernel's own limit is on the
/// *encoded* size, and `sun_path` is only 108 bytes. Resolving the runtime
/// directory has to happen before that limit can be checked, which is why the
/// path is built by the caller and only validated here.
pub const Address = struct {
    /// The sockaddr_un buffer, plus the length that goes with it.
    storage: linux.sockaddr.un,
    length: linux.socklen_t,

    /// Build a filesystem address.
    ///
    /// Abstract addresses (leading NUL) are not supported: they have no
    /// directory to create and would not survive the socket file being removed
    /// and recreated by a different user.
    pub fn init(path: []const u8) Error!Address {
        if (path.len >= @sizeOf(@FieldType(linux.sockaddr.un, "path"))) {
            return Error.NameTooLong;
        }

        var address: Address = .{
            .storage = std.mem.zeroes(linux.sockaddr.un),
            .length = 0,
        };
        address.storage.family = linux.AF.UNIX;
        @memcpy(address.storage.path[0..path.len], path);
        address.storage.path[path.len] = 0;
        // The length the kernel wants is the offset of the path plus its
        // length, not the full struct, so that a trailing NUL is not part of
        // the name.
        address.length = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
        return address;
    }

    pub fn asSockaddr(self: *const Address) *const linux.sockaddr {
        return @ptrCast(&self.storage);
    }
};

/// A listening unix socket.
pub const Listener = struct {
    fd: i32,
    path: []const u8,

    /// Create a socket, bind it to `path`, and listen.
    ///
    /// A stale socket file is removed first. That is deliberate: the server
    /// takes the lock file as the marker of its own liveness, so reaching this
    /// point means the previous process is gone and its socket is a leftover.
    /// Removing a path that is not a socket would be wrong, so the check is
    /// left to the caller, which knows whether the server is running.
    pub fn listen(path: []const u8) Error!Listener {
        const address = try Address.init(path);

        const socket_raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
        if (linux.errno(socket_raw) != .SUCCESS) return Error.SyscallFailed;
        const fd: i32 = @intCast(socket_raw);
        errdefer _ = linux.close(fd);

        const bound = linux.bind(fd, address.asSockaddr(), address.length);
        if (linux.errno(bound) != .SUCCESS) return Error.SyscallFailed;

        const listened = linux.listen(fd, 64);
        if (linux.errno(listened) != .SUCCESS) return Error.SyscallFailed;

        makeNonBlocking(fd);
        return .{ .fd = fd, .path = path };
    }

    pub fn deinit(self: *Listener) void {
        _ = linux.close(self.fd);
    }

    /// Accept a pending connection.
    ///
    /// Returns null when the connection queue is empty, which is the normal
    /// outcome of a level-triggered epoll wakeup for more than one connection.
    pub fn accept(self: Listener) Error!?i32 {
        const accepted = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(accepted)) {
            .SUCCESS => {
                const fd: i32 = @intCast(accepted);
                makeNonBlocking(fd);
                return fd;
            },
            .AGAIN => return null,
            else => return Error.SyscallFailed,
        }
    }
};

/// A connected socket.
pub const Connection = struct {
    fd: i32,

    /// Connect to a listening socket at `path`.
    pub fn connect(path: []const u8) Error!Connection {
        const address = try Address.init(path);

        const socket_raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
        if (linux.errno(socket_raw) != .SUCCESS) return Error.SyscallFailed;
        const fd: i32 = @intCast(socket_raw);
        errdefer _ = linux.close(fd);

        const connected = linux.connect(fd, address.asSockaddr(), address.length);
        switch (linux.errno(connected)) {
            .SUCCESS => {},
            // A unix socket connect that would block means the backlog is
            // full; the caller may retry.
            .AGAIN => return Error.SyscallFailed,
            else => return Error.SyscallFailed,
        }

        makeNonBlocking(fd);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Connection) void {
        _ = linux.close(self.fd);
    }

    /// Read whatever is available.
    ///
    /// Returns zero bytes when nothing is pending, and `Error.Closed` when the
    /// peer has gone. A zero-length read is how a stream socket reports end of
    /// file, but so is `ECONNRESET` after a peer that did not shut down
    /// cleanly; both are reported as closure.
    pub fn read(self: Connection, buffer: []u8) Error!usize {
        const result = linux.read(self.fd, buffer.ptr, buffer.len);
        return switch (linux.errno(result)) {
            .SUCCESS => if (result == 0) Error.Closed else result,
            .AGAIN => 0,
            .CONNRESET, .PIPE => Error.Closed,
            .INTR => 0,
            else => Error.SyscallFailed,
        };
    }

    /// Write as much of `bytes` as the kernel accepts.
    ///
    /// A short write is possible and is reported to the caller rather than
    /// looped over, because the loop belongs with the queue that owns the
    /// unwritten tail.
    pub fn write(self: Connection, bytes: []const u8) Error!usize {
        const written = linux.write(self.fd, bytes.ptr, bytes.len);
        return switch (linux.errno(written)) {
            .SUCCESS => written,
            // A broken pipe on a socket is a hangup, not a signal.
            .AGAIN => 0,
            .CONNRESET, .PIPE => Error.Closed,
            else => Error.SyscallFailed,
        };
    }
};

/// A message being assembled from the wire.
///
/// Bytes arrive in whatever sizes the kernel chooses, so the header and the
/// payload are accumulated separately: the header has to be complete before
/// its length can be believed, and the payload only then.
pub const FrameReader = struct {
    /// The four-byte header, filled from index zero.
    header: [4]u8 = undefined,
    /// How many header bytes have arrived.
    header_len: usize = 0,
    /// The length the header declared, valid once `header_len` is 4.
    ///
    /// This is kept separately from the payload's capacity on purpose.
    /// `ensureTotalCapacity` promises *at least* the requested capacity, and in
    /// practice rounds up, so a reader that waits for `items.len == capacity`
    /// waits for bytes that will never arrive and silently drops the message.
    /// The length that counts is the one the peer wrote in the header.
    declared: usize = 0,
    /// The payload, allocated once the header is complete.
    payload: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *FrameReader, gpa: std.mem.Allocator) void {
        self.payload.deinit(gpa);
    }

    /// Consume bytes, invoking `sink` for each complete message.
    ///
    /// The payload slice handed to `sink` is only valid for the duration of
    /// that call; it is reused for the next message.
    pub fn feed(
        self: *FrameReader,
        gpa: std.mem.Allocator,
        bytes: []const u8,
        context: anytype,
        comptime sink: fn (@TypeOf(context), []const u8) anyerror!void,
    ) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.header_len < self.header.len) {
                const want = self.header.len - self.header_len;
                const take = @min(want, bytes.len - offset);
                @memcpy(self.header[self.header_len..][0..take], bytes[offset..][0..take]);
                self.header_len += take;
                offset += take;
                if (self.header_len < self.header.len) return;

                const declared = std.mem.readInt(u32, &self.header, .little);
                if (declared == 0 or declared > max_message) return Error.BadFrame;

                self.declared = declared;
                self.payload.clearRetainingCapacity();
                try self.payload.ensureTotalCapacity(gpa, declared);
            }

            // The header is complete here, so there is a payload to fill.
            const want = self.declared - self.payload.items.len;
            const take = @min(want, bytes.len - offset);
            self.payload.appendSliceAssumeCapacity(bytes[offset..][0..take]);
            offset += take;

            if (self.payload.items.len == self.declared) {
                try sink(context, self.payload.items);
                // Reset for the next message: the header is re-read and the
                // payload length re-learned from it.
                self.header_len = 0;
                self.declared = 0;
                self.payload.clearRetainingCapacity();
            }
        }
    }
};

/// Write a length-prefixed message into `out`.
///
/// The caller owns the buffer and flushes it, because a server writing to a
/// client has to cope with a partial write, and that bookkeeping belongs in one
/// place rather than here.
pub fn encode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, payload: []const u8) !void {
    if (payload.len == 0 or payload.len > max_message) return Error.BadFrame;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, payload);
}

/// Remove a socket file, ignoring the case where it is already gone.
///
/// `std.fs.deleteFileAbsolute` does not exist in Zig 0.16 — `std.fs` is down to
/// path manipulation, and deletion moved to `std.Io.Dir`, which wants an `Io`.
/// The raw syscall is used instead so that this module does not have to carry
/// an `Io` for one call.
pub fn removeFile(path: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buffer, "{s}", .{path}) catch return;
    _ = linux.unlink(path_z.ptr);
}

fn makeNonBlocking(fd: i32) void {
    const current = linux.fcntl(fd, linux.F.GETFL, 0);
    var flags: linux.O = @bitCast(@as(u32, @truncate(current)));
    flags.NONBLOCK = true;
    _ = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(flags)));
}

test "an address encodes the path without the trailing NUL" {
    const address = try Address.init("/tmp/zmux-test.sock");
    try std.testing.expectEqual(linux.AF.UNIX, address.storage.family);
    try std.testing.expectEqualStrings(
        "/tmp/zmux-test.sock",
        std.mem.sliceTo(&address.storage.path, 0),
    );
    // The length covers the family plus the path plus its terminator, and
    // stops short of the padding.
    try std.testing.expectEqual(
        @as(linux.socklen_t, @offsetOf(linux.sockaddr.un, "path") + "/tmp/zmux-test.sock".len + 1),
        address.length,
    );
}

test "an overlong address is rejected" {
    const long = "a" ** 200;
    try std.testing.expectError(Error.NameTooLong, Address.init(long));
}

test "a listener accepts what a client connects" {
    const path = "/tmp/zmux-test-socket-listener.sock";
    removeFile(path);

    var listener = try Listener.listen(path);
    defer {
        listener.deinit();
        removeFile(path);
    }

    // Nothing is pending yet, and the non-blocking accept says so rather than
    // blocking.
    try std.testing.expectEqual(@as(?i32, null), try listener.accept());

    var client = try Connection.connect(path);
    defer client.deinit();

    // The connection is in the kernel's queue before it is accepted, so accept
    // must succeed on the first attempt here.
    const server_side = (try listener.accept()) orelse return error.AcceptFailed;
    var accepted = Connection{ .fd = server_side };
    defer accepted.deinit();

    _ = try client.write("ping");
    var buffer: [16]u8 = undefined;

    // The accepted socket is non-blocking and the data may not have arrived
    // yet, so poll a bounded number of times before failing.
    var attempts: usize = 0;
    var len: usize = 0;
    while (attempts < 10_000 and len == 0) : (attempts += 1) {
        len = accepted.read(&buffer) catch |err| switch (err) {
            Error.Closed => break,
            else => return err,
        };
    }
    try std.testing.expectEqualStrings("ping", buffer[0..len]);
}

test "framing round-trips through a split header" {
    const gpa = std.testing.allocator;

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try encode(&wire, gpa, "hello");
    try encode(&wire, gpa, "world");

    const Sink = struct {
        messages: std.ArrayList([]u8) = .empty,

        fn collect(self: *@This(), payload: []const u8) anyerror!void {
            // Copy, because the reader reuses its buffer.
            const copy = try std.testing.allocator.dupe(u8, payload);
            try self.messages.append(std.testing.allocator, copy);
        }

        fn deinit(self: *@This()) void {
            for (self.messages.items) |message| std.testing.allocator.free(message);
            self.messages.deinit(std.testing.allocator);
        }
    };

    var sink: Sink = .{};
    defer sink.deinit();

    var reader: FrameReader = .{};
    defer reader.deinit(gpa);

    // Feed one byte at a time. This is the case that a naive implementation
    // gets wrong: a header split across two reads cannot be interpreted until
    // its last byte arrives.
    for (wire.items) |byte| {
        try reader.feed(gpa, &[_]u8{byte}, &sink, Sink.collect);
    }

    try std.testing.expectEqual(@as(usize, 2), sink.messages.items.len);
    try std.testing.expectEqualStrings("hello", sink.messages.items[0]);
    try std.testing.expectEqualStrings("world", sink.messages.items[1]);
}

test "a payload shorter than the allocated capacity is still delivered" {
    const gpa = std.testing.allocator;

    // A three-byte message in a buffer the allocator is free to round up. If
    // the reader waited for the payload to fill its capacity instead of the
    // length in the header, this message would never be delivered.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try encode(&wire, gpa, "abc");

    const Sink = struct {
        count: usize = 0,
        fn collect(self: *@This(), payload: []const u8) anyerror!void {
            try std.testing.expectEqualStrings("abc", payload);
            self.count += 1;
        }
    };

    var sink: Sink = .{};
    var reader: FrameReader = .{};
    defer reader.deinit(gpa);

    try reader.feed(gpa, wire.items, &sink, Sink.collect);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
}

test "an oversized length is rejected before allocating" {
    const gpa = std.testing.allocator;

    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, max_message + 1, .little);

    const Sink = struct {
        fn ignore(_: *@This(), _: []const u8) anyerror!void {}
    };

    var sink: Sink = .{};
    var reader: FrameReader = .{};
    defer reader.deinit(gpa);

    try std.testing.expectError(
        Error.BadFrame,
        reader.feed(gpa, &header, &sink, Sink.ignore),
    );
}

test "a zero length is rejected" {
    const gpa = std.testing.allocator;

    var header: [4]u8 = .{ 0, 0, 0, 0 };

    const Sink = struct {
        fn ignore(_: *@This(), _: []const u8) anyerror!void {}
    };

    var sink: Sink = .{};
    var reader: FrameReader = .{};
    defer reader.deinit(gpa);

    try std.testing.expectError(
        Error.BadFrame,
        reader.feed(gpa, &header, &sink, Sink.ignore),
    );
}
