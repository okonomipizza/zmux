//! The message set the client and server exchange, and its encoding.
//!
//! Each message is one frame (see `socket.zig`). The payload's first byte is
//! the tag and the rest is the body. Everything is little-endian, matching the
//! host, because zmux only supports x86_64 for now.
//!
//! The split between the two directions is deliberate. A client sends
//! *requests*: list, create, attach, detach, kill, input, resize. The server
//! sends *events*: here is a session, here is output, the session ended. The
//! server forwards the pty's bytes unchanged and the client parses them with
//! its own libghostty-vt terminal, so the server never needs to know a client's
//! screen size and a slow client only falls behind itself.

const std = @import("std");

pub const Error = error{
    /// The tag is not one this version knows.
    UnknownTag,
    /// The body is the wrong size for its tag, or a declared length runs past
    /// the end of the message.
    BadLength,
    /// A string field held a value that is not a valid session name.
    BadValue,
};

/// Maximum bytes in a session name.
pub const name_max = 64;

/// A session name.
///
/// Names are the user's handle for a session, so they are restricted to
/// something that cannot be mistaken for an argument or a path. The limit is
/// small because the name travels in every listing entry.
pub const Name = struct {
    bytes: [name_max]u8 = [_]u8{0} ** name_max,
    len: u8 = 0,

    pub fn init(text: []const u8) Error!Name {
        if (text.len == 0 or text.len > name_max) return Error.BadValue;
        for (text) |byte| {
            const allowed = std.ascii.isAlphanumeric(byte) or
                byte == '-' or byte == '_' or byte == '.';
            if (!allowed) return Error.BadValue;
        }
        var name: Name = .{};
        @memcpy(name.bytes[0..text.len], text);
        name.len = @intCast(text.len);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

/// What the client is asking the server to do.
pub const Request = union(enum) {
    /// List the live sessions.
    list,
    /// Start a new session running the given program.
    create: struct {
        name: Name,
        rows: u16,
        cols: u16,
        /// The program and its arguments, separated by NUL. Empty means the
        /// server's own `$SHELL`.
        program: []const u8,
    },
    /// Attach to a session. The size is this client's terminal.
    attach: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
    /// Stop receiving a session's output without ending the session.
    detach: struct {
        name: Name,
    },
    /// Terminate a session and its program.
    kill: struct {
        name: Name,
    },
    /// Terminate every session.
    kill_all,
    /// Keystrokes destined for the attached session's program.
    input: struct {
        name: Name,
        data: []const u8,
    },
    /// The client's terminal changed size.
    resize: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
};

/// One session, as it appears in a listing.
pub const SessionInfo = struct {
    name: Name,
    rows: u16,
    cols: u16,
    /// How many clients are currently attached.
    clients: u8,
    /// The child's pid, for display only.
    pid: i32,
    /// Whether the child is still running.
    running: bool,
};

/// What the server is telling the client.
pub const Event = union(enum) {
    /// One entry in a listing.
    session: SessionInfo,
    /// The listing is complete.
    list_end,
    /// The attach succeeded; output for this session starts here.
    attached: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
    /// The detach succeeded; output for this session stops here.
    detached: struct {
        name: Name,
    },
    /// A session was created.
    created: struct {
        name: Name,
    },
    /// The session is gone. Sent to every client watching it.
    exited: struct {
        name: Name,
        /// The exit status, or 128 + signal when the program was signalled.
        status: u8,
    },
    /// Output from a session's program, exactly as it left the pty.
    output: struct {
        name: Name,
        data: []const u8,
    },
    /// A request was rejected, or a listing is empty.
    failure: struct {
        message: []const u8,
    },
};

/// Wire tags.
///
/// Spelled out rather than taken from the enum ordinal, because these are the
/// protocol: reordering a union arm must not silently renumber the wire.
pub const Tag = struct {
    // Requests, 1..=15.
    pub const list: u8 = 1;
    pub const create: u8 = 2;
    pub const attach: u8 = 3;
    pub const detach: u8 = 4;
    pub const kill: u8 = 5;
    pub const kill_all: u8 = 6;
    pub const input: u8 = 7;
    pub const resize: u8 = 8;
    // Events, 64..=127. The gap leaves room to add either kind later without
    // renumbering.
    pub const session: u8 = 64;
    pub const list_end: u8 = 65;
    pub const attached: u8 = 66;
    pub const detached: u8 = 67;
    pub const created: u8 = 68;
    pub const exited: u8 = 69;
    pub const output: u8 = 70;
    pub const failure: u8 = 71;
};

/// Appends fields to a buffer.
///
/// This builds the *payload* of a frame — the tag and its body — and leaves the
/// length prefix to `socket.encode`, which is the only place that knows about
/// framing. Encoding the prefix here as well would make the payload ambiguous
/// about whether it starts with a tag or a length, which is exactly the bug
/// this comment exists to prevent.
pub const Encoder = struct {
    buffer: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.gpa);
    }

    /// Start a message with the given tag.
    pub fn begin(self: *Encoder, tag: u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.gpa, tag);
    }

    fn u8le(self: *Encoder, value: u8) !void {
        try self.buffer.append(self.gpa, value);
    }

    fn u16le(self: *Encoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    fn i32le(self: *Encoder, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    fn name(self: *Encoder, value: *const Name) !void {
        try self.u8le(value.len);
        try self.buffer.appendSlice(self.gpa, value.slice());
    }

    fn blob(self: *Encoder, value: []const u8) !void {
        if (value.len > std.math.maxInt(u32)) return Error.BadLength;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value.len), .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
        try self.buffer.appendSlice(self.gpa, value);
    }

    /// Complete the current message and return its payload: the tag followed by
    /// the body, without a length prefix.
    ///
    /// The returned slice is valid until the next call that touches the
    /// encoder, so the caller must hand it to `socket.encode` before encoding
    /// anything else.
    pub fn finish(self: *Encoder) ![]const u8 {
        if (self.buffer.items.len == 0) return Error.BadLength;
        return self.buffer.items;
    }

    pub fn writeRequest(self: *Encoder, request: Request) ![]const u8 {
        switch (request) {
            .list => try self.begin(Tag.list),
            .kill_all => try self.begin(Tag.kill_all),
            .create => |create| {
                try self.begin(Tag.create);
                try self.name(&create.name);
                try self.u16le(create.rows);
                try self.u16le(create.cols);
                try self.blob(create.program);
            },
            .attach => |attach| {
                try self.begin(Tag.attach);
                try self.name(&attach.name);
                try self.u16le(attach.rows);
                try self.u16le(attach.cols);
            },
            .detach => |detach| {
                try self.begin(Tag.detach);
                try self.name(&detach.name);
            },
            .kill => |kill| {
                try self.begin(Tag.kill);
                try self.name(&kill.name);
            },
            .input => |input| {
                try self.begin(Tag.input);
                try self.name(&input.name);
                try self.blob(input.data);
            },
            .resize => |resize| {
                try self.begin(Tag.resize);
                try self.name(&resize.name);
                try self.u16le(resize.rows);
                try self.u16le(resize.cols);
            },
        }
        return self.finish();
    }

    pub fn writeEvent(self: *Encoder, event: Event) ![]const u8 {
        switch (event) {
            .list_end => try self.begin(Tag.list_end),
            .session => |info| {
                try self.begin(Tag.session);
                try self.name(&info.name);
                try self.u16le(info.rows);
                try self.u16le(info.cols);
                try self.u8le(info.clients);
                try self.i32le(info.pid);
                try self.u8le(if (info.running) 1 else 0);
            },
            .attached => |attached| {
                try self.begin(Tag.attached);
                try self.name(&attached.name);
                try self.u16le(attached.rows);
                try self.u16le(attached.cols);
            },
            .detached => |detached| {
                try self.begin(Tag.detached);
                try self.name(&detached.name);
            },
            .created => |created| {
                try self.begin(Tag.created);
                try self.name(&created.name);
            },
            .exited => |exited| {
                try self.begin(Tag.exited);
                try self.name(&exited.name);
                try self.u8le(exited.status);
            },
            .output => |output| {
                try self.begin(Tag.output);
                try self.name(&output.name);
                try self.blob(output.data);
            },
            .failure => |failure| {
                try self.begin(Tag.failure);
                try self.blob(failure.message);
            },
        }
        return self.finish();
    }
};

