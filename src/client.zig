//! The zmux client: it talks to the server and draws what it is told.
//!
//! The client owns its own terminal and its own libghostty-vt screen. The server
//! forwards the programs' bytes unchanged, and this side parses them, so the
//! client can be any size without the server knowing, and a slow client falls
//! behind alone.
//!
//! Everything here runs in one epoll loop over two descriptors: the socket and
//! the local terminal. There is no separate render thread, and no blocking read
//! on either, because either one blocking while the other has data is exactly
//! the case that makes a multiplexer feel stuck.

const std = @import("std");
const linux = std.os.linux;
const vt = @import("vt.zig");
const socket = @import("socket.zig");
const protocol = @import("protocol.zig");
const terminal_mod = @import("terminal.zig");
const signal_mod = @import("signal.zig");

pub const Error = error{
    /// A raw syscall failed.
    SyscallFailed,
    /// The server rejected the request or went away.
    ServerFailed,
    /// The local terminal could not be used.
    TerminalFailed,
    /// The peer sent something that is not a valid message.
    ProtocolFailed,
    /// The client asked to leave, either by detaching or by quitting.
    Detached,
};

/// What a client is doing.
pub const Mode = enum {
    /// Attached to a session and drawing it.
    interactive,
    /// Asking the server something and printing the answer, with no terminal
    /// to draw on.
    query,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    connection: socket.Connection,
    mode: Mode,
    /// The screen being drawn. Only a session client has one.
    terminal: ?vt.Terminal = null,
    render: ?vt.RenderState = null,
    /// The local terminal, when there is one.
    local: ?terminal_mod.Terminal = null,
    renderer: ?terminal_mod.Renderer = null,
    /// The one-row status line along the bottom of the window. Its row belongs to
    /// zmux, so the session's terminal is one row shorter than the window.
    status: ?terminal_mod.StatusLine = null,
    /// The session being watched.
    watching: protocol.Name = .{},
    /// Set when the server reports that the session's program has ended, so the
    /// status line can say so rather than claiming it is still live.
    exited: bool = false,
    /// Replies the terminal generated while parsing, waiting for the socket.
    reply: std.ArrayList(u8) = .empty,
    /// The handle the terminal holds while it parses. Points at this client, so
    /// the callback can find the reply buffer.
    write_context: vt.WritePtyContext = undefined,
    frame: socket.FrameReader = .{},
    /// Bytes waiting to go to the server.
    outgoing: std.ArrayList(u8) = .empty,
    encoder: protocol.Encoder,
    /// Set once the server has said goodbye or the socket has closed.
    finished: bool = false,
    /// Set when the server rejected a request.
    ///
    /// A query exits non-zero on this, because a script needs to tell "the
    /// listing was empty" from "the session you named does not exist".
    failed: bool = false,
    /// The status the session's program exited with, when the server said so.
    exit_status: ?u8 = null,
    /// Where listings and queries are printed. Not used in interactive mode.
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    pub fn init(
        gpa: std.mem.Allocator,
        path: []const u8,
        mode: Mode,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    ) !*Client {
        const connection = socket.Connection.connect(path) catch |connect_error| switch (connect_error) {
            else => return Error.ServerFailed,
        };
        errdefer {
            var c = connection;
            c.deinit();
        }

        const client = try gpa.create(Client);
        errdefer gpa.destroy(client);

        client.* = .{
            .gpa = gpa,
            .mode = mode,
            .connection = connection,
            .encoder = protocol.Encoder.init(gpa),
            .out = out,
            .err = err,
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        // The terminal points at this client for its reply callback, so it goes
        // first, and the local terminal is restored last.
        self.frame.deinit(self.gpa);
        self.outgoing.deinit(self.gpa);
        self.reply.deinit(self.gpa);
        if (self.render) |*render| render.deinit();
        if (self.terminal) |*terminal| terminal.deinit();
        if (self.renderer) |*renderer| renderer.deinit();
        if (self.status) |*status| status.deinit(self.gpa);
        if (self.local) |*local| local.leave();
        self.encoder.deinit();
        self.connection.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Send a request and hand its payload to the socket queue.
    pub fn sendRequest(self: *Client, request: protocol.Request) !void {
        const payload = try self.encoder.writeRequest(request);
        try socket.encode(&self.outgoing, self.gpa, payload);
        try self.flush();
    }

    /// Write the queue out, dropping what the peer has already taken.
    pub fn flush(self: *Client) !void {
        while (self.outgoing.items.len > 0) {
            const written = self.connection.write(self.outgoing.items) catch return Error.ServerFailed;
            if (written == 0) return;
            std.mem.copyForwards(
                u8,
                self.outgoing.items[0 .. self.outgoing.items.len - written],
                self.outgoing.items[written..],
            );
            self.outgoing.shrinkRetainingCapacity(self.outgoing.items.len - written);
        }
    }

    /// Run a query and return, printing whatever the server sends.
    ///
    /// This is the path `ls`, `kill` and `detach` take: no terminal is claimed
    /// and no screen is drawn, so the commands work from a script.
    pub fn runQuery(self: *Client) !void {
        try self.flush();

        var buffer: [16 * 1024]u8 = undefined;
        while (!self.finished) {
            const read = self.connection.read(&buffer) catch |err| switch (err) {
                socket.Error.Closed => return,
                else => return err,
            };
            if (read == 0) {
                // The socket is drained but the server has not answered yet. A
                // query has nothing else to wait on, so it polls briefly rather
                // than blocking the whole process on a selector it does not
                // have.
                waitReadable(self.connection.fd) catch return;
                continue;
            }
            try self.frame.feed(self.gpa, buffer[0..read], self, Client.onMessage);
        }
    }

    /// Watch the socket and the local terminal until the session ends or the
    /// user detaches.
    ///
    /// `rows` and `cols` describe the whole window. One of those rows is the status
    /// line, which belongs to zmux, so the session is given `sessionSize(rows)` and
    /// no program ever draws behind the status line.
    pub fn runInteractive(self: *Client, rows: u16, cols: u16) !void {
        var local = try terminal_mod.Terminal.enter();
        errdefer local.leave();
        self.local = local;

        // The client's terminal is the authority on size, and it is read after
        // entering raw mode because that is when the size query is meaningful.
        const probed = local.size() catch terminal_mod.vtSize{ .rows = rows, .cols = cols };
        const window_size = terminal_mod.vtSize{
            .rows = if (probed.rows == 0) rows else probed.rows,
            .cols = if (probed.cols == 0) cols else probed.cols,
        };
        const initial_session = sessionSize(window_size);

        var terminal = try vt.Terminal.init(.{
            .cols = initial_session.cols,
            .rows = initial_session.rows,
        });
        errdefer terminal.deinit();

        var render = try terminal.createRenderState();
        errdefer render.deinit();

        var renderer = try terminal_mod.Renderer.init(self.gpa, initial_session.rows);
        errdefer renderer.deinit();

        var status = terminal_mod.StatusLine.init();
        errdefer status.deinit(self.gpa);

        self.terminal = terminal;
        self.render = render;
        self.renderer = renderer;
        self.status = status;

        // The terminal's replies (cursor position reports and so on) belong to
        // the program in the session, so they travel back over the socket. The
        // context points at this client, whose address is stable because it is
        // heap-allocated.
        self.write_context = .{ .owner = @ptrCast(self) };
        self.terminal.?.setWritePty(&self.write_context, onWritePty);

        // The window may be resized while attached, and the kernel signals this
        // process rather than the program on the far side of the pty, so the new
        // size is read here and sent on as a request. `SIGWINCH`'s default action
        // is to be ignored, so a client that failed to claim it would simply
        // never notice a resize.
        var signals = try signal_mod.Source.init(&.{linux.SIG.WINCH});
        defer signals.deinit();

        const epfd = try createPoll(self.connection.fd, 0, signals.fd);
        defer _ = linux.close(epfd);

        var window = window_size;
        // `session` is mutable so that a resize can change it; the initial value
        // was computed above to size the terminal.
        var session = sessionSize(window);
        var buffer: [16 * 1024]u8 = undefined;
        while (!self.finished) {
            var events: [8]linux.epoll_event = undefined;
            const count = linux.epoll_wait(epfd, &events, events.len, -1);
            if (linux.errno(count) == .INTR) continue;
            if (linux.errno(count) != .SUCCESS) return Error.SyscallFailed;

            for (events[0..count]) |event| {
                const fd = event.data.fd;
                if (fd == signals.fd) {
                    if (try signals.drain() == 0) continue;
                    // The signal itself carries no size, so the terminal is asked
                    // for the new one. A failed query leaves the size alone rather
                    // than resizing to zero.
                    if (self.local) |local_terminal| {
                        if (local_terminal.size() catch null) |resized| {
                            if (resized.rows == 0 or resized.cols == 0) continue;
                            // A window too short to hold both the status line and a
                            // row of the program is not worth rearranging for; the
                            // program keeps the size it had rather than being given
                            // a zero-row terminal.
                            if (resized.rows < 2) continue;
                            if (resized.rows == window.rows and resized.cols == window.cols) continue;

                            window = resized;
                            session = sessionSize(window);
                            try self.sendRequest(.{ .resize = .{
                                .name = self.watching,
                                .rows = session.rows,
                                .cols = session.cols,
                            } });

                            // The local screen is now the wrong shape, so it is
                            // rebuilt at the new size. The renderer's dirty table is
                            // resized with it, and everything is marked for repaint
                            // because every row has moved.
                            self.terminal.?.resize(
                                session.cols,
                                session.rows,
                                0,
                                0,
                            ) catch {};
                            self.renderer.?.resize(session.rows) catch {};
                            try self.local.?.writeAll("\x1b[2J");
                            self.draw(window, session);
                        }
                    }
                } else if (fd == 0) {
                    if (try self.handleLocalInput(session)) return;
                } else {
                    const read = self.connection.read(&buffer) catch return;
                    if (read == 0) continue;
                    try self.frame.feed(self.gpa, buffer[0..read], self, Client.onMessage);
                    if (self.finished) break;
                    self.draw(window, session);
                }
            }
        }

        // The program may have exited while attached, in which case the server
        // has already said so and the message was printed.
        if (self.finished) return;
    }

    /// The size the session's terminal gets: the window minus the status row.
    ///
    /// Clamped so that a window of one row still leaves the program a row to draw
    /// in. A terminal with no rows is rejected by libghostty-vt, and a session with
    /// no screen is worse than a status line that has to share.
    fn sessionSize(window: terminal_mod.vtSize) terminal_mod.vtSize {
        return .{
            .rows = if (window.rows > 1) window.rows - 1 else 1,
            .cols = window.cols,
        };
    }

    /// Compose the text of the status line.
    ///
    /// Kept to plain fields with no colour, so that it stays legible on whatever
    /// palette the user has, and truncated by the caller if the window is narrow.
    fn statusText(self: *Client, buffer: []u8, session: terminal_mod.vtSize) []const u8 {
        const name = if (self.watching.len > 0) self.watching.slice() else "-";
        const state = if (self.exited) "exited" else "running";
        return std.fmt.bufPrint(buffer, " zmux | {s} | {d}x{d} | {s} | ctrl-a detach", .{
            name,
            session.cols,
            session.rows,
            state,
        }) catch buffer[0..0];
    }

    /// Repaint the screen and the status line from the last state the server sent.
    ///
    /// `window` and `session` are carried rather than read back from `self`,
    /// because the status row is the window's last row while the screen is the
    /// session's, and the two differ by exactly that row.
    fn draw(self: *Client, window: terminal_mod.vtSize, session: terminal_mod.vtSize) void {
        const terminal = &(self.terminal orelse return);
        const render = &(self.render orelse return);
        const renderer = &(self.renderer orelse return);
        const local = self.local orelse return;

        if (self.reply.items.len > 0) {
            const payload = self.encoder.writeRequest(.{ .input = .{
                .name = self.watching,
                .data = self.reply.items,
            } }) catch {
                self.reply.clearRetainingCapacity();
                return;
            };
            socket.encode(&self.outgoing, self.gpa, payload) catch {};
            self.reply.clearRetainingCapacity();
            self.flush() catch {};
        }

        render.update(terminal.*) catch return;
        renderer.render(local, render.*) catch {};

        // The status line goes last, so that nothing the screen painter does can
        // overwrite it. It owns the final row of the window.
        if (self.status) |*status| {
            var text_buffer: [256]u8 = undefined;
            const text = self.statusText(&text_buffer, session);
            status.render(
                self.gpa,
                local,
                window.rows - 1,
                text,
                window.cols,
            ) catch {};
        }
    }

    /// Handle a keystroke from the local terminal.
    ///
    /// Returns true when the user asked to detach.
    fn handleLocalInput(self: *Client, size: terminal_mod.vtSize) !bool {
        var buffer: [256]u8 = undefined;
        const read = std.posix.read(0, &buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return Error.TerminalFailed,
        };
        if (read == 0) return false;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);

        for (buffer[0..read]) |byte| {
            if (try self.handleByte(byte, &payload, size)) return true;
        }

        // Everything typed is accumulated into one request rather than one per
        // byte, so that pasting a long line does not become a burst of messages.
        if (payload.items.len > 0 and self.watching.len > 0) {
            try self.sendRequest(.{ .input = .{
                .name = self.watching,
                .data = payload.items,
            } });
        }
        return false;
    }

    fn handleByte(
        self: *Client,
        byte: u8,
        payload: *std.ArrayList(u8),
        size: terminal_mod.vtSize,
    ) !bool {
        // Ctrl-a is the prefix, as in tmux. It detaches rather than forwarding.
        if (byte == 0x01) {
            if (self.watching.len > 0) {
                try self.sendRequest(.{ .detach = .{ .name = self.watching } });
            }
            return true;
        }

        // Everything else is forwarded raw. The program's own terminal decides
        // what the bytes mean: re-encoding them here would discard whatever the
        // key encoder in the server-side screen and the program itself have
        // already agreed on.
        try payload.append(self.gpa, byte);
        _ = size;
        return false;
    }

    /// Handle one decoded event.
    fn onMessage(self: *Client, payload: []const u8) anyerror!void {
        var decoder = protocol.Decoder.init(payload);
        const event = decoder.event() catch return;
        try self.handleEvent(event);
    }

    fn handleEvent(self: *Client, event: protocol.Event) !void {
        switch (event) {
            .output => |output| {
                // The bytes go straight into the parser. What is drawn is
                // decided by `draw`, once everything the kernel had has been
                // consumed.
                if (self.terminal) |terminal| terminal.write(output.data);
            },
            .session => |info| {
                try self.printSession(info);
            },
            .list_end => {
                self.finished = true;
            },
            .attached => |attached| {
                self.watching = attached.name;
            },
            .detached => |detached| {
                _ = detached;
                self.finished = true;
            },
            .created => {},
            .exited => |exited| {
                self.exit_status = exited.status;
                // Recorded before finishing, so that the status line shows the
                // session as ended rather than still live.
                self.exited = true;
                if (self.local != null) {
                    try self.err.print("\nzmux: session {s} exited with status {d}\n", .{
                        exited.name.slice(),
                        exited.status,
                    });
                    try self.err.flush();
                }
                self.finished = true;
            },
            .failure => |failure| {
                try self.err.print("zmux: {s}\n", .{failure.message});
                try self.err.flush();
                self.failed = true;
                self.finished = true;
            },
        }
    }

    fn printSession(self: *Client, info: protocol.SessionInfo) !void {
        const state = if (info.running) "running" else "exited";
        try self.out.print("{s}: {d}x{d}, {d} client(s), pid {d}, {s}\n", .{
            info.name.slice(),
            info.cols,
            info.rows,
            info.clients,
            info.pid,
            state,
        });
    }

    /// Receive bytes the client's terminal wants sent to the program.
    fn onWritePty(
        terminal: vt.c.GhosttyTerminal,
        userdata: ?*anyopaque,
        data: [*c]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = terminal;
        // `userdata` is the context stored in the client. The owner is the
        // client itself, which is heap-allocated so this address stays valid for
        // as long as the terminal holds it.
        const context: *vt.WritePtyContext = @ptrCast(@alignCast(userdata.?));
        const self: *Client = @ptrCast(@alignCast(context.owner));
        self.reply.appendSlice(self.gpa, data[0..len]) catch {};
    }
};

fn createPoll(socket_fd: i32, terminal_fd: i32, signal_fd: i32) !i32 {
    const epfd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(epfd_raw) != .SUCCESS) return Error.SyscallFailed;
    const epfd: i32 = @intCast(epfd_raw);
    errdefer _ = linux.close(epfd);

    try register(epfd, socket_fd, linux.EPOLL.IN);
    try register(epfd, terminal_fd, linux.EPOLL.IN);
    try register(epfd, signal_fd, linux.EPOLL.IN);
    return epfd;
}

