//! The zmux server: it owns the sessions, and the clients only look at them.
//!
//! The decision that shapes everything here is that a session's pty and its
//! terminal live in the server, not in the client. A client that disconnects
//! therefore costs the session nothing: the program keeps running and its
//! screen keeps being parsed, so a reconnecting client only has to be shown the
//! current screen. If the terminal lived in the client, detaching would mean
//! either killing the program or replaying every byte it had ever produced.
//!
//! The cost is that the server has to render for clients that may be drawing at
//! a different size than the session was created at. zmux resolves this by
//! keeping the session's terminal at the size the most recent resize asked for,
//! and forwarding its output to clients unchanged; each client parses those
//! bytes with its own terminal. Several clients may watch one session and they
//! share its size, which is the compromise tmux makes too.
//!
//! The event loop is one epoll set over the listening socket, one socket per
//! client, one pty master per session, and a signalfd for SIGCHLD. Nothing
//! blocks, so a client that stops reading cannot stall the others.

const std = @import("std");
const linux = std.os.linux;
const vt = @import("vt.zig");
const pty_mod = @import("pty.zig");
const socket = @import("socket.zig");
const protocol = @import("protocol.zig");

pub const Error = error{
    /// A raw syscall failed.
    SyscallFailed,
    /// A session with that name already exists.
    SessionExists,
    /// No session has that name.
    UnknownSession,
    /// The session could not be started.
    SpawnFailed,
    /// The terminal screen could not be created.
    TerminalFailed,
    /// A pty read or write failed.
    PtyFailed,
};

/// The handle a session's terminal uses to find its way back here.
///
/// libghostty-vt's `write_pty` callback carries one opaque pointer, so it points
/// at this rather than at the session itself. A session is addressed by its name
/// rather than by its index because `sessions` is a list that reorders when a
/// session is removed, and a reply that arrived for the wrong session would be
/// written to the wrong program.
const ReplyRoute = struct {
    server: *Server,
    name: protocol.Name,
    /// The buffer replies accumulate in. Owned by the session.
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
};

/// Which client a decoded message belongs to.
///
/// A file-scope declaration rather than one nested in `Server`, because the
/// message sink's signature is built from it and it has to be in scope where the
/// sink is named.
const MessageContext = struct {
    server: *Server,
    client: usize,
};

/// One attached client.
const Client = struct {
    /// The accepted socket. Held as a `Connection` rather than a bare fd so that
    /// the non-blocking read and write, and the translation of a peer's
    /// departure into `Error.Closed`, are the same code the client side uses.
    connection: socket.Connection,
    /// The session this client is watching. An unset name means the client is
    /// connected but idle, which is the state `ls` and `kill` run in.
    watching: protocol.Name = .{},
    /// Accumulates bytes from the socket into whole messages.
    frame: socket.FrameReader = .{},
    /// Bytes waiting to go out.
    ///
    /// A queue rather than a direct write, because one pty read can produce
    /// output for several clients and a client that has stopped reading must
    /// not stall the rest.
    outgoing: std.ArrayList(u8) = .empty,
    /// Set when the peer is gone or being dropped. The entry is kept until the
    /// next sweep so that indices handed out earlier in the same loop pass stay
    /// valid.
    gone: bool = false,

    fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        self.connection.deinit();
        self.frame.deinit(gpa);
        self.outgoing.deinit(gpa);
    }
};

/// One session: a pty, the screen it is drawing, and who is watching.
const Session = struct {
    name: protocol.Name,
    pty: pty_mod.Pty,
    terminal: vt.Terminal,
    /// Clients attached to this session, as indices into `Server.clients`.
    watchers: std.ArrayList(usize) = .empty,
    /// The current screen size, which is what the pty and terminal agree on.
    rows: u16,
    cols: u16,
    /// Bytes the terminal wants sent to the pty, from the write_pty callback.
    reply: std.ArrayList(u8) = .empty,
    /// The opaque handle the terminal holds; points at `route`.
    route: ReplyRoute = undefined,
    /// Reused pty read buffer, so a busy session does not allocate per wakeup.
    read_buffer: []u8 = &.{},
    /// Set once the child has been reaped. The screen is kept so a client that
    /// attaches afterwards still sees the final output.
    exited: bool = false,
    /// The exit status, once known.
    status: u8 = 0,

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.watchers.deinit(gpa);
        self.reply.deinit(gpa);
        gpa.free(self.read_buffer);
        self.terminal.deinit();
        self.pty.deinit();
    }
};