/// Reads fields out of a decoded frame payload.
///
/// The payload is borrowed from the frame reader's buffer, so the slices this
/// returns into it are valid only until the next frame is read. Every field is
/// bounds-checked against the message length, because the bytes come from
/// another process.
pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    pub fn tag(self: Decoder) Error!u8 {
        if (self.bytes.len == 0) return Error.BadLength;
        return self.bytes[0];
    }

    fn u8le(self: *Decoder) Error!u8 {
        if (self.offset + 1 > self.bytes.len) return Error.BadLength;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn u16le(self: *Decoder) Error!u16 {
        if (self.offset + 2 > self.bytes.len) return Error.BadLength;
        defer self.offset += 2;
        return std.mem.readInt(u16, self.bytes[self.offset..][0..2], .little);
    }

    fn i32le(self: *Decoder) Error!i32 {
        if (self.offset + 4 > self.bytes.len) return Error.BadLength;
        defer self.offset += 4;
        return std.mem.readInt(i32, self.bytes[self.offset..][0..4], .little);
    }

    fn name(self: *Decoder) Error!Name {
        const length = try self.u8le();
        if (length == 0 or length > name_max) return Error.BadValue;
        if (self.offset + length > self.bytes.len) return Error.BadLength;
        defer self.offset += length;
        // The name was validated before it was encoded, but this side cannot
        // assume the peer did that.
        return Name.init(self.bytes[self.offset..][0..length]);
    }

    fn blob(self: *Decoder) Error![]const u8 {
        const length = std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
        self.offset += 4;
        if (self.offset + length > self.bytes.len) return Error.BadLength;
        defer self.offset += length;
        return self.bytes[self.offset..][0..length];
    }

    /// Decode a client request.
    pub fn request(self: *Decoder) Error!Request {
        // The tag is checked first; `offset` then starts just past it.
        _ = try self.tag();
        self.offset = 1;
        return switch (self.bytes[0]) {
            Tag.list => Request.list,
            Tag.kill_all => Request.kill_all,
            Tag.create => Request{ .create = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
                .program = try self.blob(),
            } },
            Tag.attach => Request{ .attach = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            Tag.detach => Request{ .detach = .{ .name = try self.name() } },
            Tag.kill => Request{ .kill = .{ .name = try self.name() } },
            Tag.input => Request{ .input = .{
                .name = try self.name(),
                .data = try self.blob(),
            } },
            Tag.resize => Request{ .resize = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            else => Error.UnknownTag,
        };
    }

    /// Decode a server event.
    pub fn event(self: *Decoder) Error!Event {
        _ = try self.tag();
        self.offset = 1;
        return switch (self.bytes[0]) {
            Tag.list_end => Event.list_end,
            Tag.session => Event{ .session = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
                .clients = try self.u8le(),
                .pid = try self.i32le(),
                .running = (try self.u8le()) != 0,
            } },
            Tag.attached => Event{ .attached = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            Tag.detached => Event{ .detached = .{ .name = try self.name() } },
            Tag.created => Event{ .created = .{ .name = try self.name() } },
            Tag.exited => Event{ .exited = .{
                .name = try self.name(),
                .status = try self.u8le(),
            } },
            Tag.output => Event{ .output = .{
                .name = try self.name(),
                .data = try self.blob(),
            } },
            Tag.failure => Event{ .failure = .{ .message = try self.blob() } },
            else => Error.UnknownTag,
        };
    }
};

/// Split a program string into null-separated arguments.
///
/// The program travels as one blob with NUL separators rather than a length
/// per argument, because `execve` wants NUL-terminated strings anyway and the
/// server only has to replace the separators with terminators.
pub fn splitProgram(program: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, program, 0);
    while (iterator.next()) |part| {
        if (count == out.len) break;
        if (part.len == 0) continue;
        out[count] = part;
        count += 1;
    }
    return count;
}

