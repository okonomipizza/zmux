/// A named session that holds a PTY and tracks connected clients.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

const Session = @This();
const Pty = @import("Pty.zig");
const Client = @import("Client.zig");

name: []const u8,
pty: Pty,
/// File descriptors of clients attached to this session.
clients: std.AutoArrayHashMap(posix.fd_t, void),

pub fn init(
    alloc: Allocator,
    name: []const u8,
    cols: u16,
    rows: u16,
    termios: c.struct_termios,
    epfd: posix.fd_t,
) !*Session {
    const pty = try Pty.init(cols, rows, termios);
    errdefer {
        var p = pty;
        p.deinit();
    }

    // Register PTY master fd with epoll so we get notified on output.
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = pty.master_fd },
    };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, pty.master_fd, &ev);

    const self = try alloc.create(Session);
    self.* = .{
        .name = name,
        .pty = pty,
        .clients = std.AutoArrayHashMap(posix.fd_t, void).init(alloc),
    };
    return self;
}

pub fn deinit(self: *Session, alloc: Allocator) void {
    self.clients.deinit(alloc);
    self.pty.deinit();
    alloc.destroy(self);
}

/// Returns true if fd is this session's PTY master fd.
pub fn ownsPty(self: *Session, fd: posix.fd_t) bool {
    return self.pty.master_fd == fd;
}

pub fn addClient(self: *Session, client_fd: posix.fd_t) !void {
    try self.clients.put(client_fd, {});
}

pub fn removeClient(self: *Session, client_fd: posix.fd_t) void {
    _ = self.clients.swapRemove(client_fd);
}