pub const SpawnRequest = struct {
    name: []const u8,
    rows: u16,
    cols: u16,
    /// The program and its arguments. Empty means the server's `$SHELL`.
    argv: []const []const u8,
};

/// Whether the loop should keep going.
const RunState = enum { running, stop };

pub const Server = struct {
    gpa: std.mem.Allocator,
    listener: socket.Listener,
    sessions: std.ArrayList(Session) = .empty,
    clients: std.ArrayList(Client) = .empty,
    /// The epoll set.
    epfd: i32,
    /// The socket path, so it can be removed on shutdown.
    path: []const u8,
    /// Reused for every outgoing message.
    encoder: protocol.Encoder,
    /// Passed to every child.
    environ: std.process.Environ,
    state: RunState = .running,

    /// Create the server and its listening socket.
    ///
    /// The socket path is taken as given; deciding where it lives is the
    /// caller's job, because that is where zmux's directory layout is settled.
    /// The caller must also have established that no server is already running,
    /// since this removes any existing socket file.
    pub fn init(
        gpa: std.mem.Allocator,
        path: []const u8,
        environ: std.process.Environ,
    ) !*Server {
        const epfd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(epfd_raw) != .SUCCESS) return Error.SyscallFailed;
        const epfd: i32 = @intCast(epfd_raw);
        errdefer _ = linux.close(epfd);

        socket.removeFile(path);
        var listener = try socket.Listener.listen(path);
        errdefer listener.deinit();

        const server = try gpa.create(Server);
        errdefer gpa.destroy(server);

        server.* = .{
            .gpa = gpa,
            .listener = listener,
            .epfd = epfd,
            .path = path,
            .encoder = protocol.Encoder.init(gpa),
            .environ = environ,
        };

        try server.register(listener.fd, linux.EPOLL.IN);
        return server;
    }

    pub fn deinit(self: *Server) void {
        for (self.clients.items) |*client| client.deinit(self.gpa);
        self.clients.deinit(self.gpa);
        for (self.sessions.items) |*session| session.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
        self.encoder.deinit();
        self.listener.deinit();
        socket.removeFile(self.path);
        _ = linux.close(self.epfd);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn register(self: *Server, fd: i32, events: u32) !void {
        var event = linux.epoll_event{ .events = events, .data = .{ .fd = fd } };
        if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &event)) != .SUCCESS)
            return Error.SyscallFailed;
    }

    fn unregister(self: *Server, fd: i32) void {
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Start a session and return its index.
    pub fn createSession(self: *Server, request: SpawnRequest) !usize {
        if (self.findSession(request.name) != null) return Error.SessionExists;
        if (request.rows == 0 or request.cols == 0) return Error.SpawnFailed;

        // `execve` wants null-terminated strings, so the vector is rebuilt into
        // fixed buffers. The count is bounded rather than allocated, because
        // this runs on a socket read and a peer could otherwise ask for an
        // arbitrarily large vector.
        const max_arguments = 64;
        var argument_buffers: [max_arguments][std.fs.max_path_bytes]u8 = undefined;
        var argv: [max_arguments]?[*:0]const u8 = undefined;
        var count: usize = 0;

        if (request.argv.len == 0) {
            const shell = self.environ.getPosix("SHELL") orelse "/bin/sh";
            argv[count] = (try std.fmt.bufPrintZ(&argument_buffers[count], "{s}", .{shell})).ptr;
            count += 1;
        } else {
            for (request.argv) |argument| {
                if (count >= max_arguments - 1) break;
                argv[count] = (try std.fmt.bufPrintZ(
                    &argument_buffers[count],
                    "{s}",
                    .{argument},
                )).ptr;
                count += 1;
            }
        }
        argv[count] = null;

        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

        const pty = pty_mod.Pty.spawn(@ptrCast(&argv), envp, .{
            .rows = request.rows,
            .cols = request.cols,
        }) catch return Error.SpawnFailed;
        errdefer {
            var p = pty;
            p.deinit();
        }
        pty.setNonBlocking();

        const terminal = vt.Terminal.init(.{
            .cols = request.cols,
            .rows = request.rows,
        }) catch return Error.TerminalFailed;
        errdefer {
            var t = terminal;
            t.deinit();
        }

        const read_buffer = try self.gpa.alloc(u8, 64 * 1024);
        errdefer self.gpa.free(read_buffer);

        var session: Session = .{
            .name = try protocol.Name.init(request.name),
            .pty = pty,
            .terminal = terminal,
            .rows = request.rows,
            .cols = request.cols,
            .read_buffer = read_buffer,
        };
        try session.watchers.ensureTotalCapacity(self.gpa, 4);

        try self.sessions.append(self.gpa, session);
        const index = self.sessions.items.len - 1;

        // The reply path is wired now that the session has a home in the list,
        // and before any byte is parsed: a program that probes the terminal at
        // startup blocks until it gets an answer.
        const stored = &self.sessions.items[index];
        stored.route = .{
            .server = self,
            .name = stored.name,
            .buffer = &stored.reply,
            .gpa = self.gpa,
        };
        stored.terminal.setWritePty(
            @ptrCast(&stored.route),
            onWritePty,
        );

        try self.register(stored.pty.master, linux.EPOLL.IN);
        return index;
    }

    pub fn findSession(self: *Server, name: []const u8) ?usize {
        for (self.sessions.items, 0..) |*session, index| {
            if (session.name.eql(name)) return index;
        }
        return null;
    }

    /// Serve clients until `kill-all`, or until every session has ended.
    pub fn run(self: *Server) !void {
        while (self.state == .running) {
            var events: [64]linux.epoll_event = undefined;
            const count = linux.epoll_wait(self.epfd, &events, events.len, -1);
            switch (linux.errno(count)) {
                .INTR => continue,
                .SUCCESS => {},
                else => return Error.SyscallFailed,
            }

            for (events[0..count]) |event| {
                const fd = event.data.fd;
                if (fd == self.listener.fd) {
                    try self.acceptClients();
                } else if (self.clientIndexByFd(fd)) |index| {
                    try self.serviceClient(index);
                } else if (self.sessionIndexByFd(fd)) |index| {
                    try self.serviceSession(index);
                }
            }

            self.reapChildren();
            self.sweepClients();
        }
    }

    fn acceptClients(self: *Server) !void {
        // Level-triggered epoll reports the listener while connections remain,
        // so the queue is drained here.
        while (try self.listener.accept()) |fd| {
            try self.clients.append(self.gpa, .{ .connection = .{ .fd = fd } });
            self.register(fd, linux.EPOLL.IN) catch |err| {
                var dead = self.clients.pop().?;
                dead.deinit(self.gpa);
                return err;
            };
        }
    }

    fn clientIndexByFd(self: *Server, fd: i32) ?usize {
        for (self.clients.items, 0..) |client, index| {
            if (client.connection.fd == fd) return index;
        }
        return null;
    }

    fn sessionIndexByFd(self: *Server, fd: i32) ?usize {
        for (self.sessions.items, 0..) |session, index| {
            if (session.pty.master == fd) return index;
        }
        return null;
    }

    /// Read and act on everything one client has sent.
    fn serviceClient(self: *Server, index: usize) !void {
        if (self.clients.items[index].gone) return;

        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const read = self.clients.items[index].connection.read(&buffer) catch {
                self.dropClient(index);
                return;
            };
            if (read == 0) break;

            // The message handler is told which client it is serving, because
            // an attach has to know where to send the screen and a detach has to
            // know whose name to clear. The struct is named rather than a bare
            // literal so that the sink's parameter type is inferable.
            const context = MessageContext{ .server = self, .client = index };
            try self.clients.items[index].frame.feed(
                self.gpa,
                buffer[0..read],
                context,
                onMessage,
            );

            // The client may have been dropped by its own message.
            if (index >= self.clients.items.len) return;
            if (self.clients.items[index].gone) return;
        }

        try self.flushClient(index);
    }

    /// Decode one request and act on it.
    fn onMessage(context: MessageContext, payload: []const u8) anyerror!void {
        const self = context.server;
        var decoder = protocol.Decoder.init(payload);
        const request = decoder.request() catch |err| {
            try self.failClient(context.client, err);
            return;
        };
        self.handleRequest(context.client, request) catch |err| {
            try self.failClient(context.client, err);
        };
    }

    fn handleRequest(self: *Server, client: usize, request: protocol.Request) !void {
        switch (request) {
            .list => try self.sendListing(client),
            .kill_all => {
                for (self.sessions.items) |*session| {
                    try self.broadcast(session, .{ .exited = .{
                        .name = session.name,
                        .status = session.status,
                    } });
                    // The pty is closed, which hangs up the child, so no
                    // process is left behind with nothing to reach it.
                    _ = linux.kill(session.pty.child, linux.SIG.HUP);
                }
                // Every session is gone, and with them the reason the server
                // exists, so it stops and the socket is removed.
                self.state = .stop;
            },
            .create => |create| {
                var arguments: [64][]const u8 = undefined;
                const count = protocol.splitProgram(create.program, &arguments);
                const index = try self.createSession(.{
                    .name = create.name.slice(),
                    .rows = create.rows,
                    .cols = create.cols,
                    .argv = arguments[0..count],
                });
                // The creating client attaches to what it just made, which is
                // what makes `zmux run` in one step.
                try self.sendEvent(client, .{ .created = .{ .name = create.name } });
                try self.attachClient(client, index, create.rows, create.cols);
            },
            .attach => |attach| {
                const index = self.findSession(attach.name.slice()) orelse
                    return Error.UnknownSession;
                try self.attachClient(client, index, attach.rows, attach.cols);
            },
            .detach => |detach| {
                const index = self.findSession(detach.name.slice()) orelse
                    return Error.UnknownSession;
                _ = self.removeWatcher(index, client);
                self.clients.items[client].watching = .{};
                try self.sendEvent(client, .{ .detached = .{ .name = detach.name } });
            },
            .kill => |kill| {
                const index = self.findSession(kill.name.slice()) orelse
                    return Error.UnknownSession;
                try self.killSession(index);
            },
            .input => |input| {
                const index = self.findSession(input.name.slice()) orelse return;
                const session = &self.sessions.items[index];
                if (session.exited) return;
                _ = session.pty.write(input.data) catch {};
            },
            .resize => |resize| {
                const index = self.findSession(resize.name.slice()) orelse return;
                try self.resizeSession(index, resize.rows, resize.cols);
            },
        }
    }

    fn sendListing(self: *Server, client: usize) !void {
        for (self.sessions.items) |*session| {
            try self.sendEvent(client, .{ .session = .{
                .name = session.name,
                .rows = session.rows,
                .cols = session.cols,
                .clients = @intCast(session.watchers.items.len),
                .pid = session.pty.child,
                .running = !session.exited,
            } });
        }
        try self.sendEvent(client, .list_end);
    }

    fn attachClient(self: *Server, client: usize, index: usize, rows: u16, cols: u16) !void {
        const session = &self.sessions.items[index];

        // The pty is sized to this client, which is the compromise for several
        // clients sharing a session: the newest one to attach wins.
        try self.resizeSession(index, rows, cols);

        for (session.watchers.items) |watcher| {
            if (watcher == client) return;
        }
        try session.watchers.append(self.gpa, client);
        self.clients.items[client].watching = session.name;

        try self.sendEvent(client, .{ .attached = .{
            .name = session.name,
            .rows = session.rows,
            .cols = session.cols,
        } });

        // The screen as it stands, so a reattaching client sees the current
        // state rather than only what happens next.
        try self.sendScreen(client, index);
    }

    fn removeWatcher(self: *Server, session_index: usize, client: usize) bool {
        const watchers = &self.sessions.items[session_index].watchers;
        for (watchers.items, 0..) |watcher, position| {
            if (watcher == client) {
                _ = watchers.swapRemove(position);
                return true;
            }
        }
        return false;
    }

    /// End a session, telling its watchers and releasing its resources.
    fn killSession(self: *Server, index: usize) !void {
        var session = &self.sessions.items[index];
        try self.broadcast(session, .{ .exited = .{
            .name = session.name,
            .status = session.status,
        } });

        for (session.watchers.items) |client| {
            self.clients.items[client].watching = .{};
        }
        session.watchers.clearRetainingCapacity();

        self.unregister(session.pty.master);
        // The child is signalled before the pty goes, so it does not linger.
        _ = linux.kill(session.pty.child, linux.SIG.HUP);
        session.deinit(self.gpa);
        _ = self.sessions.swapRemove(index);
    }

    fn resizeSession(self: *Server, index: usize, rows: u16, cols: u16) !void {
        var session = &self.sessions.items[index];
        if (rows == 0 or cols == 0) return;
        if (session.rows == rows and session.cols == cols) return;

        session.pty.setWindowSize(.{ .rows = rows, .cols = cols }) catch {};
        session.terminal.resize(cols, rows, 0, 0) catch {};
        session.rows = rows;
        session.cols = cols;

        // The screen reflowed, so every watcher is told the new size and
        // re-sent the screen; a client that only saw the following output would
        // be drawing at the wrong width.
        for (session.watchers.items) |client| {
            try self.sendEvent(client, .{ .attached = .{
                .name = session.name,
                .rows = rows,
                .cols = cols,
            } });
            try self.sendScreen(client, index);
        }
    }

    /// Read the pty and forward whatever arrived.
    fn serviceSession(self: *Server, index: usize) !void {
        var session = &self.sessions.items[index];

        const read = session.pty.read(session.read_buffer) catch |err| switch (err) {
            pty_mod.Error.Closed => {
                // The slave closed, so the child is gone even if the exit status
                // has not been collected yet.
                try self.sessionEnded(index, session.status);
                return;
            },
            else => return err,
        };
        if (read == 0) return;

        session.terminal.write(session.read_buffer[0..read]);

        // Replies the parser produced go back to the program before any output
        // is forwarded, because a program waiting on one is not producing more.
        if (session.reply.items.len > 0) {
            _ = session.pty.write(session.reply.items) catch {};
            session.reply.clearRetainingCapacity();
        }

        // The bytes are forwarded unchanged. The client has its own terminal and
        // parses them itself, which is what lets the two sides disagree about
        // the screen without the server having to reconcile them.
        try self.broadcast(session, .{ .output = .{
            .name = session.name,
            .data = session.read_buffer[0..read],
        } });
    }

    fn reapChildren(self: *Server) void {
        var index: usize = 0;
        while (index < self.sessions.items.len) : (index += 1) {
            const session = &self.sessions.items[index];
            if (session.exited) continue;
            const status = session.pty.reap() orelse continue;
            // A signalled child is reported the way a shell would: 128 plus the
            // signal number. The clamp is on the sum rather than on the signal,
            // because `@min(signal, 127)` narrows to `u7` and 128 does not fit in
            // it.
            const code: u8 = if (status.signaled)
                @intCast(@min(@as(u32, 128) + status.signal, 255))
            else
                status.code;
            self.sessionEnded(index, code) catch {};
        }
    }

    fn sessionEnded(self: *Server, index: usize, status: u8) !void {
        const session = &self.sessions.items[index];
        if (session.exited) return;
        session.exited = true;
        session.status = status;
        // The pty stays open so a client that attaches later still sees the
        // final screen, but its readability is no longer of interest.
        self.unregister(session.pty.master);

        try self.broadcast(session, .{ .exited = .{
            .name = session.name,
            .status = status,
        } });
    }

    /// Queue an event for one client.
    fn sendEvent(self: *Server, client: usize, event: protocol.Event) !void {
        const payload = try self.encoder.writeEvent(event);
        try socket.encode(&self.clients.items[client].outgoing, self.gpa, payload);
    }

    /// Queue the same event for everyone watching a session.
    fn broadcast(self: *Server, session: *Session, event: protocol.Event) !void {
        const payload = try self.encoder.writeEvent(event);
        for (session.watchers.items) |client| {
            if (client >= self.clients.items.len) continue;
            if (self.clients.items[client].gone) continue;
            try socket.encode(&self.clients.items[client].outgoing, self.gpa, payload);
        }
    }

    /// Send a client the whole screen as a fresh VT byte stream.
    ///
    /// Rather than a snapshot format, the screen is re-emitted as the sequences
    /// that would produce it: cursor moves, SGR, and the text of each non-blank
    /// row. The client parses it with the terminal it already has, so there is
    /// no second rendering path and no snapshot API to keep in step with
    /// libghostty-vt.
    fn sendScreen(self: *Server, client: usize, session_index: usize) !void {
        var session = &self.sessions.items[session_index];

        var screen: std.ArrayList(u8) = .empty;
        defer screen.deinit(self.gpa);

        // Clear and home first, so any previous contents on the client are
        // replaced rather than partially overwritten.
        try screen.appendSlice(self.gpa, "\x1b[2J\x1b[H");

        var render = session.terminal.createRenderState() catch return;
        defer render.deinit();

        var painter = ScreenPainter{ .buffer = &screen, .gpa = self.gpa };
        render.forEachRow(&painter, ScreenPainter.visit) catch {};

        if (painter.failed) return;

        try self.sendEvent(client, .{ .output = .{
            .name = session.name,
            .data = screen.items,
        } });
    }

    /// Write as much of a client's queue as the socket accepts.
    fn flushClient(self: *Server, index: usize) !void {
        var client = &self.clients.items[index];
        while (client.outgoing.items.len > 0) {
            const written = client.connection.write(client.outgoing.items) catch {
                self.dropClient(index);
                return;
            };
            if (written == 0) return;
            // Dropping from the front is O(n); the queue is small because a
            // client that falls behind is dropped rather than buffered
            // without limit.
            std.mem.copyForwards(
                u8,
                client.outgoing.items[0 .. client.outgoing.items.len - written],
                client.outgoing.items[written..],
            );
            client.outgoing.shrinkRetainingCapacity(client.outgoing.items.len - written);
        }
    }

    /// Mark a client dead and release it at the end of the loop pass.
    ///
    /// The teardown is deferred because the caller may be holding an index into
    /// `clients`, and removing an entry mid-pass would renumber the ones after
    /// it.
    fn dropClient(self: *Server, index: usize) void {
        const client = &self.clients.items[index];
        if (client.gone) return;
        client.gone = true;
        self.unregister(client.connection.fd);
        self.detachFromSessions(index);
    }

    fn detachFromSessions(self: *Server, client: usize) void {
        for (self.sessions.items) |*session| {
            _ = self.removeWatcherByIndex(session, client);
        }
    }

    fn removeWatcherByIndex(self: *Server, session: *Session, client: usize) bool {
        _ = self;
        for (session.watchers.items, 0..) |watcher, position| {
            if (watcher == client) {
                _ = session.watchers.swapRemove(position);
                return true;
            }
        }
        return false;
    }

    fn sweepClients(self: *Server) void {
        var index: usize = 0;
        while (index < self.clients.items.len) {
            if (!self.clients.items[index].gone) {
                index += 1;
                continue;
            }

            // `swapRemove` puts the last client into this slot. Every watcher
            // list spells clients as indices, so the moved client's entry has to
            // be rewritten from its old index to its new one. The old index is
            // the last one, which must be read before the removal shrinks the
            // list.
            const last = self.clients.items.len - 1;
            var removed = self.clients.swapRemove(index);
            removed.deinit(self.gpa);

            if (last != index) {
                self.reindexClient(index, last);
                // The client that moved may itself be dead; it is examined again
                // on the next pass rather than here.
                if (self.clients.items[index].gone) continue;
            }
            // The entry now at `index` was not the dead one, so it still needs
            // visiting.
            if (last == index) index += 1;
        }
    }

    /// Rewrite watcher entries that named the client at `old` to `new`.
    fn reindexClient(self: *Server, new: usize, old: usize) void {
        for (self.sessions.items) |*session| {
            for (session.watchers.items) |*watcher| {
                if (watcher.* == old) watcher.* = new;
            }
        }
    }

    fn failClient(self: *Server, client: usize, err: anyerror) !void {
        const message = switch (err) {
            Error.UnknownSession => "no such session",
            Error.SessionExists => "a session with that name already exists",
            protocol.Error.UnknownTag => "unknown request",
            protocol.Error.BadLength => "malformed request",
            protocol.Error.BadValue => "invalid value in request",
            else => "request failed",
        };
        try self.sendEvent(client, .{ .failure = .{ .message = message } });
        try self.flushClient(client);
    }
};