/// Join arguments into a NUL-separated program string.
pub fn joinProgram(out: *std.ArrayList(u8), gpa: std.mem.Allocator, argv: []const []const u8) !void {
    for (argv, 0..) |argument, index| {
        if (index != 0) try out.append(gpa, 0);
        // A NUL inside an argument would be indistinguishable from a separator,
        // so it cannot be represented and is not silently dropped.
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return Error.BadValue;
        try out.appendSlice(gpa, argument);
    }
}

test "a name rejects path separators and empties" {
    _ = try Name.init("work");
    _ = try Name.init("build-2.1");
    try std.testing.expectError(Error.BadValue, Name.init(""));
    try std.testing.expectError(Error.BadValue, Name.init("a/b"));
    try std.testing.expectError(Error.BadValue, Name.init("with space"));
    try std.testing.expectError(Error.BadValue, Name.init("a" ** 100));
}

test "an encoded payload starts with its tag, not a length" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const payload = try encoder.writeRequest(.list);

    // The distinction matters: `socket.encode` supplies the length prefix, and
    // a payload that also carried one would be decoded with the prefix read as
    // the tag.
    try std.testing.expectEqual(Tag.list, payload[0]);
    try std.testing.expectEqual(@as(usize, 1), payload.len);

    var decoder = Decoder.init(payload);
    try std.testing.expectEqual(Tag.list, try decoder.tag());
}

