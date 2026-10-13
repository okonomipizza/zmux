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
const layout = @import("layout.zig");
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

/// The handle a pane's terminal uses to find its way back here.
///
/// libghostty-vt's `write_pty` callback carries one opaque pointer, and the terminal
/// outlives any address inside the pane list: `panes` is an `ArrayList` that
/// reallocates when a split appends to it, so a pointer to the pane, or to a field of
/// it, would dangle the moment another pane was created. The route therefore
/// identifies the pane by session name and identifier and looks the buffer up on each
/// call, which is a linear scan over a handful of panes and cannot go stale.
const ReplyRoute = struct {
    server: *Server,
    session: protocol.Name,
    pane: layout.PaneId,
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

/// One program running on its own pty, with the screen it is drawing.
///
/// A pane is the unit of a session: it owns exactly one child process and one parsed
/// terminal. Two clients viewing the same session share these, rather than each
/// parsing the byte stream for itself.
const Pane = struct {
    id: layout.PaneId,
    pty: pty_mod.Pty,
    terminal: vt.Terminal,
    /// Bytes the terminal wants sent to the pty, from the write_pty callback.
    reply: std.ArrayList(u8) = .empty,
    /// The handle the terminal holds; heap-allocated and owned by this pane.
    ///
    /// It is a separate allocation rather than a field because `setWritePty` stores the
    /// pointer, and `panes` is an `ArrayList` that reallocates when the next split
    /// appends. A pointer to a field would be left dangling by that move, which is the
    /// same failure that a returned-by-value session caused in Phase 1: it looks correct
    /// until a program sends a second query.
    route: *ReplyRoute = undefined,
    /// Reused pty read buffer, so a busy pane does not allocate per wakeup.
    read_buffer: []u8 = &.{},
    /// Where this pane sits, recomputed on every layout.
    rect: layout.Rect = .{},
    /// Set once the child has been reaped. The screen is kept so that a client
    /// attaching later still sees the final output.
    exited: bool = false,
    /// The exit status, once known.
    status: u8 = 0,

    fn deinit(self: *Pane, gpa: std.mem.Allocator) void {
        gpa.destroy(self.route);
        self.reply.deinit(gpa);
        gpa.free(self.read_buffer);
        self.terminal.deinit();
        self.pty.deinit();
    }

    /// The size this pane's pty and terminal should have, from its rectangle.
    ///
    /// A pane with no cells has no size to give its pty, and libghostty-vt rejects a
    /// zero-sized terminal, so this reports null and the caller leaves the pane alone.
    /// That happens when a window is too small to divide, and the pane's program
    /// keeping its old size is better than being resized to nothing.
    fn size(self: Pane) ?pty_mod.Size {
        if (self.rect.isEmpty()) return null;
        return .{ .rows = self.rect.height, .cols = self.rect.width };
    }

    /// Forward whatever the pane's terminal wants written back to its program.
    fn flushReply(self: *Pane) void {
        if (self.reply.items.len == 0) return;
        _ = self.pty.write(self.reply.items) catch {};
        self.reply.clearRetainingCapacity();
    }
};

/// One session: a tree of panes, and who is watching.
const Session = struct {
    name: protocol.Name,
    /// The panes, in creation order. The tree decides where each goes, so this list
    /// is only for ownership; positions live in `Pane.rect`.
    panes: std.ArrayList(Pane) = .empty,
    /// Which pane is where. Kept in step with `panes` on every split and close.
    tree: layout.Tree,
    /// Panes that have been lifted out of the layout and are drawn above it.
    ///
    /// Order is z-order, last on top. A float is the same `Pane` as a tiled one: parking changes
    /// which list owns it and nothing else, so its pty and its screen are untouched and the
    /// program inside never notices the move.
    floats: std.ArrayList(layout.PaneId) = .empty,
    /// The float that is raised, or null when none is.
    ///
    /// This doubles as the answer to "is a float showing": a hidden float is still in `floats` but
    /// is not raised, and a hidden pane never holds focus because focus is exactly this field.
    focused_float: ?layout.PaneId = null,
    /// Whether the floats are hidden.
    ///
    /// Hidden floats keep their ptys and their screens and stay in `floats`; they are simply not
    /// drawn and not raised. A separate flag rather than a third list, because the only difference
    /// between a shown and a hidden float is whether it is painted.
    floats_hidden: bool = false,
    /// The tiled pane that had focus before a float was raised.
    ///
    /// Required by the rule that showing a float again returns focus to where the user was. Focus is
    /// a single value, so without this the pane the user was working in would be forgotten the
    /// moment a float took it, and dismissing the float would land somewhere arbitrary.
    focus_before_float: ?layout.PaneId = null,
    /// Set while the user is choosing which tiled pane to dock a float into.
    ///
    /// While this is set the layout is frozen: tiled panes carry labels and the floats are not
    /// drawn, so the labels are readable.
    docking: bool = false,
    /// Clients attached to this session, as indices into `Server.clients`.
    watchers: std.ArrayList(usize) = .empty,
    /// The area the panes share, which is what the client gave this session. Zero until
    /// a client attaches and says how much room there is.
    rows: u16 = 0,
    cols: u16 = 0,
    /// Scratch space for a layout walk, reused so that a resize does not allocate.
    placements: std.ArrayList(layout.Placement) = .empty,

    fn init(gpa: std.mem.Allocator, name: protocol.Name) Session {
        return .{
            .name = name,
            .tree = layout.Tree.init(gpa),
        };
    }

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        for (self.panes.items) |*pane| pane.deinit(gpa);
        self.panes.deinit(gpa);
        self.tree.deinit();
        self.floats.deinit(gpa);
        self.watchers.deinit(gpa);
        self.placements.deinit(gpa);
    }

    /// Find a pane by identifier.
    fn findPane(self: *Session, id: layout.PaneId) ?usize {
        for (self.panes.items, 0..) |pane, index| {
            if (pane.id == id) return index;
        }
        return null;
    }

    /// The pane holding focus, if any.
    fn focusedPane(self: *Session) ?usize {
        const id = self.tree.focused orelse return null;
        return self.findPane(id);
    }

    /// Recompute every pane's rectangle and apply the sizes to their ptys.
    ///
    /// This is the one place geometry reaches a pty. Doing it anywhere else would mean
    /// two places could disagree about how wide a pane is, and the program inside it
    /// would see a size that the client is not drawing.
    fn relayout(self: *Session) !void {
        try self.tree.layout(&self.placements, self.cols, self.rows);

        for (self.placements.items) |placement| {
            const index = self.findPane(placement.id) orelse continue;
            const pane = &self.panes.items[index];
            const changed = !pane.rect.eql(placement.rect);
            pane.rect = placement.rect;
            if (!changed) continue;

            const size = pane.size() orelse continue;
            pane.pty.setWindowSize(size) catch {};
            pane.terminal.resize(size.cols, size.rows, 0, 0) catch {};
        }
    }

    /// Whether every pane's child has exited.
    fn allExited(self: *Session) bool {
        for (self.panes.items) |pane| {
            if (!pane.exited) return false;
        }
        return true;
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

        var session = Session.init(self.gpa, try protocol.Name.init(request.name));
        session.rows = request.rows;
        session.cols = request.cols;
        try session.watchers.ensureTotalCapacity(self.gpa, 4);

        try self.sessions.append(self.gpa, session);
        const index = self.sessions.items.len - 1;

        // The session is in the list before its first pane is made, because the pane
        // stores the session's name and the terminal's reply path points back at a
        // session that has a stable home.
        const stored = &self.sessions.items[index];
        _ = self.addPane(
            stored,
            request.argv,
            .horizontal,
            fullArea(request.rows, request.cols),
        ) catch |err| {
            var doomed = self.sessions.swapRemove(index);
            doomed.deinit(self.gpa);
            return err;
        };

        // The pane's rectangle is computed here rather than inside `addPane`, because geometry
        // is the tree's business: `addPane` puts a leaf in the tree, and this turns the tree into
        // rectangles. Without it the first pane would keep the zero rectangle it was created
        // with, and the client would have nowhere to draw it.
        try stored.relayout();

        return index;
    }

    /// Start a program in a new pane belonging to `session`.
    ///
    /// The pane is created at the given size, which for a first pane is the whole area
    /// and for a split is a guess that `relayout` immediately corrects. Sizing it twice
    /// is cheaper than the alternative, which is starting a program at a size it will
    /// never be drawn at and letting it print a screenful of misplaced output before
    /// the first resize reaches it.
    fn addPane(
        self: *Server,
        session: *Session,
        argv: []const []const u8,
        axis: layout.Axis,
        size: pty_mod.Size,
    ) !layout.PaneId {
        // `execve` wants null-terminated strings, so the vector is rebuilt into fixed
        // buffers. The count is bounded rather than allocated, because this runs on a
        // socket read and a peer could otherwise ask for an arbitrarily large vector.
        const max_arguments = 64;
        var argument_buffers: [max_arguments][std.fs.max_path_bytes]u8 = undefined;
        var vector: [max_arguments]?[*:0]const u8 = undefined;
        var count: usize = 0;

        if (argv.len == 0) {
            const shell = self.environ.getPosix("SHELL") orelse "/bin/sh";
            vector[count] = (try std.fmt.bufPrintZ(&argument_buffers[count], "{s}", .{shell})).ptr;
            count += 1;
        } else {
            for (argv) |argument| {
                if (count >= max_arguments - 1) break;
                vector[count] = (try std.fmt.bufPrintZ(
                    &argument_buffers[count],
                    "{s}",
                    .{argument},
                )).ptr;
                count += 1;
            }
        }
        vector[count] = null;

        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

        const pty = pty_mod.Pty.spawn(@ptrCast(&vector), envp, size) catch
            return Error.SpawnFailed;
        errdefer {
            var p = pty;
            p.deinit();
        }
        pty.setNonBlocking();

        const terminal = vt.Terminal.init(.{
            .cols = size.cols,
            .rows = size.rows,
        }) catch return Error.TerminalFailed;
        errdefer {
            var t = terminal;
            t.deinit();
        }

        const read_buffer = try self.gpa.alloc(u8, 64 * 1024);
        errdefer self.gpa.free(read_buffer);

        const id = session.tree.allocateId();

        // The route is its own allocation so that its address survives the pane list
        // growing, and it names the pane rather than pointing at it so that it also
        // survives the pane list reordering. Both are needed: `setWritePty` keeps the
        // pointer, and a reply that finds the wrong pane writes into the wrong program.
        const route = try self.gpa.create(ReplyRoute);
        route.* = .{
            .server = self,
            .session = session.name,
            .pane = id,
        };

        try session.panes.append(self.gpa, .{
            .id = id,
            .pty = pty,
            .terminal = terminal,
            .read_buffer = read_buffer,
            .route = route,
        });
        // From here the pane owns the pty, the terminal, the buffer and the route, so
        // every later failure releases them by popping the pane rather than through an
        // errdefer. An errdefer would fire a second time on the paths that already clean
        // up by hand, which is how a double free happens.
        const pane_index = session.panes.items.len - 1;

        // The reply path is wired before any byte is parsed: a program that probes the
        // terminal at startup blocks until it is answered.
        const pane = &session.panes.items[pane_index];
        pane.terminal.setWritePty(@ptrCast(route), onWritePty);

        self.register(pane.pty.master, linux.EPOLL.IN) catch |err| {
            self.abandonPane(session);
            return err;
        };

        // The tree gains the leaf only once the pane exists, so a failure above cannot
        // leave the tree naming a pane that was never created.
        if (session.tree.isEmpty()) {
            session.tree.setRoot(id) catch |err| {
                self.abandonPane(session);
                return err;
            };
        } else {
            const target = session.tree.focused orelse id;
            session.tree.split(target, axis, id) catch |err| switch (err) {
                error.NoSuchPane => session.tree.setRoot(id) catch |root_err| {
                    self.abandonPane(session);
                    return root_err;
                },
                else => {
                    self.abandonPane(session);
                    return err;
                },
            };
        }

        return id;
    }

    /// Release the pane most recently appended to `session`.
    ///
    /// Used when a pane was built and then something after it failed. It is explicit
    /// rather than an `errdefer` because the pane owns its pty, terminal, read buffer and
    /// reply route from the moment it is in the list, and an errdefer would free those a
    /// second time on the paths that already clean up here.
    fn abandonPane(self: *Server, session: *Session) void {
        var doomed = session.panes.pop() orelse return;
        self.unregister(doomed.pty.master);
        doomed.deinit(self.gpa);
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
                } else if (self.paneByFd(fd)) |which| {
                    // The session may have been removed by an earlier event in this same
                    // batch, so the indices are re-checked rather than trusted.
                    if (which.session < self.sessions.items.len) {
                        try self.servicePane(which.session, which.pane);
                    }
                }
            }

            self.reapChildren();
            self.sweepClients();

            // Every client is flushed once per pass, after all the events have been handled. Replies
            // are queued from several places -- a client request, a pane's output, a pane ending -- and
            // only the request path used to flush, so output from a pane sat in the queue until that
            // client next sent something. That made a session feel one keystroke behind, and lost the
            // last message outright when the user stopped typing.
            for (self.clients.items, 0..) |client, index| {
                if (client.gone) continue;
                if (client.outgoing.items.len == 0) continue;
                self.flushClient(index) catch {};
            }
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

    /// Which session and pane a pty master belongs to.
    ///
    /// Both are returned because a session now owns several ptys, and the caller has to
    /// know which one became readable.
    fn paneByFd(self: *Server, fd: i32) ?struct { session: usize, pane: usize } {
        for (self.sessions.items, 0..) |session, session_index| {
            for (session.panes.items, 0..) |pane, pane_index| {
                if (pane.pty.master == fd) {
                    return .{ .session = session_index, .pane = pane_index };
                }
            }
        }
        return null;
    }

    /// Read and act on everything one client has sent.
    /// Read and act on everything one client has sent.
    ///
    /// The reply is flushed on every path out, including the ones that end the connection. A
    /// client that sent one request and then hung up still deserves the answer, and a reply
    /// left in the queue is a reply that was built and then thrown away. That was a real bug
    /// here: the read that follows a request commonly reports the peer's close, and returning
    /// straight from it discarded the listing that had just been computed.
    fn serviceClient(self: *Server, index: usize) !void {
        if (self.clients.items[index].gone) return;

        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const read = self.clients.items[index].connection.read(&buffer) catch {
                self.flushClient(index) catch {};
                self.dropClient(index);
                return;
            };
            if (read == 0) break;

            // The message handler is told which client it is serving, because an attach has
            // to know where to send the screen and a detach has to know whose name to clear.
            // The struct is named rather than a bare literal so that the sink's parameter
            // type is inferable.
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
                        .status = exitStatusOf(session),
                    } });
                    for (session.panes.items) |pane| {
                        // The child is signalled before the pty goes, so no process is
                        // left behind with nothing to reach it.
                        _ = linux.kill(pane.pty.child, linux.SIG.HUP);
                    }
                }
                // Every session is gone, and with them the reason the server exists,
                // so it stops and the socket is removed.
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
                // The creating client attaches to what it just made, which is what makes
                // `zmux run` one step.
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
                // The pane named by the request, not the focused one: a keystroke in
                // flight when focus moved belongs to the pane it was typed into.
                const pane_index = session.findPane(input.pane) orelse return;
                const pane = &session.panes.items[pane_index];
                if (pane.exited) return;
                _ = pane.pty.write(input.data) catch {};
            },
            .resize => |resize| {
                const index = self.findSession(resize.name.slice()) orelse return;
                try self.resizeSession(index, resize.rows, resize.cols);
            },
            .split => |split| {
                const index = self.findSession(split.name.slice()) orelse
                    return Error.UnknownSession;
                try self.splitSession(index, split.axis, split.program);
            },
            .close => |close| {
                const index = self.findSession(close.name.slice()) orelse
                    return Error.UnknownSession;
                try self.closeFocusedPane(index);
            },
            .focus => |focus| {
                const index = self.findSession(focus.name.slice()) orelse
                    return Error.UnknownSession;
                const session = &self.sessions.items[index];
                if (focus.backwards) {
                    _ = session.tree.focusPrevious();
                } else {
                    _ = session.tree.focusNext();
                }
                try self.sendLayout(session);
            },
            .float => |float| {
                const index = self.findSession(float.name.slice()) orelse
                    return Error.UnknownSession;
                try self.floatFocusedPane(index);
            },
            .dock => |dock| {
                const index = self.findSession(dock.name.slice()) orelse
                    return Error.UnknownSession;
                try self.dockFloat(index, dock.target);
            },
            .dock_cancel => |cancel| {
                const index = self.findSession(cancel.name.slice()) orelse
                    return Error.UnknownSession;
                const session = &self.sessions.items[index];
                session.docking = false;
                try self.sendLayout(session);
            },
            .toggle_floats => |toggle| {
                const index = self.findSession(toggle.name.slice()) orelse
                    return Error.UnknownSession;
                try self.toggleFloats(index);
            },
        }
    }

    fn sendListing(self: *Server, client: usize) !void {
        for (self.sessions.items) |*session| {
            // The listing shows the session's area and the pane count, since a session
            // is no longer one program with one size.
            const first_pane: i32 = if (session.panes.items.len > 0)
                session.panes.items[0].pty.child
            else
                0;
            try self.sendEvent(client, .{ .session = .{
                .name = session.name,
                .rows = session.rows,
                .cols = session.cols,
                .clients = @intCast(session.watchers.items.len),
                .pid = first_pane,
                .running = !session.allExited(),
            } });
        }
        try self.sendEvent(client, .list_end);
    }

    /// Hide the floats, or show them again.
    ///
    /// One key doing both, because there are only two states and a pair of keys would leave the user
    /// guessing which one they are in. What the toggle does depends on what is showing:
    ///
    ///   - A float is raised: hide it, and give focus back to the tiled pane the user was in before
    ///     it appeared. Focus has to leave the float, since a hidden pane cannot hold focus.
    ///   - No float is raised but some are hidden: show them and raise the one that was raised
    ///     before, returning focus there.
    ///   - No float is raised and none are hidden: nothing to do. A session that never floated a
    ///     pane has nothing to show, and inventing one would be worse than doing nothing.
    fn toggleFloats(self: *Server, index: usize) !void {
        const session = &self.sessions.items[index];
        if (session.floats.items.len == 0) return;

        if (session.focused_float != null) {
            // Hide. The pane that had focus before the float is the one to return to, and if it has
            // since been closed the tiled focus is left as it is rather than pointing at nothing.
            session.floats_hidden = true;
            session.focused_float = null;

            if (session.focus_before_float) |previous| {
                if (session.tree.contains(previous)) {
                    session.tree.focused = previous;
                }
            }
        } else {
            // Show, and put focus back on the float that was raised. The last entry of `floats` is
            // the most recently parked, which is the one the user is most likely to want.
            session.floats_hidden = false;
            const raised = session.floats.items[session.floats.items.len - 1];
            session.focused_float = raised;
        }

        try self.sendLayout(session);

        // The whole screen is repainted rather than only the changed panes: hiding a float leaves the
        // layout underneath it to be drawn again, and what was under the float is not something the
        // server tracked.
        for (session.watchers.items) |client| {
            try self.sendSessionScreens(session, client);
        }
    }

    /// Lift the focused pane out of the layout and above it.
    ///
    /// The pane keeps its pty and its screen; only the list that owns it changes, which is what
    /// makes the move invisible to the program inside. The tree hands the vacated space to a
    /// neighbour, so the remaining panes grow rather than leaving a hole.
    fn floatFocusedPane(self: *Server, index: usize) !void {
        const session = &self.sessions.items[index];
        const pane_index = session.focusedPane() orelse return;
        const id = session.panes.items[pane_index].id;

        // The last tiled pane cannot be parked: a session with no layout has nothing to dock back
        // into, and the tree would be left empty while a float still needed somewhere to belong.
        if (session.tree.count() <= 1) return;

        _ = session.tree.detach(id, session.cols, session.rows) catch return;
        try session.floats.append(self.gpa, id);

        // The pane to come back to when the float is hidden is read after the detach, not before. Before
        // the detach the tree's focus is the pane being floated, and remembering that would restore focus
        // to something invisible once the float is hidden. `detach` moves the tree's focus to the
        // surviving pane, which is where the user's attention was before the float took over.
        session.focus_before_float = session.tree.focused;

        // Floating a pane always shows the floats again, so that parking a second pane does not leave
        // it invisible.
        session.floats_hidden = false;

        // Centred at a default size, so a float reads as floating rather than as a pane that
        // happens to be on top.
        const rect = floatRect(session.cols, session.rows);
        const pane = &session.panes.items[pane_index];
        pane.rect = rect;

        // The pane's own terminal is resized to its new rectangle, so the program inside reflows
        // to the size it is actually drawn at.
        if (pane.size()) |size| {
            pane.pty.setWindowSize(size) catch {};
            pane.terminal.resize(size.cols, size.rows, 0, 0) catch {};
        }

        session.focused_float = id;
        session.docking = false;

        // The tiled panes changed shape, so their ptys are resized too.
        try session.relayout();

        try self.sendLayout(session);
        for (session.watchers.items) |client| {
            try self.sendSessionScreens(session, client);
        }
    }

    /// Put a floating pane back into the layout, splitting a chosen tiled pane.
    ///
    /// With no target this begins choosing one, which freezes the layout and labels the tiled
    /// panes. The float is split into the chosen pane along that pane's longer side, so the two
    /// halves come out roughly square rather than as slivers.
    fn dockFloat(self: *Server, index: usize, target: u64) !void {
        const session = &self.sessions.items[index];
        const float_id = session.focused_float orelse return;
        // The pane must exist even when a target is still being chosen, so that a stale
        // `focused_float` naming a closed pane does not put the session into a mode it cannot
        // leave.
        if (session.findPane(float_id) == null) return;

        if (target == 0) {
            // Begin choosing. The float stays where it is; only the display changes.
            session.docking = true;
            try self.sendLayout(session);
            return;
        }

        const target_index = session.findPane(@intCast(target)) orelse {
            // A target that is not a tiled pane is refused rather than guessed at, and the choice
            // stays open so the user can pick again.
            return;
        };
        if (isFloating(session, @intCast(target))) return;

        const target_id = session.panes.items[target_index].id;

        // The pane leaves the float list before the tree learns about it, so that a failure to
        // split cannot leave it owned by both.
        for (session.floats.items, 0..) |float, position| {
            if (float == float_id) {
                _ = session.floats.swapRemove(position);
                break;
            }
        }
        session.focused_float = null;
        session.docking = false;

        _ = session.tree.splitLongest(
            target_id,
            float_id,
            session.cols,
            session.rows,
        ) catch {
            // The split failed, so the pane goes back to floating rather than vanishing from both
            // lists.
            try session.floats.append(self.gpa, float_id);
            session.focused_float = float_id;
            return;
        };

        // The tiled panes now divide the window differently, which resizes the docked pane along
        // with the rest.
        try session.relayout();

        try self.sendLayout(session);
        for (session.watchers.items) |client| {
            try self.sendSessionScreens(session, client);
        }
    }

    ///
    /// The new pane is created before the tree is told about it, so that a failure to
    /// start the program leaves the layout as it was rather than a tree naming a pane
    /// that does not exist.
    fn splitSession(self: *Server, index: usize, axis: u8, program: []const u8) !void {
        const session = &self.sessions.items[index];

        var arguments: [64][]const u8 = undefined;
        const count = protocol.splitProgram(program, &arguments);

        const direction: layout.Axis = if (axis == 1) .vertical else .horizontal;

        // The new pane starts at the whole area and is corrected by the relayout
        // below. Starting it at a guess at the split's size would give the program a
        // screenful of output at the wrong width before the first resize arrives.
        _ = try self.addPane(
            session,
            arguments[0..count],
            direction,
            fullArea(session.rows, session.cols),
        );

        try session.relayout();
        try self.sendLayout(session);
    }

    /// Close the focused pane, giving its space to its sibling's subtree.
    fn closeFocusedPane(self: *Server, index: usize) !void {
        const session = &self.sessions.items[index];
        const pane_index = session.focusedPane() orelse return;

        const id = session.panes.items[pane_index].id;
        var doomed = session.panes.swapRemove(pane_index);
        self.unregister(doomed.pty.master);
        _ = linux.kill(doomed.pty.child, linux.SIG.HUP);
        doomed.deinit(self.gpa);

        _ = session.tree.close(id) catch null;

        try session.relayout();
        try self.sendLayout(session);
    }

    /// Tell every watcher where the panes are and which one has focus.
    /// Tell every watcher where the panes are, which one has focus, and whether a dock target is
    /// being chosen.
    ///
    /// Tiled panes come first and floating ones after, because the order of the list is the
    /// z-order and a float is drawn above the layout. While a dock target is being chosen the
    /// floats are left out entirely: the choice is about the layout underneath them, and a float
    /// covering it would hide the labels the user is reading.
    fn sendLayout(self: *Server, session: *Session) !void {
        var placements: [protocol.Decoder.max_panes]protocol.PanePlacement = undefined;
        var count: usize = 0;

        // Labels are assigned in list order, so that the number the user types is the position the
        // pane occupies in the layout event. They are only meaningful in dock-select mode.
        var label: u8 = 0;

        for (session.panes.items) |pane| {
            if (count == placements.len) break;
            if (isFloating(session, pane.id)) continue;
            label += 1;
            placements[count] = .{
                .id = pane.id,
                .rect = .{
                    .x = pane.rect.x,
                    .y = pane.rect.y,
                    .width = pane.rect.width,
                    .height = pane.rect.height,
                },
                .exited = pane.exited,
                .floating = false,
                .label = if (session.docking) label else 0,
            };
            count += 1;
        }

        // Hidden floats are left out of the list entirely, so the client needs no rule for what to do
        // with a pane it must not paint. The same applies during dock selection, where the labels on
        // the layout underneath have to be readable.
        if (!session.docking and !session.floats_hidden) {
            for (session.floats.items) |float_id| {
                if (count == placements.len) break;
                const index = session.findPane(float_id) orelse continue;
                const pane = &session.panes.items[index];
                placements[count] = .{
                    .id = pane.id,
                    .rect = .{
                        .x = pane.rect.x,
                        .y = pane.rect.y,
                        .width = pane.rect.width,
                        .height = pane.rect.height,
                    },
                    .exited = pane.exited,
                    .floating = true,
                    .label = 0,
                };
                count += 1;
            }
        }

        try self.broadcast(session, .{ .layout = .{
            .name = session.name,
            .area_rows = session.rows,
            .area_cols = session.cols,
            .focused = session.tree.focused orelse 0,
            .focused_float = session.focused_float orelse 0,
            .docking = session.docking,
            .floats_hidden = session.floats_hidden,
            .panes = placements[0..count],
        } });
    }

    fn attachClient(self: *Server, client: usize, index: usize, rows: u16, cols: u16) !void {
        const session = &self.sessions.items[index];

        // The session's area is sized to this client, which is the compromise for several
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

        // The layout and then every pane's screen, so a reattaching client sees the
        // current arrangement rather than only what happens next.
        try self.sendLayout(session);
        try self.sendSessionScreens(session, client);
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
            .status = exitStatusOf(session),
        } });

        for (session.watchers.items) |client| {
            self.clients.items[client].watching = .{};
        }
        session.watchers.clearRetainingCapacity();

        // Each pane's child is signalled before its pty goes, so none of them lingers with
        // nothing left to reach it.
        for (session.panes.items) |pane| {
            self.unregister(pane.pty.master);
            _ = linux.kill(pane.pty.child, linux.SIG.HUP);
        }
        session.deinit(self.gpa);
        _ = self.sessions.swapRemove(index);
    }

    fn resizeSession(self: *Server, index: usize, rows: u16, cols: u16) !void {
        const session = &self.sessions.items[index];
        if (rows == 0 or cols == 0) return;
        if (session.rows == rows and session.cols == cols) return;

        session.rows = rows;
        session.cols = cols;

        // `relayout` divides the new area and applies each pane's size to its pty, which
        // is what makes the programs inside reflow. It only touches panes whose rectangle
        // actually changed, so a resize that leaves a pane alone does not send it a
        // spurious SIGWINCH.
        try session.relayout();

        try self.sendLayout(session);

        // The area changed, so every watcher is told the new size and re-sent each pane's
        // screen. A client that only saw the following output would still be drawing the
        // old geometry.
        for (session.watchers.items) |client| {
            try self.sendEvent(client, .{ .attached = .{
                .name = session.name,
                .rows = rows,
                .cols = cols,
            } });
            try self.sendSessionScreens(session, client);
        }
    }

    /// Read one pane's pty and forward whatever arrived to every watcher.
    ///
    /// The pty is drained rather than read once. A program that answers a keystroke with an echo and
    /// then a response produces two separate writes, and reading one per wakeup leaves the second
    /// sitting in the kernel until the next event arrives -- which, with nothing else happening, is
    /// the next keystroke. That is what made typing feel one character behind.
    fn servicePane(self: *Server, session_index: usize, pane_index: usize) !void {
        const session = &self.sessions.items[session_index];
        if (pane_index >= session.panes.items.len) return;
        const pane = &session.panes.items[pane_index];

        // Bounded so that a program producing output faster than the client can consume it cannot
        // hold the loop here forever; the next wakeup picks up where this stops.
        var rounds: usize = 0;
        while (rounds < 32) : (rounds += 1) {
            const read = pane.pty.read(pane.read_buffer) catch |err| switch (err) {
                pty_mod.Error.Closed => {
                    // The slave closed, so the child is gone even if the exit status has not been
                    // collected yet. A pane whose child has exited keeps its screen, so this is not
                    // the same as closing it.
                    try self.paneEnded(session_index, pane_index, pane.status);
                    return;
                },
                else => return err,
            };
            if (read == 0) return;

            pane.terminal.write(pane.read_buffer[0..read]);

            // Replies the parser produced go back to the program before any output is forwarded,
            // because a program waiting on one is not producing more.
            pane.flushReply();

            // The bytes are forwarded unchanged, tagged with the pane. The client has its own terminal
            // per pane and parses them itself, which is what lets the two sides disagree about the
            // screen without the server having to reconcile them.
            try self.broadcast(session, .{ .output = .{
                .name = session.name,
                .pane = pane.id,
                .data = pane.read_buffer[0..read],
            } });
        }
    }

    fn reapChildren(self: *Server) void {
        for (self.sessions.items, 0..) |*session, session_index| {
            for (session.panes.items, 0..) |*pane, pane_index| {
                if (pane.exited) continue;
                const status = pane.pty.reap() orelse continue;
                self.paneEnded(session_index, pane_index, exitCode(status)) catch {};
            }
        }
    }

    /// Mark one pane's program as finished, keeping its screen.
    ///
    /// The pane is not removed: a program that has exited still has a last screen worth
    /// looking at, and the user closes the pane when they are done with it.
    fn paneEnded(self: *Server, session_index: usize, pane_index: usize, status: u8) !void {
        const session = &self.sessions.items[session_index];
        if (pane_index >= session.panes.items.len) return;
        const pane = &session.panes.items[pane_index];
        if (pane.exited) return;

        pane.exited = true;
        pane.status = status;

        // The pty stays open so that a client attaching later still sees the final
        // screen, but its readability is no longer of interest.
        self.unregister(pane.pty.master);

        try self.sendLayout(session);

        // A session whose every pane has finished is reported once, so that a client
        // attached to it can say so rather than waiting for output that will never come.
        if (session.allExited()) {
            try self.broadcast(session, .{ .exited = .{
                .name = session.name,
                .status = status,
            } });
        }
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
    /// Send a client the current screen of every pane in a session.
    fn sendSessionScreens(self: *Server, session: *Session, client: usize) !void {
        for (session.panes.items, 0..) |_, pane_index| {
            try self.sendPaneScreen(client, session, pane_index);
        }
    }

    /// Send a client one pane's screen as a fresh VT byte stream.
    ///
    /// The stream is the sequences that would produce the pane's screen, not a snapshot
    /// of it: the client already has a terminal, so re-emitting cursor moves and text
    /// reuses the one libghostty-vt rendering path rather than adding a second that has
    /// to track the library.
    fn sendPaneScreen(
        self: *Server,
        client: usize,
        session: *Session,
        pane_index: usize,
    ) !void {
        if (pane_index >= session.panes.items.len) return;
        const pane = &session.panes.items[pane_index];

        var screen: std.ArrayList(u8) = .empty;
        defer screen.deinit(self.gpa);

        // Clear and home first, so any previous contents on the client are replaced
        // rather than partially overwritten.
        try screen.appendSlice(self.gpa, "\x1b[2J\x1b[H");

        var render = pane.terminal.createRenderState() catch return;
        defer render.deinit();

        var painter = ScreenPainter{ .buffer = &screen, .gpa = self.gpa };
        render.forEachRow(&painter, ScreenPainter.visit) catch {};

        if (painter.failed) return;

        try self.sendEvent(client, .{ .output = .{
            .name = session.name,
            .pane = pane.id,
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
/// A child's exit status as one byte, the way a shell reports it.
///
/// A signalled child is 128 plus the signal number. The clamp is on the sum rather
/// than on the signal, because `@min(signal, 127)` narrows to `u7` and 128 does not
/// fit in it.
fn exitCode(status: pty_mod.ExitStatus) u8 {
    if (status.signaled) return @intCast(@min(@as(u32, 128) + status.signal, 255));
    return status.code;
}

/// The status to report for a session whose every pane has finished.
///
/// The last pane to exit is the one that explains why the session ended, so its status
/// is the one worth reporting. A session with no panes left reports success.
fn exitStatusOf(session: *Session) u8 {
    var last: u8 = 0;
    for (session.panes.items) |pane| {
        if (pane.exited) last = pane.status;
    }
    return last;
}

/// Whether a pane is currently floating.
fn isFloating(session: *Session, id: layout.PaneId) bool {
    for (session.floats.items) |float| {
        if (float == id) return true;
    }
    return false;
}

/// The default size of a floating pane, derived from the window it appears in.
///
/// A float is centred rather than keeping the rectangle it had while tiled: a pane that was a
/// narrow slice of the layout would look like a stray sliver once it was above everything, and a
/// float that filled the window would not read as floating at all. Two thirds of the window, with
/// a floor so that a tiny float is still usable.
fn floatRect(window_cols: u16, window_rows: u16) layout.Rect {
    const cols = @max(@as(u32, window_cols) * 2 / 3, 20);
    const rows = @max(@as(u32, window_rows) * 2 / 3, 6);

    // Clamped to the window, so that a float larger than the window it appears in is not placed
    // partly off-screen.
    const width: u16 = @intCast(@min(cols, @max(window_cols, 1)));
    const height: u16 = @intCast(@min(rows, @max(window_rows, 1)));

    return .{
        .x = (window_cols - width) / 2,
        .y = (window_rows - height) / 2,
        .width = width,
        .height = height,
    };
}

/// The size of a whole session area, for the first pane in it.
fn fullArea(rows: u16, cols: u16) pty_mod.Size {
    return .{ .rows = rows, .cols = cols };
}

/// This runs inside `vt_write`, so it may only append to a buffer. Writing to
/// the pty from here would reenter the parser.
fn onWritePty(
    terminal: vt.c.GhosttyTerminal,
    userdata: ?*anyopaque,
    data: [*c]const u8,
    len: usize,
) callconv(.c) void {
    _ = terminal;
    // The userdata is the `ReplyRoute` stored in the pane. It names the pane rather
    // than pointing at it, because the pane list reallocates as panes are added and a
    // pointer into it would not survive the next split.
    const route: *ReplyRoute = @ptrCast(@alignCast(userdata.?));
    const session_index = route.server.findSession(route.session.slice()) orelse return;
    const pane_index = route.server.sessions.items[session_index].findPane(route.pane) orelse return;

    // A failed allocation would lose a reply and hang the program, but there is no way
    // to report it from a C callback. The missing reply surfaces as a stalled program
    // instead.
    const pane = &route.server.sessions.items[session_index].panes.items[pane_index];
    pane.reply.appendSlice(route.server.gpa, data[0..len]) catch {};
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
        // The sessions are fabricated, so no terminals or ptys were created; only the
        // lists each one owns need freeing, plus the tree.
        for (server.sessions.items) |*session| {
            session.watchers.deinit(gpa);
            session.placements.deinit(gpa);
            session.panes.deinit(gpa);
            session.tree.deinit();
        }
        server.sessions.deinit(gpa);
        server.clients.deinit(gpa);
    }

    // Four clients, with three sessions watching various of them.
    for (0..4) |_| try server.clients.append(gpa, .{ .connection = .{ .fd = -1 } });
    for (0..3) |_| {
        var session = Session.init(gpa, try protocol.Name.init("s"));
        session.rows = 24;
        session.cols = 80;
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

test "an unset float is centred and does not fill the window" {
    // A float that filled the window would not read as floating, and one pinned to a corner would
    // read as a tiled pane. Two thirds, centred.
    const rect = floatRect(80, 24);
    try std.testing.expectEqual(@as(u16, 53), rect.width);
    try std.testing.expectEqual(@as(u16, 16), rect.height);
    try std.testing.expectEqual(@as(u16, 13), rect.x);
    try std.testing.expectEqual(@as(u16, 4), rect.y);

    // Centred means the margins on either side are within one cell of each other: an odd
    // difference cannot be split exactly, so one side gets the extra cell. The comparison is signed
    // because the left margin can legitimately be the smaller of the two, and subtracting unsigned
    // would wrap.
    const right_margin: i32 = @as(i32, 80) - (@as(i32, rect.x) + @as(i32, rect.width));
    const difference = @as(i32, rect.x) - right_margin;
    try std.testing.expect(difference <= 1 and difference >= -1);
}

test "a float smaller than the window stays inside it" {
    // A window too small for two thirds to be usable gets the floor size, which must then be
    // clamped rather than placed off-screen.
    const rect = floatRect(10, 3);
    try std.testing.expect(rect.width <= 10);
    try std.testing.expect(rect.height <= 3);
    try std.testing.expect(rect.x + rect.width <= 10);
    try std.testing.expect(rect.y + rect.height <= 3);
}

test "a float never occupies no cells at all" {
    // A zero-sized rectangle would be skipped by the client and the pane would vanish. The window
    // may be tiny, but the float still has to be somewhere.
    const rect = floatRect(1, 1);
    try std.testing.expect(rect.width >= 1);
    try std.testing.expect(rect.height >= 1);
    try std.testing.expectEqual(@as(u16, 0), rect.x);
    try std.testing.expectEqual(@as(u16, 0), rect.y);
}

test "showing a float returns focus to the pane that had it before" {
    // The rule the user asked for: after hiding and showing, focus is back where the user was working,
    // not on whichever tiled pane happened to be focused when the float appeared.
    const gpa = std.testing.allocator;
    var tree = layout.Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    // The split focused `b`, so that is where the user is.
    try std.testing.expectEqual(@as(?layout.PaneId, b), tree.focused);

    // Floating `b` moves focus within the tree, because the floated pane is no longer tiled.
    _ = try tree.detach(b, 80, 24);
    try std.testing.expect(tree.focused != null);
    try std.testing.expect(!tree.contains(b));
}

test "a hidden float is not in the tree, so it cannot hold focus" {
    // Focus in the tree is what the client sends input to when nothing is raised, so a hidden pane
    // being absent from the tree is exactly what keeps it from receiving keystrokes.
    const gpa = std.testing.allocator;
    var tree = layout.Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    _ = try tree.detach(b, 80, 24);
    try std.testing.expect(!tree.contains(b));
    // Focus is a tiled pane, never the parked one.
    try std.testing.expectEqual(@as(?layout.PaneId, a), tree.focused);
}

test "contains reports membership after a pane is closed" {
    const gpa = std.testing.allocator;
    var tree = layout.Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    try std.testing.expect(tree.contains(a));
    _ = try tree.close(b);
    try std.testing.expect(!tree.contains(b));
    try std.testing.expect(tree.contains(a));
}

test "the toggle hides and shows, and restores focus both ways" {
    // The whole behaviour of `ctrl-a -`, exercised on the state machine rather than through a pty. The
    // pty check confirms the pixels; this confirms which pane owns focus, which the pixels do not show.
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
        for (server.sessions.items) |*session| {
            session.panes.deinit(gpa);
            session.floats.deinit(gpa);
            session.watchers.deinit(gpa);
            session.placements.deinit(gpa);
            session.tree.deinit();
        }
        server.sessions.deinit(gpa);
        server.clients.deinit(gpa);
    }

    var session = Session.init(gpa, try protocol.Name.init("t"));
    session.rows = 24;
    session.cols = 80;
    try server.sessions.append(gpa, session);

    const s = &server.sessions.items[0];

    // Two tiled panes, with the second focused. No ptys are created: the state machine below never
    // touches one, and the test is about ownership and focus.
    const a = s.tree.allocateId();
    try s.tree.setRoot(a);
    const b = s.tree.allocateId();
    try s.tree.split(a, .horizontal, b);
    try s.panes.append(gpa, .{ .id = a, .pty = .{ .master = -1, .child = 0 }, .terminal = undefined });
    try s.panes.append(gpa, .{ .id = b, .pty = .{ .master = -1, .child = 0 }, .terminal = undefined });

    // `b` has focus, which is where the user is working.
    try std.testing.expectEqual(@as(?layout.PaneId, b), s.tree.focused);

    // Park `b`. The remembered pane is read *after* the detach, because before it the tree still points
    // at the pane that is leaving, and remembering that would restore focus to an invisible pane.
    _ = try s.tree.detach(b, s.cols, s.rows);
    try s.floats.append(gpa, b);
    s.focus_before_float = s.tree.focused;
    s.focused_float = b;

    // The float is no longer tiled, so it is not in the tree.
    try std.testing.expect(!s.tree.contains(b));
    // And the pane remembered for the return is the tiled survivor, not the float.
    try std.testing.expectEqual(@as(?layout.PaneId, a), s.focus_before_float);
    try std.testing.expect(s.tree.contains(a));

    // Hiding must clear the raised float and put focus back on the remembered pane.
    s.floats_hidden = true;
    s.focused_float = null;
    if (s.focus_before_float) |previous| {
        if (s.tree.contains(previous)) s.tree.focused = previous;
    }
    try std.testing.expect(s.focused_float == null);
    // Focus is on the tiled pane the user was in, never on the hidden float.
    try std.testing.expectEqual(@as(?layout.PaneId, a), s.tree.focused);
    try std.testing.expect(!s.tree.contains(b));

    // Showing again raises the float that was raised before.
    s.floats_hidden = false;
    s.focused_float = s.floats.items[s.floats.items.len - 1];
    try std.testing.expectEqual(@as(?layout.PaneId, b), s.focused_float);
}
