/// Server-side representation of a connected client.
const std = @import("std");
const posix = std.posix;
const Stream = @import("stream.zig");
const protocol = @import("protocol.zig");

const Client = @This();

const BUF_SIZE = 4096;

socket: posix.fd_t,
stream: Stream,
/// Name of the attached session, or null if not yet attached.
session_name: ?[]const u8,

pub fn init(alloc: std.mem.Allocator, socket: posix.fd_t) !*Client {
    const buf = try alloc.alloc(u8, BUF_SIZE);
    errdefer alloc.free(buf);

    const self = try alloc.create(Client);
    self.* = .{
        .socket = socket,
        .stream = Stream.init(buf),
        .session_name = null,
    };
    return self;
}

pub fn deinit(self: *Client, alloc: std.mem.Allocator) void {
    alloc.free(self.stream.buf);
    posix.close(self.socket);
    alloc.destroy(self);
}

/// Read and decode one client message. Blocks until a complete frame arrives.
pub fn readMessage(self: *Client) !protocol.ClientMsg {
    const frame = try self.stream.readMessage(self.socket);
    return protocol.ClientMsg.decode(frame);
}

/// Send a server message to this client.
pub fn sendMessage(self: *Client, msg: protocol.ServerMsg) !void {
    var buf: [BUF_SIZE]u8 = undefined;
    const payload = try msg.encode(&buf);
    try self.stream.writeMessage(payload, self.socket);
}

/// Send raw PTY output wrapped in an output message.
pub fn sendOutput(self: *Client, data: []const u8) !void {
    try self.sendMessage(.{ .output = data });
}