/// Emits a screen as the VT sequences that would produce it.
///
/// This is the alternative to a snapshot format. The client already has a
/// terminal, so re-emitting cursor moves and text reuses the one
/// libghostty-vt rendering path instead of adding a second one that has to stay
/// in step with the library.
const ScreenPainter = struct {
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    row_index: usize = 0,
    failed: bool = false,

    fn visit(self: *ScreenPainter, row: *vt.RowIterator) bool {
        self.paint(row) catch {
            self.failed = true;
            return false;
        };
        self.row_index += 1;
        return true;
    }

    fn paint(self: *ScreenPainter, row: *vt.RowIterator) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);

        var collector = CellCollector{ .line = &line, .gpa = self.gpa };
        _ = row.forEachCell(&collector, CellCollector.collect) catch {};

        // Trailing blanks are skipped so the stream stays short, and a row of
        // only blanks emits nothing at all.
        const text = std.mem.trimEnd(u8, line.items, " ");
        if (text.len == 0) return;

        var move_buffer: [32]u8 = undefined;
        const move = try std.fmt.bufPrint(
            &move_buffer,
            "\x1b[{d};1H",
            .{self.row_index + 1},
        );
        try self.buffer.appendSlice(self.gpa, move);
        try self.buffer.appendSlice(self.gpa, text);
    }
};

