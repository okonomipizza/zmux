const std = @import("std");
const posix = std.posix;

pub fn Stream(comptime buf_size: usize) type {
    return struct {
        const Self = @This();

        /// Buffer for reading
        buf: [buf_size]u8 = undefined,
        /// Start position of unprocessed data
        start: usize = 0,
        /// End position of data written into the buffer.
        pos: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn read(self: *Self, socket: posix.socket_t) ![]u8 {
            while (true) {
                if (try self.bufferedMessage()) |msg| {
                    return msg;
                }
                const pos = self.pos;
                const n = try posix.read(socket, self.buf[pos..]);
                if (n == 0) {
                    return error.Closed;
                }
                self.pos = pos + n;
            }
        }

        /// Read data from socket into buffer (non-blocking, call when epoll signals data available)
        pub fn receiveData(self: *Self, socket: posix.socket_t) !void {
            const pos = self.pos;
            const n = try posix.read(socket, self.buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }

        /// Returns next complete message from buffer, or null if none available
        pub fn nextMessage(self: *Self) ?[]u8 {
            return self.bufferedMessage() catch null;
        }

        fn bufferedMessage(self: *Self) !?[]u8 {
            const pos = self.pos;
            const start = self.start;
            std.debug.assert(pos >= start);
            const unprocessed = self.buf[start..pos];

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
            return self.buf[start + 4 .. start + total_len];
        }

        fn ensureSpace(self: *Self, space: usize) error{BufferTooSmall}!void {
            if (self.buf.len < space) {
                return error.BufferTooSmall;
            }

            const start = self.start;
            const spare = self.buf.len - start;
            if (spare >= space) return;

            const unprocessed_len = self.pos - start;
            std.mem.copyForwards(u8, self.buf[0..unprocessed_len], self.buf[start..self.pos]);
            self.start = 0;
            self.pos = unprocessed_len;
        }

        pub fn write(self: *Self, msg: []const u8, socket: posix.socket_t) !void {
            _ = self;
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);

            var vec = [2]posix.iovec_const{
                .{ .len = 4, .base = &buf },
                .{ .len = msg.len, .base = msg.ptr },
            };

            try writeAllVectored(socket, &vec);
        }

        fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
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
    };
}
