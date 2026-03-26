const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Stream = @This();

buf: []u8,
start: usize,
pos: usize,

pub fn init(buf: []u8) Stream {
    return .{
        .buf = buf,
        .start = 0,
        .pos = 0,
    };
}

pub fn readMessage(self: *Stream, socket: posix.socket_t) ![]u8 {
    var buf = self.buf;
    while (true) {
        if (try self.bufferedMessage()) |msg| {
            return msg;
        }
        const pos = self.pos;
        const n = try posix.read(socket, buf[pos..]);
        if (n == 0) {
            return error.Closed;
        }
        self.pos = pos + n;
    }
}

fn bufferedMessage(self: *Stream) !?[]u8 {
    const buf = self.buf;
    const pos = self.pos;
    const start = self.start;
    std.debug.assert(pos >= start);
    const unprocessed = buf[start..pos];

    if (unprocessed.len < 4) {
        self.ensureSpace(4 - unprocessed.len) catch unreachable;
        return null;
    }

    const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);
    const total_len = message_len + 4;

    if (unprocessed.len < total_len) {
        try self.ensureSpace(total_len);
        return null;
    }

    self.start += total_len;
    return unprocessed[4..total_len];
}

fn ensureSpace(self: *Stream, space: usize) error{BufferTooSamll}!void {
    const buf = self.buf;
    if (buf.len < space) {
        return error.BufferTooSamll;
    }

    const start = self.start;
    const spare = buf.len - start;
    if (spare >= space) return;

    const unprocessed = buf[start..self.pos];
    std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
    self.start = 0;
    self.pos = unprocessed.len;
}

pub fn writeMessage(self: Stream, msg: []const u8, socket: posix.socket_t) !void {
    _ = self;
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);

    var vec = [2]posix.iovec_const{
        .{ .len = 4, .base = &buf },
        .{ .len = msg.len, .base = msg.ptr },
    };

    try writeAllVectord(socket, &vec);
}

fn writeAllVectord(socket: posix.socket_t, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}
