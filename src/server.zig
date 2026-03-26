const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Client = @import("Client.zig");
const protocol = @import("protocol.zig");
const c = @import("c.zig").c;

const MAX_EVENTS = 64;
const PTY_BUF_SIZE = 4096;

pub fn server(alloc: Allocator, path: []const u8) !void {
    // Get termios from current terminal for PTY slave configuration.
    var termios: c.struct_termios = undefined;
    if (c.tcgetattr(c.STDIN_FILENO, &termios) < 0)
        return error.TcgetattrFailed;

    // ── Epoll ──
    const epfd = try posix.epoll_create1(0);
    defer posix.close(epfd);

    // ── Unix domain socket listener ──
    const listener = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(listener);

    posix.unlink(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer posix.unlink(path) catch {};

    const address = try std.net.Address.initUnix(path);
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listener },
        };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener, &ev);
    }

    // ── State ──
    var sessions = std.StringHashMap(*Session).init(alloc);
    defer {
        var it = sessions.valueIterator();
        while (it.next()) |s| s.*.deinit(alloc);
        sessions.deinit();
    }

    var clients = std.AutoHashMap(posix.fd_t, *Client).init(alloc);
    defer {
        var it = clients.valueIterator();
        while (it.next()) |cl| cl.*.deinit(alloc);
        clients.deinit();
    }

    var events: [MAX_EVENTS]linux.epoll_event = undefined;
    var pty_buf: [PTY_BUF_SIZE]u8 = undefined;

    std.debug.print("zmux server listening on {s}\n", .{path});

    // ── Event loop ──
    while (true) {
        const n = posix.epoll_wait(epfd, &events, -1);

        for (events[0..n]) |event| {
            const fd = event.data.fd;

            if (fd == listener) {
                // ── New client connection ──
                acceptClient(epfd, listener, &clients, alloc) catch |err| {
                    std.debug.print("accept error: {}\n", .{err});
                    continue;
                };
            } else if (findSessionByPty(&sessions, fd)) |session| {
                // ── PTY output → broadcast to attached clients ──
                handlePtyOutput(session, fd, &pty_buf, &clients);
            } else if (clients.get(fd)) |client| {
                // ── Client message ──
                handleClientMessage(client, &sessions, &clients, epfd, alloc, termios) catch |err| {
                    switch (err) {
                        error.Closed => {
                            detachAndRemoveClient(client, &sessions, &clients, epfd, alloc);
                        },
                        else => {
                            std.debug.print("client fd={} error: {}\n", .{ fd, err });
                            detachAndRemoveClient(client, &sessions, &clients, epfd, alloc);
                        },
                    }
                };
            }
        }
    }
}

// ────────────────────────────────────────────
// Accept
// ────────────────────────────────────────────

fn acceptClient(
    epfd: posix.fd_t,
    listener: posix.fd_t,
    clients: *std.AutoHashMap(posix.fd_t, *Client),
    alloc: Allocator,
) !void {
    const sock = try posix.accept(listener, null, null, posix.SOCK.NONBLOCK);
    errdefer posix.close(sock);

    const client = try Client.init(alloc, sock);
    errdefer client.deinit(alloc);

    try clients.put(sock, client);

    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .fd = sock },
    };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock, &ev);

    std.debug.print("client connected: fd={}\n", .{sock});
}

// ────────────────────────────────────────────
// PTY output
// ────────────────────────────────────────────

fn handlePtyOutput(
    session: *Session,
    pty_fd: posix.fd_t,
    buf: []u8,
    clients: *std.AutoHashMap(posix.fd_t, *Client),
) void {
    const n = posix.read(pty_fd, buf) catch |err| {
        std.debug.print("pty read error: {}\n", .{err});
        return;
    };
    if (n == 0) return;

    const data = buf[0..n];

    // Broadcast to every client attached to this session.
    for (session.clients.keys()) |client_fd| {
        const client = clients.get(client_fd) orelse continue;
        client.sendOutput(data) catch |err| {
            std.debug.print("send to fd={} failed: {}\n", .{ client_fd, err });
        };
    }
}

// ────────────────────────────────────────────
// Client messages
// ────────────────────────────────────────────

fn handleClientMessage(
    client: *Client,
    sessions: *std.StringHashMap(*Session),
    clients: *std.AutoHashMap(posix.fd_t, *Client),
    epfd: posix.fd_t,
    alloc: Allocator,
    termios: c.struct_termios,
) !void {
    const msg = try client.readMessage();

    switch (msg) {
        .attach => |req| {
            // Get or create session.
            const session = sessions.get(req.session_name) orelse blk: {
                const s = try Session.init(
                    alloc,
                    req.session_name,
                    req.cols,
                    req.rows,
                    termios,
                    epfd,
                );
                try sessions.put(req.session_name, s);
                std.debug.print("session created: \"{s}\"\n", .{req.session_name});
                break :blk s;
            };

            // Detach from old session if any.
            if (client.session_name) |old_name| {
                if (sessions.get(old_name)) |old_session| {
                    old_session.removeClient(client.socket);
                }
            }

            client.session_name = req.session_name;
            try session.addClient(client.socket);
            try client.sendMessage(.{ .attached = req.session_name });
            std.debug.print("client fd={} attached to \"{s}\"\n", .{ client.socket, req.session_name });
        },
        .detach => |_| {
            detachAndRemoveClient(client, sessions, clients, epfd, alloc);
        },
        .input => |i| {
            const session_neme = client.session_name orelse return;
            const session = sessions.get(session_neme) orelse return;
            try session.pty.write(i);
        },
        .resize => |req| {
            const session = getClientSession(client, sessions) orelse return;
            session.pty.resize(req.cols, req.rows) catch |err| {
                std.debug.print("pty resize error: {}\n", .{err});
            };
        },
    }
}

fn getClientSession(client: *Client, sessions: *std.StringHashMap(*Session)) ?*Session {
    const name = client.session_name orelse return null;
    return sessions.get(name);
}

// ────────────────────────────────────────────
// Cleanup
// ────────────────────────────────────────────

fn detachAndRemoveClient(
    client: *Client,
    sessions: *std.StringHashMap(*Session),
    clients: *std.AutoHashMap(posix.fd_t, *Client),
    epfd: posix.fd_t,
    alloc: Allocator,
) void {
    // Remove from session's client list.
    if (client.session_name) |name| {
        if (sessions.get(name)) |session| {
            session.removeClient(client.socket);
        }
    }

    // Remove from epoll and client map.
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, client.socket, null) catch {};
    _ = clients.remove(client.socket);
    client.deinit(alloc);
}

// ────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────

fn findSessionByPty(sessions: *std.StringHashMap(*Session), fd: posix.fd_t) ?*Session {
    var it = sessions.valueIterator();
    while (it.next()) |s| {
        if (s.*.ownsPty(fd)) return s.*;
    }
    return null;
}