test "a request survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("work");

    {
        const frame = try encoder.writeRequest(.{ .attach = .{
            .name = name,
            .rows = 24,
            .cols = 80,
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u16, 24), request.attach.rows);
        try std.testing.expectEqual(@as(u16, 80), request.attach.cols);
        try std.testing.expect(request.attach.name.eql("work"));
    }

    {
        const frame = try encoder.writeRequest(.{ .input = .{
            .name = name,
            .data = "ls -la\n",
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqualStrings("ls -la\n", request.input.data);
    }

    {
        const frame = try encoder.writeRequest(.list);
        var decoder = Decoder.init(frame);
        try std.testing.expectEqual(Request.list, try decoder.request());
    }
}

test "an event survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("build");

    const frame = try encoder.writeEvent(.{ .session = .{
        .name = name,
        .rows = 10,
        .cols = 40,
        .clients = 2,
        .pid = 4321,
        .running = true,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expect(event.session.name.eql("build"));
    try std.testing.expectEqual(@as(u16, 10), event.session.rows);
    try std.testing.expectEqual(@as(u8, 2), event.session.clients);
    try std.testing.expectEqual(@as(i32, 4321), event.session.pid);
    try std.testing.expect(event.session.running);
}

test "output carrying arbitrary bytes survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    // Pty output is not text: it is VT sequences full of NULs and high bytes,
    // and a decoder that treated it as a C string would truncate it.
    const raw = "\x1b[1;1H\x00\xff\xfe hello \x00\x1b[2J";

    const frame = try encoder.writeEvent(.{ .output = .{
        .name = try Name.init("tty"),
        .data = raw,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expectEqualStrings(raw, event.output.data);
}

test "a truncated message is rejected rather than read past its end" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const payload = try encoder.writeRequest(.{ .attach = .{
        .name = try Name.init("work"),
        .rows = 24,
        .cols = 80,
    } });

    // Drop the columns field but keep the tag, so the decoder recognises the
    // message and then finds its body short. This is the case a bounds check
    // has to catch: the peer said "attach" and then stopped.
    const truncated = payload[0 .. payload.len - 2];

    var decoder = Decoder.init(truncated);
    try std.testing.expectError(Error.BadLength, decoder.request());
}

test "an unknown tag is reported rather than guessed at" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const frame = try encoder.writeRequest(.{ .detach = .{
        .name = try Name.init("work"),
    } });

    var bytes = try gpa.dupe(u8, frame);
    defer gpa.free(bytes);
    // Corrupt the tag. A version skew between client and server has to be
    // reported, not interpreted.
    bytes[4] = 99;
    std.mem.writeInt(u32, bytes[0..4], 2, .little);

    var decoder = Decoder.init(bytes[4..]);
    try std.testing.expectError(Error.UnknownTag, decoder.request());
    try std.testing.expectError(Error.UnknownTag, decoder.event());
}

test "a program string splits on its NUL separators" {
    const program = "vim\x00-c\x00set nu";
    var argv: [8][]const u8 = undefined;
    const count = splitProgram(program, &argv);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("vim", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("set nu", argv[2]);
}

test "joining a program round trips through splitting" {
    const gpa = std.testing.allocator;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joinProgram(&joined, gpa, &.{ "sh", "-c", "echo hi" });

    var argv: [8][]const u8 = undefined;
    const count = splitProgram(joined.items, &argv);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("echo hi", argv[2]);
}

test "an argument containing NUL is rejected" {
    const gpa = std.testing.allocator;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try std.testing.expectError(
        Error.BadValue,
        joinProgram(&joined, gpa, &.{ "echo", "a\x00b" }),
    );
}