/// Copies the text of each cell into a line buffer.
const CellCollector = struct {
    line: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn collect(self: *CellCollector, cell: *vt.CellIterator) void {
        var codepoints: [8]u32 = undefined;
        var utf8: [32]u8 = undefined;
        const bytes = cell.graphemesUtf8(&codepoints, &utf8);
        if (bytes.len == 0) {
            self.line.append(self.gpa, ' ') catch {};
            return;
        }
        self.line.appendSlice(self.gpa, bytes) catch {};
    }
};

/// Receive the bytes the terminal wants sent to the program.
///
/// This runs inside `vt_write`, so it may only append to a buffer. Writing to
/// the pty from here would reenter the parser.
fn onWritePty(
    terminal: vt.c.GhosttyTerminal,
    userdata: ?*anyopaque,
    data: [*c]const u8,
    len: usize,
) callconv(.c) void {
    _ = terminal;
    // The userdata is the `ReplyRoute` stored in the session, whose address is
    // stable because the session lives in the server's list and the route is a
    // field of it that is never moved while it is registered.
    const route: *ReplyRoute = @ptrCast(@alignCast(userdata.?));
    // A failed allocation would lose a reply and hang the program, but there is
    // no way to report it from a C callback. The missing reply surfaces as a
    // stalled program instead.
    route.buffer.appendSlice(route.gpa, data[0..len]) catch {};
}