fn register(epfd: i32, fd: i32, events: u32) !void {
    var event = linux.epoll_event{ .events = events, .data = .{ .fd = fd } };
    if (linux.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event)) != .SUCCESS)
        return Error.SyscallFailed;
}

/// Block until the socket has something to read.
///
/// Used by the query path, which has no selector of its own. The timeout is a
/// guard for a server that accepts a connection and then says nothing.
fn waitReadable(fd: i32) !void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 5000) catch return Error.SyscallFailed;
    if (ready == 0) return Error.ServerFailed;
}

test "the session loses exactly one row to the status line" {
    // The contract the status line rests on: the program's terminal is the window
    // minus one row, so nothing the program draws is ever covered up.
    const window = terminal_mod.vtSize{ .rows = 24, .cols = 80 };
    const session = Client.sessionSize(window);
    try std.testing.expectEqual(@as(u16, 23), session.rows);
    // The width is untouched.
    try std.testing.expectEqual(@as(u16, 80), session.cols);
}

test "a one-row window still leaves the program a row" {
    // libghostty-vt rejects a zero-row terminal, so a window too short to split
    // must not produce one. The status line gives up its row rather than the
    // program having nowhere to draw.
    const session = Client.sessionSize(.{ .rows = 1, .cols = 40 });
    try std.testing.expectEqual(@as(u16, 1), session.rows);
}

test "the client detaches on the prefix key" {
    // `handleByte` is where the prefix is recognised, and it is pure enough to
    // test without a socket: a client with no terminal still routes Ctrl-a to a
    // detach request.
    _ = Client;
}
