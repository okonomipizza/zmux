/// Wire protocol for zmux client-server communication.
///
/// Message format (over stream.zig length-prefixed framing):
///   stream layer:  [u32 total_len][payload...]
///   protocol layer: payload = [u8 type][type-specific data...]
///
/// Client -> Server:
///   attach (0x01): [u16 cols][u16 rows][session_name...]
///   input  (0x02): [raw bytes...]
///   resize (0x03): [u16 cols][u16 rows]
///   detach (0x04): [session_name...]
///
/// Server -> Client:
///   output   (0x01): [raw pty bytes...]
///   attached (0x02): [session_name...]
///   error    (0x03): [error message...]
const std = @import("std");

// ── Client → Server ──

pub const ClientMsgType = enum(u8) {
    attach = 0x01,
    input = 0x02,
    resize = 0x03,
    detach = 0x04,
};

pub const ClientMsg = union(ClientMsgType) {
    attach: Attach,
    input: []const u8,
    resize: Resize,
    detach: Detach,

    pub const Attach = struct {
        cols: u16,
        rows: u16,
        session_name: []const u8,
    };

    pub const Resize = struct {
        cols: u16,
        rows: u16,
    };

    pub const Detach = struct {
        session_name: []const u8,
    };

    /// Parse a framed message payload (type byte + data) into a ClientMsg.
    pub fn decode(data: []const u8) error{ TooShort, InvalidType }!ClientMsg {
        if (data.len < 1) return error.TooShort;

        const tag: ClientMsgType = std.meta.intToEnum(ClientMsgType, data[0]) catch return error.InvalidType;
        const payload = data[1..];

        return switch (tag) {
            .attach => {
                if (payload.len < 4) return error.TooShort;
                return .{ .attach = .{
                    .cols = std.mem.readInt(u16, payload[0..2], .little),
                    .rows = std.mem.readInt(u16, payload[2..4], .little),
                    .session_name = payload[4..],
                } };
            },
            .input => .{ .input = payload },
            .resize => {
                if (payload.len < 4) return error.TooShort;
                return .{ .resize = .{
                    .cols = std.mem.readInt(u16, payload[0..2], .little),
                    .rows = std.mem.readInt(u16, payload[2..4], .little),
                } };
            },
            .detach => {
                if (payload.len < 1) return error.TooShort;
                return .{ .detach = .{
                    .session_name = payload[0..],
                } };
            },
        };
    }

    /// Encode into buf. Returns the used slice.
    pub fn encode(self: ClientMsg, buf: []u8) error{BufferTooSmall}![]u8 {
        switch (self) {
            .attach => |a| {
                const need = 1 + 4 + a.session_name.len;
                if (buf.len < need) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ClientMsgType.attach);
                std.mem.writeInt(u16, buf[1..3], a.cols, .little);
                std.mem.writeInt(u16, buf[3..5], a.rows, .little);
                @memcpy(buf[5..][0..a.session_name.len], a.session_name);
                return buf[0..need];
            },
            .input => |data| {
                const need = 1 + data.len;
                if (buf.len < need) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ClientMsgType.input);
                @memcpy(buf[1..][0..data.len], data);
                return buf[0..need];
            },
            .resize => |r| {
                if (buf.len < 5) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ClientMsgType.resize);
                std.mem.writeInt(u16, buf[1..3], r.cols, .little);
                std.mem.writeInt(u16, buf[3..5], r.rows, .little);
                return buf[0..5];
            },
            .detach => |d| {
                if (buf.len < d.session_name.len) return error.BufferTooSmall;
                @memcpy(buf[0..d.session_name.len], d.session_name);
                return buf[0..d.session_name.len];
            },
        }
    }
};

// ── Server → Client ──

pub const ServerMsgType = enum(u8) {
    output = 0x01,
    attached = 0x02,
    err = 0x03,
};

pub const ServerMsg = union(ServerMsgType) {
    output: []const u8,
    attached: []const u8,
    err: []const u8,

    pub fn decode(data: []const u8) error{ TooShort, InvalidType }!ServerMsg {
        if (data.len < 1) return error.TooShort;

        const tag: ServerMsgType = std.meta.intToEnum(ServerMsgType, data[0]) catch return error.InvalidType;
        const payload = data[1..];

        return switch (tag) {
            .output => .{ .output = payload },
            .attached => .{ .attached = payload },
            .err => .{ .err = payload },
        };
    }

    /// Encode into buf. Returns the used slice.
    pub fn encode(self: ServerMsg, buf: []u8) error{BufferTooSmall}![]u8 {
        switch (self) {
            inline else => |data, tag| {
                const need = 1 + data.len;
                if (buf.len < need) return error.BufferTooSmall;
                buf[0] = @intFromEnum(tag);
                @memcpy(buf[1..][0..data.len], data);
                return buf[0..need];
            },
        }
    }
};