test "removing a client rewrites the indices of the one moved into its slot" {
    // This is the bookkeeping `sweepClients` depends on, and it is silent when
    // wrong: a watcher list holding a stale index sends another client's screen
    // to the wrong terminal. The state is fabricated because the real paths
    // need sockets and ptys, which a unit test cannot have.
    const gpa = std.testing.allocator;

    var server: Server = .{
        .gpa = gpa,
        .listener = .{ .fd = -1, .path = "/nonexistent" },
        .epfd = -1,
        .path = "/nonexistent",
        .encoder = protocol.Encoder.init(gpa),
        .environ = undefined,
    };
    defer {
        server.encoder.deinit();
        // The sessions are fabricated, so their terminals were never created and
        // only their lists need freeing. Their `watchers` and `reply` are the
        // allocations.
        for (server.sessions.items) |*session| {
            session.watchers.deinit(gpa);
            session.reply.deinit(gpa);
        }
        server.sessions.deinit(gpa);
        server.clients.deinit(gpa);
    }

    // Four clients, with three sessions watching various of them.
    for (0..4) |_| try server.clients.append(gpa, .{ .connection = .{ .fd = -1 } });
    for (0..3) |_| {
        const session: Session = .{
            .name = try protocol.Name.init("s"),
            .pty = .{ .master = -1, .child = 0 },
            .terminal = undefined,
            .rows = 24,
            .cols = 80,
            .read_buffer = &.{},
        };
        try server.sessions.append(gpa, session);
    }

    // Sessions 0 and 1 watch client 3, which is the last and therefore the one
    // that gets moved when an earlier client is removed.
    try server.sessions.items[0].watchers.append(gpa, 0);
    try server.sessions.items[0].watchers.append(gpa, 3);
    try server.sessions.items[1].watchers.append(gpa, 3);
    // Session 2 watches client 1, which must be left alone.
    try server.sessions.items[2].watchers.append(gpa, 1);

    // Remove client 1, so client 3 moves into slot 1.
    server.clients.items[1].gone = true;
    server.sweepClients();

    try std.testing.expectEqual(@as(usize, 3), server.clients.items.len);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items[0].watchers.items[1]);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items[1].watchers.items[0]);
    // Client 1 is gone, so the session that watched it keeps a stale entry;
    // the entry is harmless because `broadcast` skips out-of-range and dead
    // clients, but the index must not have been rewritten to something live.
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items[2].watchers.items[0]);
}

test "a session name round trips through the protocol" {
    // The server stores names as `protocol.Name`, so the validation rules it
    // applies are the protocol's. This pins that the two agree.
    const name = try protocol.Name.init("work");
    try std.testing.expect(name.eql("work"));
    try std.testing.expect(!name.eql("other"));
    try std.testing.expectError(protocol.Error.BadValue, protocol.Name.init("a/b"));
}
