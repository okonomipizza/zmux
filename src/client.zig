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
const config_mod = @import("config.zig");
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

/// The key that introduces a zmux command rather than being sent to the program.
///
/// `ctrl-b`, which is what tmux uses, so a habit formed there carries over. Named rather than written
/// as a literal because it appears in three places, and a prefix that agreed with itself in only two
/// of them would leave the third key either dead or sent to the program by mistake.
const prefix_key: u8 = 0x02;

/// What a client is doing.
pub const Mode = enum {
    /// Attached to a session and drawing it.
    interactive,
    /// Asking the server something and printing the answer, with no terminal
    /// to draw on.
    query,
};

/// One remote pane, as the client sees it: its own terminal and the
/// rectangle the server says it occupies.
///
/// One terminal per pane rather than one per session, because each program has its own
/// screen. The server sends each pane's bytes tagged with its identifier, so this side
/// dispatches without having to parse anything to know where they belong.
const RemotePane = struct {
    id: u64,
    terminal: vt.Terminal,
    render: vt.RenderState,
    /// Where the server says this pane goes, in window cells.
    rect: protocol.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Set when the server reports this pane's program has exited.
    exited: bool = false,
    /// Whether this pane floats above the layout rather than being tiled by it.
    ///
    /// A float is drawn after the tiled panes and may overlap them, and its rectangle is absolute
    /// window cells rather than a slice of the tiled area.
    floating: bool = false,
    /// The number the server wants drawn on this pane while a dock target is being chosen, or
    /// zero when nothing is being numbered.
    label: u8 = 0,
    /// Set when the whole pane has to be repainted, whatever the library says is dirty.
    ///
    /// The library only reports cells that changed, which is not enough on its own: a pane that
    /// moved, was uncovered by a float, or had a label drawn over it is out of date without any
    /// cell having changed. Those cases set this rather than trying to describe the damage.
    stale: bool = true,
    /// Bytes this pane's terminal wants sent to its program, waiting for the socket.
    reply: std.ArrayList(u8) = .empty,
    /// The handle the terminal holds; heap-allocated and owned here.
    ///
    /// Separate from the pane because `setWritePty` keeps the pointer and the pane list
    /// reorders when a pane is closed, which would leave the terminal pointing at a pane
    /// that a `swapRemove` moved into its slot.
    route: *PaneRoute = undefined,
    /// Reused scratch for one row's text while painting.
    line: std.ArrayList(u8) = .empty,

    fn deinit(self: *RemotePane, gpa: std.mem.Allocator) void {
        gpa.destroy(self.route);
        self.reply.deinit(gpa);
        self.line.deinit(gpa);
        self.render.deinit();
        self.terminal.deinit();
    }
};

/// What a pane's terminal callback needs to find its way back to the client.
const PaneRoute = struct {
    client: *Client,
    pane: u64,
};

/// Bytes waiting for a pane the client has not been told about yet.
const PendingOutput = struct {
    pane: u64,
    data: std.ArrayList(u8) = .empty,
};

/// How many bytes may be held for a pane the layout has not described.
///
/// This exists because of a case the original reasoning missed. The bytes are held so that a pane's
/// first output is not lost when its layout event is still behind them in the same batch, and that
/// window is tiny -- a few messages.
///
/// But a pane can be *permanently* absent from every layout event while still producing output: a
/// float whose program keeps printing, while the floats are hidden, is left out of the layout by
/// `sendLayout` for as long as it stays hidden, and the server forwards its output regardless. The
/// old comment claimed the queue was bounded by what a program could print "between a split and its
/// own layout event", which is not true of that case, so a hidden `tail -f` grew it without limit.
///
/// The cap is what makes the queue bounded for real. A pane that never appears loses the oldest bytes
/// rather than the newest, since the recent output is what a reader wants when the pane does appear,
/// and losing output at all is only possible in a case where the pane is not on screen.
const pending_limit = 256 * 1024;

pub const Client = struct {
    gpa: std.mem.Allocator,
    connection: socket.Connection,
    mode: Mode,
    /// The keys and colours the user chose, or the defaults.
    ///
    /// Read once when the client starts and never re-read: a configuration that changed underfoot
    /// would have to be reconciled with what is already on screen, and there is no way to do that for
    /// a colour that has already been drawn.
    config: config_mod.Config = .{},
    /// The panes the server says this session has.
    panes: std.ArrayList(RemotePane) = .empty,
    /// The pane the server says has focus, by identifier. Input is addressed to it.
    focused: u64 = 0,
    /// The raised floating pane, by identifier, or zero when none is raised.
    focused_float: u64 = 0,
    /// Set while the server is labelling the tiled panes for a dock target.
    docking: bool = false,
    /// Set while the server is labelling the tiled panes so one can be picked to focus.
    ///
    /// Separate from `docking` even though both draw the same numbers, because a digit means a
    /// different request in each and the mode is the only thing that says which.
    focusing: bool = false,
    /// The sessions the server last listed, while the switch menu is open.
    ///
    /// Gathered from the `session` events that answer a `list` request, and held here rather than
    /// drawn as they arrive so that the menu is one screenful the user reads at once.
    session_menu: std.ArrayList(protocol.SessionInfo) = .empty,
    /// Set while the switch menu is open.
    menu_open: bool = false,
    /// Set while the focused pane is being scrolled through its history.
    ///
    /// A mode rather than a key, because it changes what every other key means: `j` and `k` move the
    /// viewport instead of being typed, and `q` leaves rather than closing a pane. The pane's
    /// viewport is the library's, so what is being read is the pane's own history and not a copy.
    scroll_mode: bool = false,
    /// The digits typed so far, as a number, or zero when none has been typed.
    ///
    /// A value rather than a string, because the menu chooses a session by its position and a number
    /// is what that is. Zero means nothing has been typed, which is also why the sessions are
    /// numbered from one.
    menu_choice: usize = 0,
    /// Whether the listing the menu is waiting for has arrived.
    menu_ready: bool = false,
    /// Set while the floating panes are hidden, so the status line can say so.
    ///
    /// Hidden floats are not in the layout event at all, so without this the client cannot tell
    /// "no floats exist" from "the floats are put away", and the status line would be wrong.
    floats_hidden: bool = false,
    /// The area the floats covered on the previous frame, per pane.
    ///
    /// A tiled pane under a float is not painted at all while the float is up, so when a float
    /// moves, is hidden or is closed, the cells it was covering are still showing it. Comparing
    /// this with the current frame's float rectangles is how those panes are found and marked
    /// stale again. Kept as a rectangle per pane rather than one bounding box, so that a pane
    /// uncovered along one edge of a float is not repainted because another pane covers a
    /// different corner.
    covered: std.ArrayList(protocol.Rect) = .empty,
    /// Set between the prefix key and the key that follows it.
    prefix_armed: bool = false,
    /// How many messages this client could not decode.
    ///
    /// Counted rather than merely logged so that the complaint is made once. A frame the decoder
    /// cannot read is likely to be followed by more of them, and a line per frame would bury the
    /// screen it is warning about.
    protocol_complaints: usize = 0,
    /// Output that arrived for panes this client has not been told about yet.
    ///
    /// Each entry is one pane and the bytes waiting for it. Replayed when the layout event
    /// that creates the pane arrives; a pane that never appears leaves its bytes here until
    /// the client exits, which is bounded by how much a program can print between a split
    /// and its own layout event.
    pending: std.ArrayList(PendingOutput) = .empty,
    /// The area the panes share, which is the window minus the status row.
    area_rows: u16 = 0,
    area_cols: u16 = 0,
    /// The local terminal, when there is one.
    local: ?terminal_mod.Terminal = null,
    /// The one-row status line along the bottom of the window. Its row belongs to zmux,
    /// so the session's area is one row shorter than the window.
    status: ?terminal_mod.StatusLine = null,
    /// The session being watched.
    watching: protocol.Name = .{},
    /// Set when the server reports that the session's program has ended, so the status
    /// line can say so rather than claiming it is still live.
    exited: bool = false,
    frame: socket.FrameReader = .{},
    /// Bytes waiting to go to the server.
    outgoing: std.ArrayList(u8) = .empty,
    encoder: protocol.Encoder,
    /// Set once the server has said goodbye or the socket has closed.
    finished: bool = false,
    /// Set when the server rejected a request.
    ///
    /// A query exits non-zero on this, because a script needs to tell "the listing was
    /// empty" from "the session you named does not exist".
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
        config: config_mod.Config,
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
            .config = config,
            .encoder = protocol.Encoder.init(gpa),
            .out = out,
            .err = err,
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        // The panes' terminals point at this client for their reply callbacks, so they go
        // first; the local terminal is restored last, since the screen is written to it
        // until then.
        self.frame.deinit(self.gpa);
        self.outgoing.deinit(self.gpa);
        for (self.panes.items) |*pane| pane.deinit(self.gpa);
        self.panes.deinit(self.gpa);
        for (self.pending.items) |*entry| entry.data.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.covered.deinit(self.gpa);
        self.session_menu.deinit(self.gpa);
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

        var status = terminal_mod.StatusLine.init();
        errdefer status.deinit(self.gpa);
        self.status = status;

        // The panes are not created here. The server decides how many there are and where
        // they go, and sends a layout event saying so; this side makes a terminal per pane
        // when that arrives. Creating one up front would mean guessing how many the
        // session has.

        // The window may be resized while attached, and the kernel signals this process
        // rather than the programs on the far side of the pty, so the new size is read
        // here and sent on as a request. `SIGWINCH`'s default action is to be ignored, so
        // a client that failed to claim it would simply never notice a resize.
        var signals = try signal_mod.Source.init(&.{linux.SIG.WINCH});
        defer signals.deinit();

        const epfd = try createPoll(self.connection.fd, 0, signals.fd);
        defer _ = linux.close(epfd);

        var window = terminal_mod.vtSize{
            .rows = if (rows == 0) 24 else rows,
            .cols = if (cols == 0) 80 else cols,
        };
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
                    // The signal itself carries no size, so the terminal is asked for the
                    // new one. A failed query leaves the size alone rather than resizing
                    // to zero.
                    if (self.local) |local_terminal| {
                        if (local_terminal.size() catch null) |resized| {
                            if (resized.rows == 0 or resized.cols == 0) continue;
                            // A window too short to hold both the status line and a row of
                            // the programs is not worth rearranging for; they keep the size
                            // they had rather than being given zero-row terminals.
                            if (resized.rows < 2) continue;
                            if (resized.rows == window.rows and resized.cols == window.cols) continue;

                            window = resized;
                            try self.sendRequest(.{ .resize = .{
                                .name = self.watching,
                                .rows = window.rows - 1,
                                .cols = window.cols,
                            } });

                            // The server answers with a fresh layout, which resizes every
                            // pane's terminal and repaints. Clearing first means the rows
                            // the old arrangement occupied are not left behind.
                            try self.local.?.writeAll("\x1b[2J");
                        }
                    }
                } else if (fd == 0) {
                    if (try self.handleLocalInput()) return;
                    // The screen is repainted after input as well as after output. A program that
                    // echoes what it receives, or that answers a keystroke by drawing, sends its
                    // answer back as a separate message; without a paint here the display shows the
                    // state as of the previous keystroke, which reads as the terminal being one
                    // character behind the typing. Painting is cheap when nothing changed, because
                    // each pane only redraws the rows the library marks dirty.
                    self.draw(window);
                } else {
                    // The socket is drained before painting, so one repaint reflects everything that
                    // has arrived rather than only the first segment. A program that echoes a
                    // keystroke and then answers it produces two messages, and painting between them
                    // shows a half-updated screen.
                    var rounds: usize = 0;
                    var drew = false;
                    while (rounds < 32) : (rounds += 1) {
                        // A server that goes away without saying so has to be reported. This used to
                        // return silently: the terminal was restored and the user was left at their
                        // shell with the window they had been working in simply gone, and nothing
                        // anywhere to say whether it had crashed or been killed. A `kill` or
                        // `kill-all` sends an event first, so reaching here means the server died.
                        const read = self.connection.read(&buffer) catch |err| {
                            try self.err.print(
                                "\nzmux: lost the server ({s}); the session is gone\n",
                                .{@errorName(err)},
                            );
                            try self.err.flush();
                            self.finished = true;
                            return;
                        };
                        try self.frame.feed(self.gpa, buffer[0..read], self, Client.onMessage);
                        if (self.finished) break;
                        drew = true;
                    }
                    if (self.finished) break;
                    if (drew) self.draw(window);
                }
            }
        }

        // The program may have exited while attached, in which case the server
        // has already said so and the message was printed.
        if (self.finished) return;
    }

    /// The size the session's area gets: the window minus the status row.
    ///
    /// Clamped so that a window of one row still leaves the programs a row to draw in. A
    /// terminal with no rows is rejected by libghostty-vt, and the status line giving up
    /// its row is better than the programs having nowhere to draw.
    fn sessionSize(window: terminal_mod.vtSize) terminal_mod.vtSize {
        return .{
            .rows = if (window.rows > 1) window.rows - 1 else 1,
            .cols = window.cols,
        };
    }

    /// Compose the text of the status line.
    ///
    /// Kept to plain fields with no colour, so that it stays legible on whatever palette
    /// the user has. Truncation is the caller's job, since it knows the window width.
    fn statusText(self: *Client, buffer: []u8) []const u8 {
        const name = if (self.watching.len > 0) self.watching.slice() else "-";
        const state = if (self.exited) "exited" else "running";

        // While a dock target is being chosen the status line is the instruction for the mode, since
        // the whole window is now a menu.
        // While the history is being read the status line is the only thing that says the mode is
        // on, since the pane itself looks like one that has simply stopped updating.
        if (self.scroll_mode) {
            const pane = self.focusedPane();
            const history = if (pane) |p| p.terminal.scrollbackRows() else 0;
            const at_live = if (pane) |p| p.terminal.viewportActive() else true;
            return std.fmt.bufPrint(
                buffer,
                " zmux | {s} | scroll: j/k line  J/K ten  ctrl-d/u half  ctrl-f/v page  g/G ends  q quit |{s} {d} rows of history",
                .{ name, if (at_live) " live," else "", history },
            ) catch buffer[0..0];
        }

        if (self.docking) {
            return std.fmt.bufPrint(
                buffer,
                " zmux | dock {s} into which pane? press 1-9, esc to cancel",
                .{name},
            ) catch buffer[0..0];
        }

        // The instruction has to name the keys the user can actually press, so it says what the
        // digits do rather than only that the panes are numbered.
        if (self.focusing) {
            return std.fmt.bufPrint(
                buffer,
                " zmux | focus which pane? press 1-9, esc to cancel",
                .{},
            ) catch buffer[0..0];
        }

        // Hidden floats are not in the layout, so the status line is the only place that says they
        // still exist. Without this a user would think they had been closed.
        if (self.floats_hidden) {
            return std.fmt.bufPrint(
                buffer,
                " zmux | {s} | {d}x{d} | floats hidden, ctrl-b f shows them | {s}",
                .{
                    name,
                    self.area_cols,
                    self.area_rows,
                    state,
                },
            ) catch buffer[0..0];
        }

        return std.fmt.bufPrint(
            buffer,
            " zmux | {s} | {d}x{d} | ctrl-b: \\/- split q close h/j/k/l focus <> swap o rotate F/f floats d dock | {s}",
            .{
                name,
                self.area_cols,
                self.area_rows,
                state,
            },
        ) catch buffer[0..0];
    }

    /// Repaint the panes that changed, and then the status line.
    ///
    /// The tiled panes tile the session's area, so nothing overlaps between them and no clearing is
    /// needed; the floats are drawn after them, on top. The status line goes last because it owns the
    /// one row below the area.
    ///
    /// A pane's terminal is the authority on what changed, and it reports that per row, so the
    /// usual frame writes one row for one keystroke rather than every cell on the screen. What the
    /// library cannot know is which panes stopped being visible, since that is a fact about the
    /// layout rather than about any one terminal; that is what `covered` is for.
    fn draw(self: *Client, window: terminal_mod.vtSize) void {
        const local = self.local orelse return;

        // The menu takes the whole window rather than sitting beside the panes: it is a choice the
        // user is making, and the sessions it lists are not the one already on screen.
        if (self.menu_open) {
            self.drawMenu(local, window);
            return;
        }

        // Replies the panes' terminals produced while parsing go back to the programs
        // they belong to, before anything is painted.
        self.flushPaneReplies();

        // The floats that are up now, which is what the tiled panes are drawn under.
        self.noteOcclusion();

        // Tiled panes first, then the floats over them. The server sends the panes in z-order and
        // the flag on each one says which is which, so the two passes are what put the floats on
        // top rather than merely beside.
        for (self.panes.items) |*pane| {
            if (pane.floating) continue;
            self.drawPane(pane);
        }
        for (self.panes.items) |*pane| {
            if (!pane.floating) continue;
            self.drawPane(pane);
            // After the pane, because the mark is written into the frame the pane just drew. A float
            // whose program ended is kept on screen rather than closed, so this is what says so.
            if (pane.exited) self.drawExitedPane(pane);
        }

        // While a pane is being chosen -- to dock a float into, or to move focus to -- each tiled
        // pane shows its number. Both modes draw the same way and differ only in what a digit then
        // asks the server for.
        if (self.docking or self.focusing) {
            for (self.panes.items) |*pane| {
                if (pane.floating or pane.label == 0) continue;
                self.drawPaneLabel(pane);
            }
        }

        if (self.status) |*status| {
            var text_buffer: [256]u8 = undefined;
            const text = self.statusText(&text_buffer);
            status.render(
                self.gpa,
                local,
                window.rows - 1,
                text,
                window.cols,
                self.config.colours.status_fg.toArray(),
                self.config.colours.status_bg.toArray(),
            ) catch {};
        }

        // The cursor goes last, because every other write moves it. `Terminal.enter` hides the
        // cursor for the duration of the session so that painting a frame does not leave it
        // flickering around the screen, so unless this puts it back the user is typing blind.
        self.drawCursor(local);
    }

    /// Place the terminal's cursor where the focused pane's program wants it, and show it.
    ///
    /// One cursor is shared by the whole window, so only the focused pane gets one: a cursor in
    /// every pane would be drawing something no program asked for and no user could act on. A
    /// pane that is not focused, has nothing on screen, or has a program that hid its own cursor
    /// leaves the window's cursor hidden, which is the state the session starts in.
    ///
    /// The position is in the pane's own coordinates, so the pane's origin is added to reach
    /// window coordinates. A program that scrolled its cursor out of view reports no position at
    /// all, which is why the position is optional rather than assumed to be in range.
    fn drawCursor(self: *Client, local: terminal_mod.Terminal) void {
        const pane = self.focusedPane() orelse return hideCursor(local);
        // A float takes the focus when one is raised, and the server says which; the tiled focus
        // is not what the user is typing into while a float is up.
        if (!pane.render.cursorVisible()) return hideCursor(local);
        const position = pane.render.cursorPosition() orelse return hideCursor(local);

        // The cursor is reported in the program's own coordinates, whose origin is the interior's
        // top left rather than the pane's. The frame is one cell, so the pane's origin alone would
        // put the cursor in the border.
        const interior = pane.rect.interior();
        var buffer: [32]u8 = undefined;
        const move = std.fmt.bufPrint(
            &buffer,
            "\x1b[{d};{d}H\x1b[?25h",
            .{ interior.y + position.y + 1, interior.x + position.x + 1 },
        ) catch return hideCursor(local);
        local.writeAll(move) catch {};
    }

    /// The pane the user's keystrokes go to, which is the one that should show a cursor.
    ///
    /// Mirrors the choice `sendInput` makes, so that the cursor is drawn in the pane that is
    /// actually receiving what the user types.
    fn focusedPane(self: *Client) ?*RemotePane {
        if (self.focused_float != 0) {
            if (self.findPane(self.focused_float)) |pane| return pane;
        }
        if (self.focused == 0) return null;
        return self.findPane(self.focused);
    }

    /// Mark the panes whose visibility changed since the last frame.
    ///
    /// A tiled pane is not painted while a float covers it, so the cells the float was sitting on
    /// still hold the float once it has moved away, been hidden or been closed. Neither terminal
    /// reports those cells as dirty, because neither terminal changed: the layout did. The
    /// rectangles the floats occupied are therefore remembered from the previous frame, and any
    /// tiled pane intersecting an old or a new one is marked stale, which makes the next paint
    /// write every row of it.
    ///
    /// Marking a pane that is still covered costs nothing, because the paint loop skips it.
    ///
    /// Infallible on purpose: losing the record would leave the cells under a float showing it
    /// after the float is gone, and the caller has nowhere to report that. The list can hold one
    /// entry per pane, which is allocated for once and then only ever reused.
    fn noteOcclusion(self: *Client) void {
        // Panes that a float stopped covering, or started covering, are stale. The comparison is
        // against the previous frame's list, which is then replaced by this frame's.
        for (self.panes.items) |*pane| {
            if (pane.floating) continue;
            var affected = false;
            for (self.covered.items) |old| {
                if (rectsIntersect(old, pane.rect)) affected = true;
            }
            for (self.panes.items) |*other| {
                if (!other.floating) continue;
                if (rectsIntersect(other.rect, pane.rect)) affected = true;
            }
            if (affected) pane.stale = true;
        }

        // The other direction, which was missing: a float's border is drawn in cells that the tiles
        // behind it also write to, because a tile's row blanking spans its whole interior and the
        // float sits on top of part of it. Tiled panes are painted first, so a tile that repaints
        // erases whatever of the float's frame it crosses, and the float has to put it back.
        //
        // Only when a tile under the float is actually being painted: a frame where nothing moves
        // costs nothing, which is the case this optimisation exists for.
        for (self.panes.items) |*pane| {
            if (!pane.floating) continue;
            if (pane.rect.width == 0 or pane.rect.height == 0) continue;
            for (self.panes.items) |*other| {
                if (other.floating) continue;
                if (other.rect.width == 0 or other.rect.height == 0) continue;
                if (!rectsIntersect(other.rect, pane.rect)) continue;
                // `stale` is consumed by the tile's own paint, so it cannot be read here; what
                // matters is whether the tile has anything to draw at all. Its render state says so,
                // and the global flag covers a resize or a move.
                if (other.stale or other.render.dirty() != .clean) pane.stale = true;
            }
        }

        self.covered.clearRetainingCapacity();
        self.covered.ensureUnusedCapacity(self.gpa, self.panes.items.len) catch return;
        for (self.panes.items) |*pane| {
            if (!pane.floating) continue;
            // A float with no area is not on screen, so it covers nothing and remembering it
            // would repaint a tiled pane for a float that was never drawn.
            if (pane.rect.width == 0 or pane.rect.height == 0) continue;
            self.covered.appendAssumeCapacity(pane.rect);
        }
    }

    /// Draw the session menu over the whole window.
    ///
    /// The sessions are numbered from one down the left, and the number typed so far is shown back
    /// to the user so that a multi-digit choice is visible before it is accepted. One `\x1b[K` per
    /// row is what clears each line, so a shorter listing does not leave the previous frame behind.
    fn drawMenu(self: *Client, local: terminal_mod.Terminal, window: terminal_mod.vtSize) void {
        var buffer: [512]u8 = undefined;

        local.writeAll("\x1b[2J") catch return;

        const heading = std.fmt.bufPrint(
            &buffer,
            "\x1b[1;1H\x1b[7m zmux | switch to which session?  type a number and press enter, esc to cancel \x1b[0m\x1b[K",
            .{},
        ) catch return;
        local.writeAll(heading) catch return;

        // The menu can only draw as many rows as the window has, and the heading and the prompt line
        // take one each. A listing longer than that is truncated rather than scrolled, because the
        // session the user wants is more likely to be near the top than at the bottom.
        const rows_available = if (window.rows > 2) window.rows - 2 else 0;
        var row: u16 = 0;
        for (self.session_menu.items) |info| {
            if (row >= rows_available) break;
            const line = std.fmt.bufPrint(
                &buffer,
                "\x1b[{d};1H  {d:>2}  {s}\x1b[K",
                .{ row + 2, row + 1, info.name.slice() },
            ) catch return;
            local.writeAll(line) catch return;
            row += 1;
        }

        // A listing that has not arrived yet, or one with nothing in it, says so rather than leaving
        // the screen blank: an empty window reads as a failure.
        if (self.session_menu.items.len == 0) {
            const empty = if (self.menu_ready)
                "\x1b[3;1H  (no sessions)\x1b[K"
            else
                "\x1b[3;1H  (asking the server)\x1b[K";
            local.writeAll(empty) catch return;
        }

        // Where the choice is written, so a number that has been typed is visible before Enter.
        const prompt_row = if (window.rows > 1) window.rows else 1;
        const choice = if (self.menu_choice == 0)
            std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[7m choice: \x1b[0m\x1b[K", .{prompt_row}) catch return
        else
            std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[7m choice: {d} \x1b[0m\x1b[K", .{ prompt_row, self.menu_choice }) catch return;
        local.writeAll(choice) catch {};
    }

    /// Draw a pane's number in the middle of its top row, while a dock target is being chosen.
    ///
    /// The label is drawn in inverse video and in the pane's own cells rather than at a fixed
    /// place, so that a user looking at a small pane still reads it. It is written after the
    /// pane's screen, so nothing the program does can cover it up.
    fn drawPaneLabel(self: *Client, pane: *RemotePane) void {
        const local = self.local orelse return;
        const rect = pane.rect;
        if (rect.width < 4 or rect.height == 0) return;

        var buffer: [48]u8 = undefined;
        // Centre the two-character cell: the number with a space either side.
        const column = rect.x + (rect.width / 2) - 1;
        const move = std.fmt.bufPrint(
            &buffer,
            "\x1b[{d};{d}H\x1b[7m {d} \x1b[0m",
            .{ rect.y + 1, column + 1, pane.label },
        ) catch return;
        local.writeAll(move) catch {};
    }

    /// Paint a float's frame to say its program has ended.
    ///
    /// A pane whose program exits keeps its last screen, which is what makes the output readable
    /// after the fact. Without a mark the frame around it looks exactly like a pane whose program is
    /// still running and simply not printing, so a user would wait for output that is never coming.
    ///
    /// The mark goes on the top edge, where the dock label also goes, because that edge already
    /// carries the one piece of state zmux writes into a pane's frame.
    fn drawExitedPane(self: *Client, pane: *RemotePane) void {
        const local = self.local orelse return;
        const rect = pane.rect;
        // The same minimum as a label: a frame narrower than this has no room for text inside its
        // top edge, and overwriting the corner would break the frame rather than annotate it.
        if (rect.width < 6 or rect.height < 3) return;

        var buffer: [48]u8 = undefined;
        const column = rect.x + (rect.width / 2) - 3;
        const move = std.fmt.bufPrint(
            &buffer,
            "\x1b[{d};{d}H\x1b[7m exited \x1b[0m",
            .{ rect.y + 1, column + 1 },
        ) catch return;
        local.writeAll(move) catch {};
    }

    /// Paint one pane's screen inside its rectangle.
    ///
    /// The pane's terminal is exactly the size of the rectangle the server gave it, so
    /// painting is a matter of moving the cursor to the rectangle's origin and writing the
    /// rows in order. The rectangle may have moved since the last frame, in which case
    /// every row is painted whether or not the library thinks it changed.
    fn drawPane(self: *Client, pane: *RemotePane) void {
        const local = self.local orelse return;
        const rect = pane.rect;
        if (rect.width == 0 or rect.height == 0) return;

        // The program is painted inside the frame, never over it. Its terminal was sized to the
        // interior, so this is the same rectangle the pty was told about.
        const interior = rect.interior();

        // A pane under a float is not painted at all. Whatever it would write is invisible, and
        // writing it is what made typing in a float repaint the whole session. It is marked stale
        // instead, so that the frame in which the float moves away repaints it in full.
        if (self.isCovered(pane)) {
            pane.stale = true;
            pane.render.update(pane.terminal) catch return;
            pane.render.clearDirty();
            return;
        }

        pane.render.update(pane.terminal) catch return;

        // Whether every row has to be written. The library says so itself when the global state
        // changed, which is what a resize looks like; `stale` covers the cases it cannot know
        // about, such as the pane having moved or been uncovered.
        const repaint_all = pane.stale or pane.render.dirty() == .full;
        pane.stale = false;

        // Every row is visited either way, because the row flags have to be cleared on the rows
        // that are not painted as well; leaving them set would make the next frame repaint them.
        // The whole frame is collected into one buffer and written once, so a frame costs one
        // write per pane rather than three per row.
        pane.line.clearRetainingCapacity();
        var row_index: u16 = 0;
        const Painter = struct {
            pane: *RemotePane,
            rect: protocol.Rect,
            row_index: *u16,
            gpa: std.mem.Allocator,
            repaint_all: bool,
            /// Whether any row was actually written, so that an empty frame does not cost a
            /// write syscall.
            wrote: bool = false,
            /// Set when a row could not be built and the walk was abandoned.
            ///
            /// Returning `false` from the visitor stops the walk without an error, so this is
            /// the only way to tell a complete frame from one that stopped in the middle.
            failed: bool = false,
            /// The style the terminal is currently in, which decides when the next cell has to
            /// write a new escape. Reset at the start of every row, because each row is written
            /// after a cursor move and the terminal keeps whatever the last cell of the previous
            /// row left it in.
            current_style: vt.Style = .{},
            /// How many cells of this row have been written, which is how the row is clipped to the
            /// rectangle without cutting into the escape sequences sharing the buffer.
            columns_written: u16 = 0,

            fn visit(painter: *@This(), row: *vt.RowIterator) bool {
                defer painter.row_index.* += 1;
                // Rows past the rectangle belong to no part of this pane. They are left dirty,
                // which is what the previous code did by stopping the walk, and the count only
                // differs when the terminal and the rectangle disagree.
                if (painter.row_index.* >= painter.rect.height) return false;

                const needs_paint = painter.repaint_all or row.isDirty();
                row.clearDirty();
                if (!needs_paint) return true;

                painter.wrote = true;
                // From here the row is committed to: the cursor move and the glyphs have to go
                // out together or the screen is left describing a row that was never written.
                // Each failure below abandons the frame rather than continuing with a partial
                // rectangle, and says so through `failed`.
                //
                // Move to this row's first column inside the pane's rectangle and blank exactly the
                // interior, then write the cells. Blanking matters because a row that got shorter
                // would otherwise keep the tail of the previous frame.
                //
                // The blanking is `ECH` with an explicit count rather than `EL` (`\x1b[K`), which
                // erases to the end of the whole screen line. Content starts at the interior's left
                // edge, so `EL` would reach past the pane's right border and wipe it, leaving the
                // frame with its top and bottom edges and no sides.
                var buffer: [48]u8 = undefined;
                const move = blankRow(&buffer, painter.rect, painter.row_index.*) catch {
                    painter.failed = true;
                    return false;
                };
                painter.pane.line.appendSlice(painter.gpa, move) catch {
                    painter.failed = true;
                    return false;
                };

                // Both are per row: the terminal's style after this row's cursor move is whatever
                // the previous row's last cell left it in, so the first cell of this row has to
                // consider itself unstyled until it says otherwise.
                painter.current_style = .{};
                painter.columns_written = 0;
                _ = row.forEachCell(painter, collect) catch {
                    painter.failed = true;
                    return false;
                };

                // The row ends with a reset, so that a colour cannot bleed into the cursor move
                // that follows or into the pane next to this one. It goes into the frame buffer
                // rather than to the terminal, so that the whole frame is one write.
                painter.pane.line.appendSlice(painter.gpa, "\x1b[0m") catch {
                    painter.failed = true;
                    return false;
                };

                return true;
            }

            fn collect(painter: *@This(), cell: *vt.CellIterator) void {
                // Cells beyond the rectangle are dropped rather than written and clipped. A wide
                // glyph or a mis-sized terminal would otherwise run into the pane beside this one.
                if (painter.columns_written >= painter.rect.width) return;
                painter.columns_written += 1;
                // Styling is emitted before the glyph, and only when it differs from the cell
                // before it. A run of text in one colour therefore costs one escape rather than one
                // per character, which matters for a screenful of a shell's output.
                const style = cell.resolvedStyle();
                if (!style.eql(painter.current_style)) {
                    terminal_mod.SgrWriter.write(
                        &painter.pane.line,
                        painter.gpa,
                        style,
                    ) catch {
                        // A dropped escape would colour the rest of the row wrongly, which is
                        // harder to notice than a missing glyph, so the row is abandoned.
                        painter.failed = true;
                        return;
                    };
                    painter.current_style = style;
                }

                var codepoints: [8]u32 = undefined;
                var utf8: [32]u8 = undefined;
                const bytes = cell.graphemesUtf8(&codepoints, &utf8);
                // A cell with no graphemes is a blank one, which the grid still has to be told
                // about: skipping it would shift every cell after it one column to the left.
                const text: []const u8 = if (bytes.len == 0) " " else bytes;
                painter.pane.line.appendSlice(painter.gpa, text) catch {
                    // A dropped glyph leaves a hole in the row that nothing would ever repair,
                    // because the row is marked clean once the frame is out.
                    painter.failed = true;
                };
            }
        };

        var painter = Painter{
            .pane = pane,
            .rect = interior,
            .row_index = &row_index,
            .gpa = self.gpa,
            .repaint_all = repaint_all,
        };
        // `forEachRow` reports a failure of the walk itself; the visitor reports a row it could
        // not build through `failed`, because stopping the walk with `false` is not an error. Both
        // mean the same thing to the frame, so both set the same flag.
        pane.render.forEachRow(&painter, Painter.visit) catch {
            painter.failed = true;
        };

        // The frame is written only if it is whole. Anything else and the pane is marked stale and
        // left dirty, so that the next frame paints all of it. Writing a partial frame would leave
        // the rows it did not reach showing the previous one, with their flags cleared and nothing
        // left to ask for them again.
        const outcome = commitFrame(&painter);
        if (outcome == .incomplete) {
            pane.stale = true;
            return;
        }

        // The border goes into the same buffer as the content, so a pane costs one write rather
        // than one per row plus one for the frame. It is appended after the rows, which is what
        // puts it around them rather than over them.
        //
        // It is redrawn only when the frame could have been disturbed, which is when the pane moved
        // or came out from under a float. Content never touches the border, because it is painted
        // inside the interior, so redrawing the frame on every keystroke would send two escape
        // sequences per row for cells that cannot have changed.
        //
        // The focused pane's frame is tinted. The focus is the server's, so a pane that loses it is
        // marked stale by the layout event that says so and paints its frame plain next frame.
        if (repaint_all) {
            const active = if (self.focused_float != 0)
                pane.id == self.focused_float
            else
                pane.id == self.focused;
            if (!appendBorder(
                &pane.line,
                self.gpa,
                rect,
                active,
                self.config.colours.border_active_fg,
                self.config.colours.border_inactive_fg,
            )) {
                pane.stale = true;
                return;
            }
        }
        if (pane.line.items.len == 0) return;

        if (local.writeAll(pane.line.items)) |_| {
            // The flags are cleared only once the frame is out and whole.
            pane.render.clearDirty();
        } else |_| {
            // The frame did not reach the terminal, so the rows it described are still showing the
            // previous one, and there is no way to say how much of it got out. Clearing the flags
            // here would leave those rows out of date forever. Repainting the whole rectangle next
            // frame also covers the rows a partial write did manage to place.
            pane.stale = true;
        }
    }

    /// Whether a float completely covers this pane, so that painting it would be wasted work.
    ///
    /// Completely, not merely overlapping. A float is centred and smaller than the window, so the
    /// pane behind it is usually visible around the edges — and floating a pane makes the pane it
    /// left behind *grow* into the space it gave up, which changes what is visible around the
    /// float. Skipping on any overlap left that ring unpainted, so the window showed the float and
    /// blankness where the tiled pane should have been.
    ///
    /// Only a pane that is entirely hidden can be skipped safely, which is the case this was
    /// written for: a float as large as the pane behind it.
    fn isCovered(self: *Client, pane: *RemotePane) bool {
        for (self.panes.items) |*other| {
            if (!other.floating) continue;
            if (other.id == pane.id) continue;
            if (other.rect.width == 0 or other.rect.height == 0) continue;
            if (covers(other.rect, pane.rect)) return true;
        }
        return false;
    }

    /// Send every pane's accumulated terminal replies to the program that provoked them.
    fn flushPaneReplies(self: *Client) void {
        for (self.panes.items) |*pane| {
            if (pane.reply.items.len == 0) continue;
            const payload = self.encoder.writeRequest(.{ .input = .{
                .name = self.watching,
                .pane = pane.id,
                .data = pane.reply.items,
            } }) catch {
                pane.reply.clearRetainingCapacity();
                continue;
            };
            socket.encode(&self.outgoing, self.gpa, payload) catch {};
            pane.reply.clearRetainingCapacity();
        }
        self.flush() catch {};
    }

    /// Handle a keystroke from the local terminal.
    ///
    /// Returns true when the user asked to detach.
    fn handleLocalInput(self: *Client) !bool {
        var buffer: [256]u8 = undefined;
        const read = std.posix.read(0, &buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return Error.TerminalFailed,
        };
        if (read == 0) return false;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);

        for (buffer[0..read]) |byte| {
            if (try self.handleByte(byte, &payload)) return true;
        }

        // Everything typed is accumulated into one request rather than one per byte, so
        // that pasting a long line does not become a burst of messages.
        try self.sendInput(payload.items);
        return false;
    }

    /// Handle one keystroke, returning true when the client should detach.
    ///
    /// `ctrl-b` is the prefix. Twice detaches, leaving the session running; followed by one of the
    /// command keys it acts on the layout instead. The prefix is armed by the first byte and consumed
    /// by the second, so a prefix followed by a key the layout does not use simply does nothing
    /// rather than being swallowed. It used to detach, which ended the client on a mistyped key.
    fn handleByte(
        self: *Client,
        byte: u8,
        payload: *std.ArrayList(u8),
    ) !bool {
        if (self.prefix_armed) {
            self.prefix_armed = false;
            return self.handleCommand(byte);
        }

        // While a dock target is being chosen, a digit picks one. The keystroke is consumed rather
        // than forwarded: the labels belong to zmux, and sending the number to a pane's program
        // would be sending it a character the user typed at a menu.
        if (self.docking) {
            if (byte >= '1' and byte <= '9') {
                const target = self.labeledPane(byte - '0');
                if (target) |id| {
                    // The mode ends when the server answers with the new layout. Asking twice would
                    // split twice, so the request is sent once and the mode is cleared here.
                    self.docking = false;
                    try self.sendRequest(.{ .dock = .{
                        .name = self.watching,
                        .target = id,
                    } });
                }
                return false;
            }
            // Escape leaves the choice without moving anything.
            if (byte == 0x1B) {
                self.docking = false;
                try self.sendRequest(.{ .dock_cancel = .{ .name = self.watching } });
                return false;
            }
            // Anything else is ignored rather than forwarded, so that a stray keystroke cannot be
            // typed into a program the user is not looking at.
            return false;
        }

        // While a pane is being picked to focus, a digit moves there. The same reading of the labels
        // as docking, and the same consumption of the keystroke, but the request is the one that
        // moves focus rather than the one that docks a float.
        if (self.focusing) {
            if (byte >= '1' and byte <= '9') {
                const target = self.labeledPane(byte - '0');
                if (target) |id| {
                    // One keystroke is the whole choice, so the number is not held for an Enter.
                    //
                    // The mode is deliberately not cleared here, unlike docking. A refusal -- a pane
                    // closed between the layout arriving and the digit being pressed -- sends no
                    // layout event, so clearing locally would take the numbers off screen while the
                    // server still believes the mode is on, and the next digit would be typed at a
                    // menu the user can no longer see. Waiting for the layout event keeps the two
                    // agreeing whatever the server decides.
                    try self.sendRequest(.{ .focus_target = .{
                        .name = self.watching,
                        .pane = id,
                    } });
                }
                return false;
            }
            // Escape leaves the choice without moving anything. The server is told so that it can
            // stop numbering, since the labels are its idea and not the client's, and the flag is
            // left for the layout event it answers with -- see the note above on why this side does
            // not clear it early.
            if (byte == 0x1B) {
                try self.sendRequest(.{ .dock_cancel = .{ .name = self.watching } });
                return false;
            }
            // Anything else is ignored rather than forwarded, for the same reason as docking.
            return false;
        }

        // While the history is being read, the movement keys move the viewport and everything else
        // is consumed. Nothing is forwarded: a program receiving a `j` the user meant as a scroll
        // would act on it, and the whole point of the mode is that the program is left alone.
        //
        // The prefix is the exception, and it is checked first. A reader inside the mode still needs
        // to reach the rest of zmux, and the keys that would take them out again are behind the
        // prefix; consuming it would leave the mode as the only thing a mistyped command could reach.
        if (self.scroll_mode and byte == prefix_key) {
            self.leaveScroll();
            self.prefix_armed = true;
            return false;
        }

        if (self.scroll_mode) {
            const pane = self.focusedPane() orelse {
                self.leaveScroll();
                return false;
            };
            // A page is the visible height less one row, so that a line of context carries over and
            // the reader can see where they were. That is what `less` and `vim` do.
            const page: i32 = if (pane.rect.height > 2) @as(i32, pane.rect.height) - 2 else 1;
            switch (byte) {
                'j', 'l' => pane.terminal.scrollBy(1),
                'k', 'h' => pane.terminal.scrollBy(-1),
                // The capitals move by ten, so a long history can be crossed without holding a key.
                'J', 'L' => pane.terminal.scrollBy(10),
                'K', 'H' => pane.terminal.scrollBy(-10),
                // Half a screen, the movement a reader makes most when looking for something.
                0x04 => pane.terminal.scrollBy(@divTrunc(page, 2)), // ctrl-d
                0x15 => pane.terminal.scrollBy(-@divTrunc(page, 2)), // ctrl-u
                0x06 => pane.terminal.scrollBy(page), // ctrl-f
                // Page-up is `ctrl-v`, the counterpart of `ctrl-f` on keyboards where the pair is
                // adjacent, and the key `less` uses for the same movement. `ctrl-b` would be the
                // obvious partner but it is the prefix, and a reader who pressed it expecting the
                // prefix would find themselves in a mode they could not leave by the key they meant
                // to press. The prefix is checked before this switch, so it wins.
                0x16 => pane.terminal.scrollBy(-page), // ctrl-v
                // The ends of the history. `g` is vim's and `G` the same for the other end.
                'g' => pane.terminal.scrollToTop(),
                'G' => pane.terminal.scrollToBottom(),
                // Leaving with Enter returns to the live screen, which is what the user wants when
                // they have found what they were looking for.
                'q', 0x1B, '\r', '\n' => {
                    self.leaveScroll();
                    return false;
                },
                else => return false,
            }
            // The rows on screen have changed, so the pane is painted again from the viewport the
            // library now holds.
            pane.stale = true;
            return false;
        }

        // While the session menu is open, the digits choose a session and Enter accepts. Every
        // keystroke is consumed: the menu belongs to zmux, and forwarding a digit to the pane behind
        // it would be sending a character the user typed at a menu.
        if (self.menu_open) {
            switch (byte) {
                // A number is built up digit by digit, so a session beyond the ninth is still
                // reachable. Only the sessions actually listed count, so a typed number that is too
                // large simply selects nothing.
                '0'...'9' => {
                    self.menu_choice = self.menu_choice * 10 + (byte - '0');
                    // A leading zero is not part of a number, so it is treated as starting one.
                    if (self.menu_choice == 0 and byte == '0') self.menu_choice = 0;
                    return false;
                },
                '\r', '\n' => {
                    const chosen = self.chosenSession();
                    self.closeMenu();
                    if (chosen) |info| {
                        // The size travels with the request, because the session being moved to has
                        // to be sized to this client and the server does not remember one between
                        // requests.
                        const window = self.local.?.size() catch terminal_mod.vtSize{
                            .rows = 24,
                            .cols = 80,
                        };
                        try self.sendRequest(.{ .switch_session = .{
                            .name = info.name,
                            .rows = if (window.rows > 1) window.rows - 1 else 1,
                            .cols = window.cols,
                        } });
                        // Everything on screen belongs to the session being left, and this client is
                        // about to be told a whole new layout. Clearing now means the old session's
                        // panes are not briefly drawn underneath the new one's.
                        self.forgetPanes();
                        try self.local.?.writeAll("\x1b[2J");
                    }
                    return false;
                },
                // Backspace withdraws a digit, which is what a number field does.
                0x7F, 0x08 => {
                    self.menu_choice /= 10;
                    return false;
                },
                // Escape leaves without switching.
                0x1B => {
                    self.closeMenu();
                    return false;
                },
                else => return false,
            }
        }

        if (byte == prefix_key) {
            // The prefix takes effect on the next byte; a prefix that is never followed
            // by anything means the user pressed it and stopped, which detaches so
            // that a bare prefix keeps working.
            self.prefix_armed = true;
            return false;
        }

        // Everything else is forwarded raw. The program's own terminal decides what the
        // bytes mean: re-encoding them here would discard whatever the program and its own
        // terminal have already agreed on.
        //
        // A keystroke also ends the scroll mode. Reading history and typing cannot both be
        // happening: the program's answer would arrive below the viewport, and the user would be
        // typing without seeing it. Returning to the live screen first is what makes the reply
        // visible.
        self.endScrollForInput();
        try payload.append(self.gpa, byte);
        return false;
    }

    /// Enter the scroll mode on the focused pane, if there is any history to read.
    ///
    /// Refusing when there is nothing above the screen is deliberate: a mode that opens onto a
    /// frozen screen and swallows the keys would read as the program hanging. The status line stays
    /// as it is, so the user sees why nothing happened.
    fn enterScroll(self: *Client) void {
        const pane = self.focusedPane() orelse return;
        if (pane.terminal.scrollbackRows() == 0) return;
        self.scroll_mode = true;
    }

    /// Leave the scroll mode and return the pane to the live screen.
    ///
    /// The viewport is put back at the bottom rather than left where it was, so that the pane shows
    /// what the program is doing now. Leaving it in history would mean the next output arrives
    /// off-screen and the pane looks stuck.
    fn leaveScroll(self: *Client) void {
        self.scroll_mode = false;
        const pane = self.focusedPane() orelse return;
        pane.terminal.scrollToBottom();
        pane.stale = true;
    }

    /// Return every pane's viewport to the live screen.
    ///
    /// Used when a key is about to be typed into a program. Reading history and typing at the same
    /// time is not possible: the program's next output would arrive out of view, and the user would
    /// be typing without seeing what they typed.
    fn endScrollForInput(self: *Client) void {
        if (!self.scroll_mode) return;
        self.leaveScroll();
    }

    /// Open the switch menu and ask the server for the sessions to fill it.
    ///
    /// The list is requested rather than remembered, because sessions come and go without this
    /// client being told: another terminal can start one, and one whose last pane exited is gone.
    /// Asking each time the menu opens is what makes it current.
    fn openMenu(self: *Client) !void {
        self.session_menu.clearRetainingCapacity();
        self.menu_choice = 0;
        self.menu_ready = false;
        self.menu_open = true;
        try self.sendRequest(.list);
    }

    /// Close the menu without switching.
    ///
    /// The panes are marked stale and the screen cleared, because the menu covered the whole window
    /// and the panes are painted by writing into their rectangles rather than by restoring a saved
    /// screen. Without this the window would come back empty.
    fn closeMenu(self: *Client) void {
        self.menu_open = false;
        self.menu_choice = 0;
        self.session_menu.clearRetainingCapacity();
        self.forgetMenuScreen();
    }

    /// Blank the window and arrange for every pane to be painted again.
    fn forgetMenuScreen(self: *Client) void {
        for (self.panes.items) |*pane| pane.stale = true;
        const local = self.local orelse return;
        local.writeAll("\x1b[2J") catch {};
    }

    /// The session the typed number names, or null when it names none.
    ///
    /// The numbers are positions in the listed order, counted from one, so zero names nothing. A
    /// number larger than the list names nothing either, which is what a mistyped digit gets.
    fn chosenSession(self: *Client) ?protocol.SessionInfo {
        if (self.menu_choice == 0) return null;
        const index = self.menu_choice - 1;
        if (index >= self.session_menu.items.len) return null;
        return self.session_menu.items[index];
    }

    /// Drop every pane this client holds, and their terminals with them.
    ///
    /// Used when moving to another session. The panes belong to the session being left, and the
    /// servers sends a whole new layout for the one being entered; keeping the old panes would draw
    /// a mixture of the two, and their terminals would go on parsing whatever arrived.
    fn forgetPanes(self: *Client) void {
        for (self.panes.items) |*pane| pane.deinit(self.gpa);
        self.panes.clearRetainingCapacity();
        for (self.pending.items) |*entry| entry.data.deinit(self.gpa);
        self.pending.clearRetainingCapacity();
        self.covered.clearRetainingCapacity();
        self.focused = 0;
        self.focused_float = 0;
        self.docking = false;
        self.focusing = false;
        self.floats_hidden = false;
        self.exited = false;
    }

    /// The pane carrying a given label, while a dock target is being chosen.
    ///
    /// Zero is not a label: an unnumbered pane carries zero, so matching it would let a caller name
    /// a float, which cannot be docked into. The check belongs here rather than at the call site,
    /// because this is the function that would get it wrong.
    fn labeledPane(self: *Client, label: u8) ?u64 {
        if (label == 0) return null;
        for (self.panes.items) |pane| {
            if (pane.label == label) return pane.id;
        }
        return null;
    }

    /// Act on the key that followed the prefix.
    ///
    /// Returns true when the client should detach.
    ///
    /// The key the user pressed is translated to the command it stands for before the switch below,
    /// so the switch can keep naming commands by the keys they were designed for. A `switch` in Zig
    /// needs its cases at compile time, so a configured key could not be a case; translating first
    /// leaves one table of defaults and one place a binding is looked up.
    fn handleCommand(self: *Client, byte: u8) !bool {
        const keybinds = self.config.keybinds;
        const command: u8 = if (byte == keybinds.split_horizontal)
            's'
        else if (byte == keybinds.split_vertical)
            'v'
        else if (byte == keybinds.close)
            'q'
        else if (byte == keybinds.float_toggle)
            'f'
        else if (byte == keybinds.float_focused)
            'F'
        else if (byte == keybinds.dock)
            'd'
        else if (byte == keybinds.focus_left)
            'h'
        else if (byte == keybinds.focus_down)
            'j'
        else if (byte == keybinds.focus_up)
            'k'
        else if (byte == keybinds.focus_right)
            'l'
        else if (byte == keybinds.move_next)
            '>'
        else if (byte == keybinds.move_previous)
            '<'
        else if (byte == keybinds.rotate)
            'o'
        else if (byte == keybinds.sessions)
            'w'
        else if (byte == keybinds.scroll)
            'x'
        else if (byte == keybinds.pane_select)
            'm'
        else
            byte;

        switch (command) {
            // `s` splits the focused pane side by side, and a second `s` stacks.
            's' => {
                try self.sendRequest(.{ .split = .{
                    .name = self.watching,
                    .axis = 0,
                    .program = &.{},
                } });
                return false;
            },
            'v' => {
                try self.sendRequest(.{ .split = .{
                    .name = self.watching,
                    .axis = 1,
                    .program = &.{},
                } });
                return false;
            },
            'q' => {
                try self.sendRequest(.{ .close = .{ .name = self.watching } });
                return false;
            },
            // `f` shows and hides the floats, and `F` parks the focused pane above the layout.
            // The toggle is on the easier key because it is the one used repeatedly while
            // working, and floating is a move made once. The client does not track which state the
            // server is in, so one key asks for the change and the server decides the direction.
            'f' => {
                try self.sendRequest(.{ .toggle_floats = .{ .name = self.watching } });
                return false;
            },
            'F' => {
                try self.sendRequest(.{ .float = .{ .name = self.watching } });
                return false;
            },
            'd' => {
                // No target: the server freezes the layout and labels the panes, and the number
                // typed next chooses one.
                try self.sendRequest(.{ .dock = .{
                    .name = self.watching,
                    .target = 0,
                } });
                return false;
            },
            // h/j/k/l move focus one pane in the direction the key points. The client sends the
            // direction rather than a pane, because which pane is "to the left" is geometry, and
            // the server owns the arrangement. A direction with nothing in it moves nothing.
            'h', 'j', 'k', 'l' => {
                const direction: u8 = switch (command) {
                    'h' => 0,
                    'l' => 1,
                    'k' => 2,
                    else => 3,
                };
                try self.sendRequest(.{ .focus = .{
                    .name = self.watching,
                    .direction = direction,
                } });
                return false;
            },
            // `<` and `>` move the focused pane past its neighbours. They read as arrows, so the key
            // says which way the pane travels, and unlike braces they sit on the same physical keys
            // whatever the keyboard layout.
            '>' => {
                try self.sendRequest(.{ .layout_move = .{
                    .name = self.watching,
                    .kind = 0,
                } });
                return false;
            },
            '<' => {
                try self.sendRequest(.{ .layout_move = .{
                    .name = self.watching,
                    .kind = 1,
                } });
                return false;
            },
            // `o` rotates the whole arrangement, which is a different operation from swapping: with
            // three panes or more, pairwise swaps cannot shift them all without a plan.
            'o' => {
                try self.sendRequest(.{ .layout_move = .{
                    .name = self.watching,
                    .kind = 2,
                } });
                return false;
            },
            // `w` opens the session menu, which lists the sessions by number and switches to the one
            // chosen. A window onto the other sessions, which is what the key is named for.
            'w' => {
                try self.openMenu();
                return false;
            },
            // `x` opens the focused pane's history for reading. Nothing is detached and the program
            // keeps running; the viewport is what moves.
            'x' => {
                self.enterScroll();
                return false;
            },
            // `m` numbers every tiled pane so one can be picked by name. It exists because the
            // direction keys cannot always reach the pane the user means: in a layout of one pane
            // above two, the pane below right shares no row with the pane above, so no single
            // direction key points at it. Choosing from the numbers needs no geometry at all.
            'm' => {
                try self.sendRequest(.{ .focus_select = .{ .name = self.watching } });
                return false;
            },
            // The prefix twice detaches, which is how a user who is used to pressing it twice gets
            // out.
            prefix_key => {
                if (self.watching.len > 0) {
                    try self.sendRequest(.{ .detach = .{ .name = self.watching } });
                }
                return true;
            },
            else => {
                // An unused key after the prefix does nothing at all.
                //
                // It used to detach, on the reasoning that a prefix followed by a typo should not
                // leave the client in a state where the next byte is eaten. It does not: the prefix
                // is consumed by `handleByte` whether or not the key that follows is one it knows,
                // so the next byte is an ordinary keystroke either way. What detaching actually did
                // was end the client on a mistyped key, losing the session the user was working in
                // to a slip of the finger. tmux ignores the key, and now so does this.
                return false;
            },
        }
    }

    /// Send keystrokes to whichever pane has focus.
    ///
    /// A raised float takes input in preference to the tiled pane: it is drawn on top and is what the
    /// user is looking at, so typing has to reach it. When no float is raised -- including while the
    /// floats are hidden -- input goes to the tiled focus, which is the only thing on screen.
    fn sendInput(self: *Client, data: []const u8) !void {
        if (data.len == 0) return;
        if (self.watching.len == 0) return;

        // The same choice `drawCursor` makes, so that the cursor is drawn in the pane this
        // reaches. Going through the pane rather than the identifier means a pane the client has
        // not been told about yet simply receives nothing, which is what the server would do with
        // its bytes anyway.
        const target = self.focusedPane() orelse return;

        try self.sendRequest(.{ .input = .{
            .name = self.watching,
            .pane = target.id,
            .data = data,
        } });
    }

    /// Handle one decoded event.
    fn onMessage(self: *Client, payload: []const u8) anyerror!void {
        var decoder = protocol.Decoder.init(payload);
        // A frame that does not decode is not fatal: the server and this client are the same
        // version, so a malformed frame means one of them is wrong about the protocol, which is not
        // something this side can repair by exiting.
        //
        // It is not silent either. Ignoring it outright left a protocol mismatch invisible: the
        // session would simply stop updating with nothing anywhere to say why, and the cause would
        // be a disagreement between two builds that neither side reported. The message goes to the
        // client's own stderr, which is the terminal zmux was started from rather than the pane, so
        // it is not drawn over the screen being painted.
        const event = decoder.event() catch |err| {
            self.protocol_complaints += 1;
            // Reported once, because a frame the decoder cannot read is likely to be followed by
            // more of them, and a message per frame would bury the screen it is warning about.
            if (self.protocol_complaints == 1) {
                self.err.print("zmux: ignoring a message this client cannot read ({s})\n", .{
                    @errorName(err),
                }) catch {};
                self.err.flush() catch {};
            }
            return;
        };
        try self.handleEvent(event);
    }

    fn handleEvent(self: *Client, event: protocol.Event) !void {
        switch (event) {
            .output => |output| {
                // The bytes go straight into the parser of the pane they name. What is drawn
                // is decided by `draw`, once everything the kernel had has been consumed.
                //
                // Output for a pane this client does not have yet is held rather than
                // dropped. The server sends a pane's screen when a client attaches, and those
                // events are ordered layout-then-output; but a split's output can reach a
                // client whose layout event is still behind it in the same batch, and
                // discarding those bytes would leave the new pane blank until its program
                // happened to redraw.
                const pane = self.findPane(output.pane) orelse {
                    try self.holdOutput(output.pane, output.data);
                    return;
                };
                pane.terminal.write(output.data);
            },
            .layout => |layout| {
                try self.applyLayout(layout);
            },
            .session => |info| {
                // While the menu is open the listing fills the menu rather than being printed, since
                // the user is looking at the menu and not at the terminal they started zmux from.
                if (self.menu_open) {
                    try self.session_menu.append(self.gpa, info);
                    return;
                }
                try self.printSession(info);
            },
            .list_end => {
                // While the menu is open the listing is its contents, so the end of the listing is
                // the moment it can be drawn rather than the end of the query.
                if (self.menu_open) {
                    self.menu_ready = true;
                    return;
                }
                self.finished = true;
            },
            .attached => |attached| {
                self.watching = attached.name;
            },
            .detached => |detached| {
                _ = detached;
                self.finished = true;
            },
            .exited => |exited| {
                self.exit_status = exited.status;
                // Recorded before finishing, so that the status line shows the session as
                // ended rather than still live.
                self.exited = true;
                if (self.local != null) {
                    // The session is gone, so there is nothing left to be attached to. This used to
                    // stay attached and keep the last screen up, which was right while the server
                    // kept a finished session; now that it discards one, staying would leave the
                    // client showing a dead window whose only content is this message. Detaching
                    // restores the terminal zmux was started from, with the status above it.
                    // A killed session did not exit, so there is no status to report. Printing one
                    // would tell the user their program had finished at the moment they destroyed it.
                    if (exited.killed) {
                        try self.err.print("\nzmux: session {s} was killed\n", .{
                            exited.name.slice(),
                        });
                    } else {
                        try self.err.print("\nzmux: session {s} exited with status {d}\n", .{
                            exited.name.slice(),
                            exited.status,
                        });
                    }
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

    /// Make the local panes match the layout the server just described.
    ///
    /// A layout event is the whole arrangement, not a delta, so this reconciles rather than
    /// applies: panes the server no longer lists are torn down, panes it has added get a
    /// terminal, and the rest have their rectangles and sizes updated in place. Rebuilding
    /// every pane on each layout would throw away their screens and make a split flash.
    fn applyLayout(self: *Client, layout: protocol.Layout) !void {
        // Panes that vanished. Iterated backwards because removing reorders the list.
        var index: usize = 0;
        while (index < self.panes.items.len) {
            const id = self.panes.items[index].id;
            var still_there = false;
            for (layout.panes) |placement| {
                if (placement.id == id) {
                    still_there = true;
                    break;
                }
            }
            if (still_there) {
                index += 1;
                continue;
            }
            var removed = self.panes.swapRemove(index);
            removed.deinit(self.gpa);
        }

        for (layout.panes) |placement| {
            const pane = self.findPane(placement.id) orelse blk: {
                // A pane the server has that this client does not. Its terminal is made at
                // the size the rectangle says, because that is the size its program was
                // given.
                break :blk try self.addPane(placement);
            };
            // A pane that moved or changed size has to be repainted in full, whatever its
            // terminal reports: its cells did not change, its position did. The library notices a
            // resize by itself, but not a move, and a move leaves the cells at the old place.
            if (pane.rect.x != placement.rect.x or pane.rect.y != placement.rect.y or
                pane.rect.width != placement.rect.width or
                pane.rect.height != placement.rect.height)
            {
                pane.stale = true;
            }

            pane.rect = placement.rect;
            pane.exited = placement.exited;
            pane.floating = placement.floating;

            // A label that appeared or moved is drawn into the pane's own cells, so the cells
            // underneath have to be repainted before it is drawn again.
            if (pane.label != placement.label) pane.stale = true;
            pane.label = placement.label;

            // The terminal is resized to match, so that the client's idea of the pane's
            // shape agrees with the server's. Skipping this would leave a pane's screen
            // wrapped for a width it no longer has.
            //
            // Two things matter here. The size is the *interior*, because that is what the server
            // gives the pty and what the cells are painted into; using the full rectangle would
            // wrap this side's text one column away from the program's. And it is only done when
            // the size actually changed, because a resize reflows the screen and marks rows dirty:
            // doing it on every layout event repainted panes whose program had done nothing, since
            // a layout event arrives for the whole session whenever any one pane changes.
            if (resizeTarget(placement.rect)) |target| {
                if (pane.terminal.cols() != target.width or
                    pane.terminal.rows() != target.height)
                {
                    pane.terminal.resize(target.width, target.height, 0, 0) catch {};
                }
            }
        }

        // The focus is part of what a pane's frame looks like, so a pane that gains or loses it has
        // to be repainted even though neither its cells nor its rectangle changed. Both panes are
        // marked: the one losing the tint needs its frame redrawn plain, and the one gaining it
        // needs the tint.
        const focus_changed = self.focused != layout.focused or
            self.focused_float != layout.focused_float;
        if (focus_changed) {
            for (self.panes.items) |*pane| {
                const was = if (self.focused_float != 0)
                    pane.id == self.focused_float
                else
                    pane.id == self.focused;
                const now = if (layout.focused_float != 0)
                    pane.id == layout.focused_float
                else
                    pane.id == layout.focused;
                if (was != now) pane.stale = true;
            }
        }

        self.focused = layout.focused;
        self.focused_float = layout.focused_float;
        self.docking = layout.docking;
        self.focusing = layout.focusing;
        self.floats_hidden = layout.floats_hidden;
        self.area_rows = layout.area_rows;
        self.area_cols = layout.area_cols;

        // The session is finished when it has panes and every one of them has exited. A
        // session with no panes at all is not finished: it is one whose last pane was closed
        // and whose client has not been told to leave yet.
        self.exited = self.panes.items.len > 0;
        for (self.panes.items) |pane| {
            if (!pane.exited) {
                self.exited = false;
                break;
            }
        }

        // Any output that arrived ahead of this layout is fed to the panes it was waiting
        // for, now that they exist.
        self.replayPending();
    }

    /// Make a local pane to mirror one the server has.
    fn addPane(self: *Client, placement: protocol.PanePlacement) !*RemotePane {
        // The terminal is the size the server gave the pty, which is the *interior*: the frame takes
        // a row and a column on every side, and the program inside is handed what is left. Building
        // this from the whole rectangle would give one pane two widths, and since both sides wrap
        // what they receive, the same output would become a different number of rows on each. The
        // reader scrolls this side's history, so that history has to be the program's own.
        const interior = placement.rect.interior();
        const cols = if (interior.width == 0) 1 else interior.width;
        const rows = if (interior.height == 0) 1 else interior.height;

        var terminal = try vt.Terminal.init(.{ .cols = cols, .rows = rows });
        errdefer terminal.deinit();

        var render = try terminal.createRenderState();
        errdefer render.deinit();

        const route = try self.gpa.create(PaneRoute);
        errdefer self.gpa.destroy(route);
        route.* = .{ .client = self, .pane = placement.id };

        try self.panes.append(self.gpa, .{
            .id = placement.id,
            .terminal = terminal,
            .render = render,
            .rect = placement.rect,
            .exited = placement.exited,
            .route = route,
        });

        const pane = &self.panes.items[self.panes.items.len - 1];
        // Replies this pane's terminal generates belong to the program in that pane, so the
        // callback has to know which one it is.
        pane.terminal.setWritePty(@ptrCast(route), onPaneWritePty);
        return pane;
    }

    fn findPane(self: *Client, id: u64) ?*RemotePane {
        for (self.panes.items) |*pane| {
            if (pane.id == id) return pane;
        }
        return null;
    }

    /// Hold bytes that arrived for a pane the layout has not described yet.
    ///
    /// Bounded by `pending_limit`: a pane that is never described would otherwise be a place for
    /// output to accumulate for as long as the client runs. See that constant for the case.
    fn holdOutput(self: *Client, pane: u64, data: []const u8) !void {
        for (self.pending.items) |*entry| {
            if (entry.pane == pane) {
                try entry.data.appendSlice(self.gpa, data);
                trimPending(&entry.data);
                return;
            }
        }
        var entry = PendingOutput{ .pane = pane };
        try entry.data.appendSlice(self.gpa, data);
        trimPending(&entry.data);
        try self.pending.append(self.gpa, entry);
    }

    /// Feed held bytes to the panes they were waiting for, and forget them.
    ///
    /// Called after a layout has been applied, so that a pane whose bytes arrived before it
    /// was created catches up in the order they were produced.
    fn replayPending(self: *Client) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const entry = &self.pending.items[index];
            const pane = self.findPane(entry.pane) orelse {
                index += 1;
                continue;
            };
            pane.terminal.write(entry.data.items);
            var done = self.pending.swapRemove(index);
            done.data.deinit(self.gpa);
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

    /// Receive bytes one pane's terminal wants sent to that pane's program.
    ///
    /// This runs inside `vt_write`, so it may only append to a buffer. Writing to the
    /// socket from here would reenter the parser, and the reply would be built out of the
    /// state the parser is halfway through changing.
    fn onPaneWritePty(
        terminal: vt.c.GhosttyTerminal,
        userdata: ?*anyopaque,
        data: [*c]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = terminal;
        // The userdata is this pane's route, which is its own allocation so that its
        // address survives the pane list reordering.
        const route: *PaneRoute = @ptrCast(@alignCast(userdata.?));
        const client = route.client;
        const pane = client.findPane(route.pane) orelse return;
        // A failed allocation loses a reply, and the program waiting on it stalls; there is no way
        // to report that from a C callback, which returns nothing. The queue is drained on the next
        // paint, so anything that did arrive is sent, but what was dropped here is dropped.
        pane.reply.appendSlice(client.gpa, data[0..len]) catch {};
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

/// What should happen to a frame the painter has just built.
///
/// Three outcomes, and the difference between the first two is the whole point: a frame that was
/// never completed must not be written, and must not have its dirty flags cleared either, because
/// those flags are the only record of work still owed. A frame with nothing in it is complete and
/// simply has no work to do, which is the common case for an idle program.
const FrameOutcome = enum {
    /// Every row that needed painting was built. Write it and clear the flags.
    complete,
    /// Nothing needed painting. There is nothing to write, and the flags are already clear.
    nothing,
    /// A row could not be built. The buffer holds a prefix of the frame, which must not be
    /// written: the rows it does not reach would keep the previous frame's cells with their
    /// flags cleared, and nothing would ever repaint them.
    incomplete,
};

/// Decide what to do with a painted frame.
fn commitFrame(painter: anytype) FrameOutcome {
    if (painter.failed) return .incomplete;
    if (!painter.wrote) return .nothing;
    return .complete;
}

/// Append the frame drawn around a pane's rectangle to a frame buffer.
///
/// Box-drawing characters rather than dashes, so that a border meeting another border looks
/// joined instead of dotted. Written as whole rows with a cursor move each, because the alternative
/// is a move per cell for no benefit: the border is at most a few hundred bytes.
///
/// An active pane's frame is tinted so that the focused pane is findable without reading the status
/// line. Only the border is coloured; the program's own cells are untouched, so nothing the program
/// draws is altered.
///
/// A rectangle too small to hold a frame is left alone; `interior` returned it untouched, so
/// drawing a border would eat the only cell the program has.
fn appendBorder(
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    rect: protocol.Rect,
    active: bool,
    active_colour: config_mod.Rgb,
    inactive_colour: ?config_mod.Rgb,
) bool {
    if (rect.width < 3 or rect.height < 3) return true;

    const horizontal = rect.width - 2;

    // The colour is set once at the start and cleared at the end, so a border costs two escapes
    // whatever its size. A pane without focus has no colour of its own unless one was configured,
    // in which case it keeps whatever the terminal is already doing, which is one fewer colour to
    // disagree with the user's theme.
    const colour: ?config_mod.Rgb = if (active) active_colour else inactive_colour;
    if (colour) |rgb| {
        buffer.print(gpa, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch return false;
    }

    // The edges are written straight into the frame buffer, which grows as needed, rather than
    // through a fixed scratch buffer. A fixed buffer would cap how wide a pane could be before its
    // border was silently dropped, and a terminal wide enough to hit that cap is not exotic.

    // The top edge, with corners.
    buffer.print(gpa, "\x1b[{d};{d}H\u{250c}", .{ rect.y + 1, rect.x + 1 }) catch return false;
    appendRepeated(buffer, gpa, "\u{2500}", horizontal) catch return false;
    buffer.appendSlice(gpa, "\u{2510}") catch return false;

    // The middle rows: a vertical marker at each side.
    var row: u16 = 1;
    while (row < rect.height - 1) : (row += 1) {
        buffer.print(gpa, "\x1b[{d};{d}H\u{2502}\x1b[{d};{d}H\u{2502}", .{
            rect.y + row + 1,
            rect.x + 1,
            rect.y + row + 1,
            rect.x + rect.width,
        }) catch return false;
    }

    // The bottom edge.
    buffer.print(gpa, "\x1b[{d};{d}H\u{2514}", .{ rect.y + rect.height, rect.x + 1 }) catch return false;
    appendRepeated(buffer, gpa, "\u{2500}", horizontal) catch return false;
    buffer.appendSlice(gpa, "\u{2518}") catch return false;

    // A colour cannot bleed into the neighbouring pane.
    buffer.appendSlice(gpa, "\x1b[0m") catch return false;
    return true;
}

/// Write `count` copies of a box-drawing character.
fn appendRepeated(
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    text: []const u8,
    count: u16,
) !void {
    var written: u16 = 0;
    while (written < count) : (written += 1) try buffer.appendSlice(gpa, text);
}

/// Drop the oldest bytes from a pending pane's buffer once it is over the limit.
///
/// The newest bytes are the ones kept. If the pane does appear, what a reader wants is the output
/// closest to now; the alternative, refusing the new bytes, would hold a stale screen and show it as
/// though it were current. Removing from the front is O(n) in the buffer, which is bounded by
/// `pending_limit` and only runs on the overflow path.
fn trimPending(data: *std.ArrayList(u8)) void {
    if (data.items.len <= pending_limit) return;
    const excess = data.items.len - pending_limit;
    std.mem.copyForwards(u8, data.items[0 .. data.items.len - excess], data.items[excess..]);
    data.shrinkRetainingCapacity(data.items.len - excess);
}

/// The size a pane's terminal should have for a given rectangle, or null when it cannot have one.
///
/// Null for a rectangle with no area, and for one too small to hold a frame and any content: the
/// interior would be empty and libghostty-vt rejects a zero-sized terminal. Returning null rather
/// than a zero size is what lets the caller leave the pane at the size it already has, which is
/// better than resizing it to nothing.
fn resizeTarget(rect: protocol.Rect) ?protocol.Rect {
    if (rect.width == 0 or rect.height == 0) return null;
    const interior = rect.interior();
    if (interior.width == 0 or interior.height == 0) return null;
    return interior;
}

/// The escape sequence that puts the cursor on one interior row and blanks exactly that row.
///
/// `ECH` with an explicit count, not `EL`. `EL` (`\x1b[K`) erases to the end of the whole screen
/// line, and since the interior starts one column in from the pane's left edge, it reaches past the
/// pane's right border and erases it. The frame then keeps its top and bottom edges and loses both
/// sides — and only on rows whose content did not already fill the interior, which is what makes it
/// look like the border is intermittently broken rather than absent.
///
/// Writing this by hand in the test would only check the test, so the sequence is built here and the
/// test calls it.
fn blankRow(buffer: []u8, rect: protocol.Rect, row_index: u16) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "\x1b[{d};{d}H\x1b[{d}X",
        .{ rect.y + row_index + 1, rect.x + 1, rect.width },
    );
}

/// Hide the window's cursor.
///
/// `Terminal.enter` hides it for the session and every frame has to say what it wants, so this is
/// the answer whenever there is no position to show one at.
fn hideCursor(local: terminal_mod.Terminal) void {
    local.writeAll("\x1b[?25l") catch {};
}

/// Whether two rectangles share at least one cell.
///
/// Rectangles with no area share nothing, which matters because a pane that has not been given a
/// size yet is described as a zero-sized rectangle at the origin rather than being absent. Treating
/// one as covering the top-left corner would make every frame repaint the panes near it.
fn rectsIntersect(a: protocol.Rect, b: protocol.Rect) bool {
    if (a.width == 0 or a.height == 0) return false;
    if (b.width == 0 or b.height == 0) return false;
    // Half-open ranges: edges that merely touch do not overlap.
    if (a.x + a.width <= b.x) return false;
    if (b.x + b.width <= a.x) return false;
    if (a.y + a.height <= b.y) return false;
    if (b.y + b.height <= a.y) return false;
    return true;
}

/// Whether one rectangle hides another completely.
///
/// Every cell of `inner` has to be inside `outer`; an overlap that leaves part of the pane showing
/// is not enough, because the part left showing still has to be drawn. This is the test for skipping
/// a pane under a float, and the difference from `rectsIntersect` is the whole reason the pane
/// behind a float was blank when only its edges were covered.
fn covers(outer: protocol.Rect, inner: protocol.Rect) bool {
    if (outer.width == 0 or outer.height == 0) return false;
    if (inner.width == 0 or inner.height == 0) return false;
    if (inner.x < outer.x or inner.y < outer.y) return false;
    if (inner.x + inner.width > outer.x + outer.width) return false;
    if (inner.y + inner.height > outer.y + outer.height) return false;
    return true;
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

test "the prefix key arms the prefix, and the old one no longer does" {
    // The prefix is recognised in `handleByte`, which is pure enough to test without a socket. What
    // matters is that the key named by `prefix_key` is the one that arms it, and that the key it was
    // moved from does not: a rename that left the old byte reachable would leave two prefixes, and
    // the second would silently swallow the byte it consumed.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        client.session_menu.deinit(gpa);
        client.encoder.deinit();
    }

    try std.testing.expectEqual(@as(u8, 0x02), prefix_key);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    // The prefix arms and is not forwarded to the program.
    _ = try client.handleByte(prefix_key, &payload);
    try std.testing.expect(client.prefix_armed);
    try std.testing.expectEqual(@as(usize, 0), payload.items.len);

    // The key the prefix used to be is an ordinary byte now, and reaches the program.
    client.prefix_armed = false;
    payload.clearRetainingCapacity();
    _ = try client.handleByte(0x01, &payload);
    try std.testing.expect(!client.prefix_armed);
    try std.testing.expectEqualStrings("\x01", payload.items);
}

test "a label finds the pane the server numbered" {
    // The number the user types is matched against the labels the server assigned, which are the
    // positions of the tiled panes in the layout event. Getting this wrong would dock a float into
    // a pane the user was not looking at.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    // Two panes with labels, and a float with none. The float must not be reachable by number,
    // since docking into a float is not a thing the server will do.
    for ([_]struct { id: u64, label: u8 }{
        .{ .id = 100, .label = 1 },
        .{ .id = 200, .label = 2 },
        .{ .id = 300, .label = 0 },
    }) |entry| {
        var terminal = try vt.Terminal.init(.{ .cols = 10, .rows = 5 });
        errdefer terminal.deinit();
        var render = try terminal.createRenderState();
        errdefer render.deinit();
        const route = try gpa.create(PaneRoute);
        route.* = .{ .client = &client, .pane = entry.id };
        try client.panes.append(gpa, .{
            .id = entry.id,
            .terminal = terminal,
            .render = render,
            .label = entry.label,
            .route = route,
        });
    }
    defer for (client.panes.items) |*pane| pane.deinit(gpa);

    try std.testing.expectEqual(@as(?u64, 100), client.labeledPane(1));
    try std.testing.expectEqual(@as(?u64, 200), client.labeledPane(2));
    // Nothing is numbered zero or above the number of tiled panes.
    try std.testing.expectEqual(@as(?u64, null), client.labeledPane(0));
    try std.testing.expectEqual(@as(?u64, null), client.labeledPane(9));
}

test "one keystroke repaints one row, not the screen" {
    // The defect this guards against: the render state's dirty flags are never
    // cleared by the library, so a client that does not clear them is told that
    // every row changed on every frame, forever. That turned each keystroke
    // into a full repaint of every pane, which is what made typing flicker.
    var terminal = try vt.Terminal.init(.{ .cols = 80, .rows = 20 });
    defer terminal.deinit();
    var render = try terminal.createRenderState();
    defer render.deinit();

    // Paint a frame the way the client does, and report how many rows it wrote.
    const Counter = struct {
        painted: usize = 0,
        rows: usize = 0,

        fn visit(self: *@This(), row: *vt.RowIterator) bool {
            self.rows += 1;
            const needed = row.isDirty();
            // Clearing is part of painting, and the point of the test: without
            // it the next frame reports this row dirty again.
            row.clearDirty();
            if (needed) self.painted += 1;
            return true;
        }
    };
    const paint = struct {
        fn call(state: vt.RenderState) !Counter {
            var counter = Counter{};
            try state.forEachRow(&counter, Counter.visit);
            state.clearDirty();
            return counter;
        }
    }.call;

    terminal.write("user@host:~$ ls -la");
    try render.update(terminal);
    var frame = try paint(render);
    // The first frame is everything, because none of it has been drawn yet.
    try std.testing.expectEqual(@as(usize, 20), frame.painted);

    // A frame in which nothing happened must repaint nothing. This is the
    // assertion that fails if the global dirty flag is left set.
    try render.update(terminal);
    frame = try paint(render);
    try std.testing.expectEqual(@as(usize, 0), frame.painted);
    try std.testing.expectEqual(vt.Dirty.clean, render.dirty());

    // One character lands on one row.
    terminal.write("x");
    try render.update(terminal);
    frame = try paint(render);
    try std.testing.expectEqual(@as(usize, 1), frame.painted);
    try std.testing.expectEqual(@as(usize, 20), frame.rows);

    // And the frame after it is clean again, proving the per-row flags were
    // cleared rather than left set by the row that was just painted.
    try render.update(terminal);
    frame = try paint(render);
    try std.testing.expectEqual(@as(usize, 0), frame.painted);
}

test "output held for a pane that never appears stays bounded" {
    // The defect this guards against: a pane the layout never describes, accumulating output for as
    // long as the client runs. A float whose program keeps printing while the floats are hidden is
    // exactly that -- `sendLayout` leaves hidden floats out, and the server forwards their output
    // anyway -- so a hidden `tail -f` grew this without limit.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.pending.items) |*entry| entry.data.deinit(gpa);
        client.pending.deinit(gpa);
        client.encoder.deinit();
    }

    // A chunk far larger than the limit, so one call is enough to overflow it.
    const chunk = "x" ** (pending_limit * 3);
    try client.holdOutput(42, chunk);

    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    const held = client.pending.items[0].data.items.len;
    // The bound is the limit, not three times it.
    try std.testing.expectEqual(@as(usize, pending_limit), held);

    // Feeding more keeps it there rather than growing.
    for (0..8) |_| try client.holdOutput(42, chunk);
    try std.testing.expectEqual(@as(usize, pending_limit), client.pending.items[0].data.items.len);
    // Still one entry for the one pane, and every byte in it is real output rather than a hole from
    // a bad copy.
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(client.pending.items[0].data.items[0] == 'x');

    // The newest bytes are the ones kept, which is what makes the trimmed buffer worth showing if
    // the pane does appear. A distinct tail marks it.
    try client.holdOutput(42, "TAIL");
    try std.testing.expectEqual(@as(usize, pending_limit), client.pending.items[0].data.items.len);
    try std.testing.expect(std.mem.endsWith(u8, client.pending.items[0].data.items, "TAIL"));

    // A second pane is bounded on its own rather than sharing the allowance.
    try client.holdOutput(43, chunk);
    try std.testing.expectEqual(@as(usize, 2), client.pending.items.len);
    try std.testing.expectEqual(@as(usize, pending_limit), client.pending.items[1].data.items.len);

    // Under the limit nothing is trimmed, so the ordinary case does not lose the pane's first output.
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(gpa);
    try small.appendSlice(gpa, "hello");
    trimPending(&small);
    try std.testing.expectEqualStrings("hello", small.items);
}

test "a pane is covered only by an overlapping float" {
    // A tiled pane under a float is skipped when painting, so the test for
    // "covered" has to be exact in both directions: too eager and a pane that
    // is visible is left unpainted, too shy and the skip never happens.
    const tiled = protocol.Rect{ .x = 0, .y = 0, .width = 40, .height = 20 };

    // Wholly inside, so covered.
    try std.testing.expect(rectsIntersect(
        protocol.Rect{ .x = 10, .y = 5, .width = 20, .height = 10 },
        tiled,
    ));
    // Overlapping one corner, so covered.
    try std.testing.expect(rectsIntersect(
        protocol.Rect{ .x = 30, .y = 15, .width = 20, .height = 10 },
        tiled,
    ));
    // Disjoint, so not covered.
    try std.testing.expect(!rectsIntersect(
        protocol.Rect{ .x = 40, .y = 0, .width = 20, .height = 10 },
        tiled,
    ));
    // Sharing only an edge is not overlapping: half-open ranges.
    try std.testing.expect(!rectsIntersect(
        protocol.Rect{ .x = 40, .y = 5, .width = 20, .height = 10 },
        tiled,
    ));
    try std.testing.expect(!rectsIntersect(
        protocol.Rect{ .x = 0, .y = 20, .width = 40, .height = 10 },
        tiled,
    ));
    // A pane that has not been sized yet covers nothing, rather than sitting
    // on the origin and covering whatever is there.
    try std.testing.expect(!rectsIntersect(
        protocol.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
        tiled,
    ));
    try std.testing.expect(!rectsIntersect(
        tiled,
        protocol.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    ));
}

test "the cursor is placed inside the focused pane" {
    // The window's cursor is hidden when the session starts, so that painting a
    // frame does not leave it flickering around the screen. Nothing puts it back
    // unless the client does, and a cursor that is shown in the wrong pane is
    // worse than none: it points at a place the user's typing does not go.
    //
    // The arithmetic is the part worth pinning down. A pane's terminal reports the
    // cursor in its own coordinates, with its own origin at zero, while the window
    // is addressed from one. Adding the pane's origin and one is the whole
    // translation, and it is easy to be off by a row or a column.
    const pane = protocol.Rect{ .x = 10, .y = 5, .width = 20, .height = 10 };
    const position = .{ .x = 3, .y = 2 };

    var buffer: [32]u8 = undefined;
    const move = try std.fmt.bufPrint(
        &buffer,
        "\x1b[{d};{d}H\x1b[?25h",
        .{ pane.y + position.y + 1, pane.x + position.x + 1 },
    );
    // Row 5 + 2 + 1 = 8, column 10 + 3 + 1 = 14.
    try std.testing.expectEqualStrings("\x1b[8;14H\x1b[?25h", move);

    // The origin of a pane at the top left is row 1, column 1, not row 0.
    const origin = protocol.Rect{ .x = 0, .y = 0, .width = 20, .height = 10 };
    const at_origin = try std.fmt.bufPrint(
        &buffer,
        "\x1b[{d};{d}H\x1b[?25h",
        .{ origin.y + 0 + 1, origin.x + 0 + 1 },
    );
    try std.testing.expectEqualStrings("\x1b[1;1H\x1b[?25h", at_origin);
}

test "the cursor follows the float when one is raised" {
    // `sendInput` and `drawCursor` both go through `focusedPane`, so the cursor
    // cannot sit in a pane other than the one being typed into. What this pins
    // down is the choice itself: a raised float wins over the tiled focus, because
    // it is drawn on top and is what the user is looking at, and the tiled focus is
    // used only when no float is raised.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    // No panes at all, so nothing to point at.
    try std.testing.expectEqual(@as(?*RemotePane, null), client.focusedPane());

    // A tiled pane and a float, with both focuses set to different panes.
    for ([_]struct { id: u64, floating: bool }{
        .{ .id = 100, .floating = false },
        .{ .id = 200, .floating = true },
    }) |entry| {
        var terminal = try vt.Terminal.init(.{ .cols = 20, .rows = 5 });
        errdefer terminal.deinit();
        var render = try terminal.createRenderState();
        errdefer render.deinit();
        const route = try gpa.create(PaneRoute);
        route.* = .{ .client = &client, .pane = entry.id };
        try client.panes.append(gpa, .{
            .id = entry.id,
            .terminal = terminal,
            .render = render,
            .floating = entry.floating,
            .route = route,
        });
    }

    client.focused = 100;
    // With no float raised, the tiled focus is the target.
    try std.testing.expectEqual(@as(?u64, 100), client.focusedPane().?.id);

    // A raised float takes it, even though the tiled focus is unchanged.
    client.focused_float = 200;
    try std.testing.expectEqual(@as(?u64, 200), client.focusedPane().?.id);

    // Hiding the floats clears the raised one, which returns the focus to the tile.
    client.focused_float = 0;
    try std.testing.expectEqual(@as(?u64, 100), client.focusedPane().?.id);

    // A raised float the client has not been told about falls back rather than
    // failing: the layout event that creates it is still in flight.
    client.focused_float = 999;
    try std.testing.expectEqual(@as(?u64, 100), client.focusedPane().?.id);
}

test "an incomplete frame is neither written nor marked clean" {
    // The trap this guards against: clearing the dirty flags after a frame that was
    // never completed. The rows the frame did not reach keep the previous frame's
    // cells, and with their flags cleared nothing ever asks for them again, so the
    // pane shows a half-updated screen until the program happens to overwrite it.
    //
    // A frame that stopped early has to be told apart from one that simply had
    // nothing to do, which is why there are three outcomes rather than a bool.
    const Case = struct { failed: bool, wrote: bool, expected: FrameOutcome };
    for ([_]Case{
        // A row failed to build, whatever else happened. Not writable.
        .{ .failed = true, .wrote = true, .expected = .incomplete },
        .{ .failed = true, .wrote = false, .expected = .incomplete },
        // Nothing failed and something was painted: the ordinary keystroke.
        .{ .failed = false, .wrote = true, .expected = .complete },
        // Nothing failed and nothing was painted: an idle program. Writing this
        // would cost a syscall per pane per frame for no change at all, and
        // clearing the flags is correct because there was no work owed.
        .{ .failed = false, .wrote = false, .expected = .nothing },
    }) |case| {
        var painter = .{ .failed = case.failed, .wrote = case.wrote };
        try std.testing.expectEqual(case.expected, commitFrame(&painter));
    }
}

test "the resize target is the interior, and absent when there is no room" {
    // The size a pane's terminal is given is the interior, not the rectangle: the server sizes the
    // pty the same way, so the two agree about where the text wraps. Sending the full rectangle
    // would wrap this side's text one column away from the program's.
    const target = resizeTarget(.{ .x = 10, .y = 5, .width = 20, .height = 10 }).?;
    try std.testing.expectEqual(@as(u16, 11), target.x);
    try std.testing.expectEqual(@as(u16, 6), target.y);
    try std.testing.expectEqual(@as(u16, 18), target.width);
    try std.testing.expectEqual(@as(u16, 8), target.height);

    // Nothing to resize to, so the caller leaves the pane alone rather than making it zero-sized.
    // A zero-sized terminal is rejected by libghostty-vt, and a pane keeping its old size is better
    // than one that cannot exist.
    try std.testing.expectEqual(@as(?protocol.Rect, null), resizeTarget(.{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
    }));

    // A pane too small to hold a frame keeps all of its cells and simply has no border, so two by
    // ten is a perfectly good terminal size rather than a refusal.
    const narrow = resizeTarget(.{ .x = 0, .y = 0, .width = 2, .height = 10 }).?;
    try std.testing.expectEqual(@as(u16, 2), narrow.width);
    try std.testing.expectEqual(@as(u16, 10), narrow.height);
}

test "a content row cannot erase the border beside it" {
    // Every content row is blanked before it is written. Blanking with `EL` (`\x1b[K`) erases to the
    // end of the *screen* line, which reaches past the pane's right border and wipes it: the frame
    // kept its top and bottom edges and lost both sides, and only on panes wider than the content
    // actually filled, which is why it looked like the border was "partly" missing.
    //
    // The sequence used is `ECH` with an explicit count, so it stops at the interior's last column.
    // This pins that down, because the two differ by one letter and the failure is visual.
    var buffer: [48]u8 = undefined;
    const interior = protocol.Rect{ .x = 1, .y = 1, .width = 18, .height = 8 };
    const move = try blankRow(&buffer, interior, 0);
    try std.testing.expectEqualStrings("\x1b[2;2H\x1b[18X", move);
    // `EL`, which is the mistake this guards against, would be the same prefix with a bare K and
    // no count, erasing to the end of the screen line instead of to the pane's edge.
    try std.testing.expect(std.mem.find(u8, move, "[K") == null);
    try std.testing.expect(std.mem.endsWith(u8, move, "[18X"));

    // The count is the interior's width, so the last cell it clears is one short of the pane's
    // right border column: the border survives.
    try std.testing.expectEqual(@as(u16, 20), interior.x + interior.width + 1);

    // The row addressed is the interior's, not the pane's: the frame owns the first one.
    const later = try blankRow(&buffer, interior, 3);
    try std.testing.expectEqualStrings("\x1b[5;2H\x1b[18X", later);
}

test "the border is drawn at any width, however wide the terminal" {
    // The edges were built in a fixed 512-byte scratch buffer, and a pane wide enough to overflow it
    // lost its whole border silently: the function returned success without writing anything. At
    // three bytes per box-drawing cell that is a pane of about 160 columns, which a maximised
    // terminal on a wide monitor reaches. The frame buffer grows, so there is no such width.
    const gpa = std.testing.allocator;
    const wide = protocol.Rect{ .x = 0, .y = 0, .width = 400, .height = 3 };

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try std.testing.expect(appendBorder(&line, gpa, wide, false, .{ .r = 0x7c, .g = 0xa8, .b = 0x6c }, null));

    // A horizontal edge of 398 cells, three bytes each, is far past the old limit.
    try std.testing.expect(line.items.len > 1200);
    // Both corners and both sides are present.
    try std.testing.expect(std.mem.find(u8, line.items, "\u{250c}") != null);
    try std.testing.expect(std.mem.find(u8, line.items, "\u{2510}") != null);
    try std.testing.expect(std.mem.find(u8, line.items, "\u{2514}") != null);
    try std.testing.expect(std.mem.find(u8, line.items, "\u{2518}") != null);
    try std.testing.expect(std.mem.find(u8, line.items, "\u{2502}") != null);

    // A pane too small for a frame is left alone and reports success, rather than drawing a frame
    // over the only cell the program has.
    var tiny: std.ArrayList(u8) = .empty;
    defer tiny.deinit(gpa);
    try std.testing.expect(appendBorder(
        &tiny,
        gpa,
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        true,
        .{ .r = 0x7c, .g = 0xa8, .b = 0x6c },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), tiny.items.len);
}

test "a finished session detaches the client rather than leaving the window up" {
    // The server discards a session whose last pane exits, so a client that stays attached is
    // attached to nothing: it keeps drawing a dead window whose only content is the exit message.
    // Leaving the alternate screen is what takes the TUI down, and that happens when the client
    // finishes.
    //
    // The event handler is exercised through the state it sets, because the printing and the screen
    // restore need a real terminal. What matters is that `finished` ends the loop, which is what
    // makes the client leave the alternate screen and restore the terminal it was started from.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    // A client that has not been told anything keeps running.
    try std.testing.expect(!client.finished);

    // The exit event is what the loop watches, and no local terminal means nothing is printed, so
    // the handler is safe to call here.
    try client.handleEvent(.{ .exited = .{
        .name = try protocol.Name.init("s"),
        .status = 3,
        .killed = false,
    } });
    try std.testing.expect(client.finished);
    try std.testing.expect(client.exited);
    try std.testing.expectEqual(@as(u8, 3), client.exit_status);
}

test "the active pane's border is tinted and the others are not" {
    // The border is what says which pane has focus, so the tint has to distinguish them. Only the
    // focused pane's frame is coloured: tinting both would say nothing.
    const gpa = std.testing.allocator;
    const rect = protocol.Rect{ .x = 0, .y = 0, .width = 10, .height = 4 };

    const tint = config_mod.Rgb{ .r = 0x7c, .g = 0xa8, .b = 0x6c };

    var active: std.ArrayList(u8) = .empty;
    defer active.deinit(gpa);
    try std.testing.expect(appendBorder(&active, gpa, rect, true, tint, null));
    try std.testing.expect(std.mem.find(u8, active.items, "\x1b[38;2;124;168;108m") != null);

    // Without a configured colour the unfocused frame is left in whatever the terminal is doing,
    // which is the default: one fewer colour to disagree with the user's theme.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try std.testing.expect(appendBorder(&plain, gpa, rect, false, tint, null));
    try std.testing.expect(std.mem.find(u8, plain.items, "38;2;") == null);

    // But it can be given one, and then the two frames differ by the colour they were given rather
    // than by one of them being absent.
    var inactive: std.ArrayList(u8) = .empty;
    defer inactive.deinit(gpa);
    const grey = config_mod.Rgb{ .r = 0x60, .g = 0x60, .b = 0x60 };
    try std.testing.expect(appendBorder(&inactive, gpa, rect, false, tint, grey));
    try std.testing.expect(std.mem.find(u8, inactive.items, "\x1b[38;2;96;96;96m") != null);
    try std.testing.expect(std.mem.find(u8, inactive.items, "\x1b[38;2;124;168;108m") == null);

    // The colour is cleared at the end, so it cannot bleed into the pane's own cells or into a
    // neighbouring pane. Both forms end with the reset.
    try std.testing.expect(std.mem.endsWith(u8, active.items, "\x1b[0m"));
    try std.testing.expect(std.mem.endsWith(u8, plain.items, "\x1b[0m"));

    // The tint is set once however wide the pane is, so it does not grow the frame.
    const wide = protocol.Rect{ .x = 0, .y = 0, .width = 200, .height = 4 };
    var wide_active: std.ArrayList(u8) = .empty;
    defer wide_active.deinit(gpa);
    try std.testing.expect(appendBorder(&wide_active, gpa, wide, true, tint, null));
    var wide_plain: std.ArrayList(u8) = .empty;
    defer wide_plain.deinit(gpa);
    // An unfocused pane with no colour of its own, so the difference below is exactly one
    // introducer: a coloured frame must not write one per cell.
    try std.testing.expect(appendBorder(&wide_plain, gpa, wide, false, tint, null));
    // One introducer plus one reset, whatever the width.
    const difference = wide_active.items.len - wide_plain.items.len;
    try std.testing.expectEqual(@as(usize, "\x1b[38;2;124;168;108m".len), difference);
}

test "a float only hides a pane it covers completely" {
    // Skipping a pane that is merely overlapped leaves the visible part of it blank. A float is
    // centred and smaller than the window, so the pane behind it is normally visible around the
    // edges — and when a pane is floated, the pane it left behind grows into the space, which
    // changes what shows around the float.
    const pane = protocol.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };

    // A float smaller than the pane, sitting inside it: the pane shows around it, so it must be
    // painted.
    try std.testing.expect(!covers(
        protocol.Rect{ .x = 10, .y = 4, .width = 60, .height = 16 },
        pane,
    ));
    // A float that covers the pane entirely: nothing of the pane shows, so painting it is wasted.
    try std.testing.expect(covers(
        protocol.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 },
        pane,
    ));
    try std.testing.expect(covers(
        protocol.Rect{ .x = 0, .y = 0, .width = 90, .height = 30 },
        pane,
    ));
    // A float that covers all but one column leaves that column to draw.
    try std.testing.expect(!covers(
        protocol.Rect{ .x = 0, .y = 0, .width = 79, .height = 24 },
        pane,
    ));
    // Zero-sized rectangles hide nothing and are hidden by nothing.
    try std.testing.expect(!covers(
        protocol.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
        pane,
    ));
    try std.testing.expect(!covers(
        pane,
        protocol.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    ));
}

test "a pane is skipped only when a float covers all of it" {
    // `isCovered` is the decision that skips painting, and it has to use complete coverage rather
    // than overlap. Overlap was the bug: the pane behind a centred float was skipped, so the part
    // of it visible around the float stayed blank.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    // Three panes: two tiled and one float over the first of them.
    for ([_]struct { id: u64, floating: bool, rect: protocol.Rect }{
        .{
            .id = 1,
            .floating = false,
            .rect = .{ .x = 0, .y = 0, .width = 40, .height = 20 },
        },
        .{
            .id = 2,
            .floating = false,
            .rect = .{ .x = 40, .y = 0, .width = 40, .height = 20 },
        },
        .{
            .id = 3,
            .floating = true,
            .rect = .{ .x = 10, .y = 5, .width = 20, .height = 10 },
        },
    }) |entry| {
        var terminal = try vt.Terminal.init(.{ .cols = 20, .rows = 5 });
        errdefer terminal.deinit();
        var render = try terminal.createRenderState();
        errdefer render.deinit();
        const route = try gpa.create(PaneRoute);
        route.* = .{ .client = &client, .pane = entry.id };
        try client.panes.append(gpa, .{
            .id = entry.id,
            .terminal = terminal,
            .render = render,
            .floating = entry.floating,
            .rect = entry.rect,
            .route = route,
        });
    }

    // Pane 1 is overlapped by the float but not covered, so it must still be painted: the frame
    // around the float is exactly what was missing.
    try std.testing.expect(!client.isCovered(client.findPane(1).?));
    // Pane 2 does not touch the float at all.
    try std.testing.expect(!client.isCovered(client.findPane(2).?));

    // A float the size of the pane behind it covers it completely, so it can be skipped.
    client.findPane(3).?.rect = .{ .x = 0, .y = 0, .width = 40, .height = 20 };
    try std.testing.expect(client.isCovered(client.findPane(1).?));

    // A float one column narrower leaves that column to draw, so the pane is not skippable.
    client.findPane(3).?.rect = .{ .x = 0, .y = 0, .width = 39, .height = 20 };
    try std.testing.expect(!client.isCovered(client.findPane(1).?));
}

test "the menu numbers sessions from one, and refuses a number out of range" {
    // The user types a position, not an identifier, so the mapping is the whole contract. Counting
    // from one is what makes zero unusable as a choice, which is what leaves "nothing typed" and
    // "the first session" distinguishable.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        client.session_menu.deinit(gpa);
        client.encoder.deinit();
    }

    try client.session_menu.append(gpa, .{
        .name = try protocol.Name.init("alpha"),
        .rows = 24,
        .cols = 80,
        .clients = 0,
        .pid = 0,
        .running = true,
    });
    try client.session_menu.append(gpa, .{
        .name = try protocol.Name.init("beta"),
        .rows = 24,
        .cols = 80,
        .clients = 0,
        .pid = 0,
        .running = true,
    });

    // Nothing typed yet.
    client.menu_choice = 0;
    try std.testing.expectEqual(@as(?protocol.SessionInfo, null), client.chosenSession());

    // One is the first session, not the second.
    client.menu_choice = 1;
    try std.testing.expectEqualStrings("alpha", client.chosenSession().?.name.slice());

    client.menu_choice = 2;
    try std.testing.expectEqualStrings("beta", client.chosenSession().?.name.slice());

    // Past the end there is nothing, so a mistyped digit selects nothing rather than the last
    // session.
    client.menu_choice = 3;
    try std.testing.expectEqual(@as(?protocol.SessionInfo, null), client.chosenSession());
    client.menu_choice = 99;
    try std.testing.expectEqual(@as(?protocol.SessionInfo, null), client.chosenSession());
}

test "digits typed at the menu build a number" {
    // A list longer than nine needs more than one digit, so the digits accumulate rather than each
    // replacing the last. This mirrors what `handleByte` does with a digit key.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        client.session_menu.deinit(gpa);
        client.encoder.deinit();
    }

    // Twelve sessions, so a two-digit choice is meaningful.
    var index: usize = 0;
    var names: [12]protocol.Name = undefined;
    while (index < 12) : (index += 1) {
        names[index] = try protocol.Name.init(try std.fmt.bufPrint(&names[index].bytes, "s{d}", .{index + 1}));
        try client.session_menu.append(gpa, .{
            .name = names[index],
            .rows = 24,
            .cols = 80,
            .clients = 0,
            .pid = 0,
            .running = true,
        });
    }

    // Typing "1" then "2" is twelve, not two.
    client.menu_choice = 0;
    client.menu_choice = client.menu_choice * 10 + ('1' - '0');
    client.menu_choice = client.menu_choice * 10 + ('2' - '0');
    try std.testing.expectEqual(@as(usize, 12), client.menu_choice);
    try std.testing.expectEqualStrings("s12", client.chosenSession().?.name.slice());
}

test "the scroll mode refuses to open with nothing to scroll" {
    // A mode that opens onto a frozen screen and swallows every key reads as the program hanging.
    // A pane on the alternate screen has no scrollback at all, and one that has printed less than a
    // screenful has none either, so both must leave the mode off.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    // No panes at all: nothing to scroll.
    client.enterScroll();
    try std.testing.expect(!client.scroll_mode);

    // A pane that has printed one line into a five-row terminal has no history.
    var terminal = try vt.Terminal.init(.{ .cols = 20, .rows = 5 });
    errdefer terminal.deinit();
    var render = try terminal.createRenderState();
    errdefer render.deinit();
    const route = try gpa.create(PaneRoute);
    route.* = .{ .client = &client, .pane = 7 };
    try client.panes.append(gpa, .{
        .id = 7,
        .terminal = terminal,
        .render = render,
        .route = route,
    });
    client.focused = 7;

    terminal.write("one line\n");
    try std.testing.expectEqual(@as(usize, 0), client.findPane(7).?.terminal.scrollbackRows());
    client.enterScroll();
    try std.testing.expect(!client.scroll_mode);

    // Once lines have scrolled out of view there is history, so the mode opens.
    var line: usize = 0;
    while (line < 20) : (line += 1) terminal.write("more\n");
    try std.testing.expect(client.findPane(7).?.terminal.scrollbackRows() > 0);
    client.enterScroll();
    try std.testing.expect(client.scroll_mode);
}

test "leaving the scroll mode returns the pane to the live screen" {
    // Leaving the viewport in history would mean the program's next output arrives off-screen and
    // the pane looks stuck, which is worse than not having scrolled at all.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    var terminal = try vt.Terminal.init(.{ .cols = 20, .rows = 5 });
    errdefer terminal.deinit();
    var render = try terminal.createRenderState();
    errdefer render.deinit();
    const route = try gpa.create(PaneRoute);
    route.* = .{ .client = &client, .pane = 3 };
    try client.panes.append(gpa, .{
        .id = 3,
        .terminal = terminal,
        .render = render,
        .route = route,
    });
    client.focused = 3;

    var line: usize = 0;
    while (line < 30) : (line += 1) terminal.write("x\n");

    const pane = client.findPane(3).?;
    try std.testing.expect(pane.terminal.viewportActive());
    client.enterScroll();
    pane.terminal.scrollBy(-5);
    try std.testing.expect(!pane.terminal.viewportActive());

    client.leaveScroll();
    try std.testing.expect(!client.scroll_mode);
    // The viewport is back at the bottom, and the pane is marked for repainting so the screen
    // catches up.
    try std.testing.expect(pane.terminal.viewportActive());
    try std.testing.expect(pane.stale);
}

test "typing ends the scroll mode before the byte is forwarded" {
    // Reading history and typing cannot both be happening: the program's answer would arrive below
    // the viewport and the user would be typing without seeing it.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        for (client.panes.items) |*pane| pane.deinit(gpa);
        client.panes.deinit(gpa);
        client.encoder.deinit();
    }

    var terminal = try vt.Terminal.init(.{ .cols = 20, .rows = 5 });
    errdefer terminal.deinit();
    var render = try terminal.createRenderState();
    errdefer render.deinit();
    const route = try gpa.create(PaneRoute);
    route.* = .{ .client = &client, .pane = 9 };
    try client.panes.append(gpa, .{
        .id = 9,
        .terminal = terminal,
        .render = render,
        .route = route,
    });
    client.focused = 9;
    client.watching = try protocol.Name.init("s");
    var line: usize = 0;
    while (line < 30) : (line += 1) terminal.write("x\n");
    client.enterScroll();
    client.findPane(9).?.terminal.scrollBy(-5);
    try std.testing.expect(client.scroll_mode);
    try std.testing.expect(!client.findPane(9).?.terminal.viewportActive());

    // This is what `handleByte` calls before forwarding a printable byte. It is exercised directly
    // because forwarding needs a socket, and what matters here is the order: the mode ends and the
    // viewport returns, so the program's reply will be visible.
    client.endScrollForInput();

    try std.testing.expect(!client.scroll_mode);
    try std.testing.expect(client.findPane(9).?.terminal.viewportActive());
    try std.testing.expect(client.findPane(9).?.stale);
}

test "a pane's local terminal is the size the server gave its pty" {
    // The two sides have to agree on the pane's width, because wrapping happens on both of them and
    // the reader scrolls this side's history. Building this terminal from the whole rectangle while
    // the server sizes the pty from the interior gives the same pane two widths, so the same output
    // wraps into a different number of rows on each side and the history the reader walks is not the
    // one the program produced.
    const rect = protocol.Rect{ .x = 4, .y = 2, .width = 80, .height = 24 };
    const interior = rect.interior();

    // The sizes must differ, or this test would pass on the broken code by accident.
    try std.testing.expect(interior.width != rect.width);
    try std.testing.expect(interior.height != rect.height);

    var terminal = try vt.Terminal.init(.{
        .cols = interior.width,
        .rows = interior.height,
    });
    defer terminal.deinit();

    try std.testing.expectEqual(interior.width, terminal.cols());
    try std.testing.expectEqual(interior.height, terminal.rows());

    // A stream of numbered lines longer than the screen, which is what a reader scrolls.
    var n: usize = 1;
    var buf: [32]u8 = undefined;
    while (n <= 200) : (n += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "{d}\r\n", .{n}));
    }

    // Every line that has scrolled off is reachable, so the history is the whole stream less the
    // rows still on screen. Losing any of it is what makes a long listing stop part-way.
    // The final newline leaves the cursor on a fresh row rather than scrolling another off, so the
    // history is one row short of the plain difference.
    const expected = 200 - interior.height + 1;
    try std.testing.expectEqual(@as(usize, expected), terminal.scrollbackRows());
}

test "a long run of output is retained in full, not cut short" {
    // The report was that `seq 1 1000` could only be scrolled back to about line 600. A pane whose
    // local terminal is wider than the pty that produced the output wraps the same text into fewer
    // rows, so the history the reader walks is shorter than the one the program wrote, and the
    // older part of it is not reachable at all.
    //
    // Every line here is short, so wrapping is not what loses them; what this pins down is that the
    // count of scrolled-off rows matches the count of lines that went off screen, at the size the
    // pane actually uses.
    const rect = protocol.Rect{ .x = 1, .y = 1, .width = 80, .height = 24 };
    const interior = rect.interior();
    var terminal = try vt.Terminal.init(.{
        .cols = interior.width,
        .rows = interior.height,
    });
    defer terminal.deinit();

    var n: usize = 1;
    var buf: [32]u8 = undefined;
    while (n <= 1000) : (n += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "{d}\r\n", .{n}));
    }

    // A thousand lines printed into a terminal of `interior.height` rows leaves every line above the
    // last screenful in history, which is what makes the first line reachable.
    const history = terminal.scrollbackRows();
    try std.testing.expect(history >= 1000 - interior.height);

    // The oldest content is genuinely there: scrolling to the top brings it into view.
    terminal.scrollToTop();
    try std.testing.expect(!terminal.viewportActive());

    const Probe = struct {
        found_first: bool = false,
        seen: std.ArrayList(u8),
        gpa: std.mem.Allocator,
        fn visit(self: *@This(), row: *vt.RowIterator) bool {
            _ = row.forEachCell(self, collect) catch {};
            return true;
        }
        fn collect(self: *@This(), cell: *vt.CellIterator) void {
            var codepoints: [8]u32 = undefined;
            var utf8: [32]u8 = undefined;
            const bytes = cell.graphemesUtf8(&codepoints, &utf8);
            self.seen.appendSlice(self.gpa, if (bytes.len == 0) " " else bytes) catch {};
        }
    };
    var probe = Probe{ .seen = .empty, .gpa = std.testing.allocator };
    defer probe.seen.deinit(std.testing.allocator);
    var render = try terminal.createRenderState();
    defer render.deinit();
    try render.forEachRow(&probe, Probe.visit);

    const top = std.mem.trim(u8, probe.seen.items, " ");
    // The first rows of the scrollback hold the oldest output, which begins with `1`.
    try std.testing.expect(top.len > 0);
    try std.testing.expect(top[0] == '1');
}

test "an unbound key after the prefix does nothing" {
    // It used to detach. The reasoning was that a prefix followed by a typo should not leave the
    // client in a state where the next byte is eaten, but the prefix is consumed either way, so the
    // next byte is an ordinary keystroke whatever follows it. What detaching actually did was end
    // the client on a mistyped key and lose the session with it. tmux ignores the key.
    const gpa = std.testing.allocator;
    var client: Client = .{
        .gpa = gpa,
        .connection = .{ .fd = -1 },
        .mode = .interactive,
        .encoder = protocol.Encoder.init(gpa),
        .out = undefined,
        .err = undefined,
    };
    defer {
        client.session_menu.deinit(gpa);
        client.encoder.deinit();
    }
    // A session name, so that the old code would have had something to detach from: without one it
    // returned early and the test would pass either way.
    client.watching = try protocol.Name.init("s");

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    // A key the prefix does not use. `g` is bound inside the scroll mode only, so at the top level it
    // is exactly the stray key the report was about.
    _ = try client.handleByte(prefix_key, &payload);
    try std.testing.expect(client.prefix_armed);

    const finished = try client.handleByte('g', &payload);
    try std.testing.expect(!finished);
    try std.testing.expect(!client.finished);
    // The prefix is spent, so the next key is an ordinary one rather than being eaten.
    try std.testing.expect(!client.prefix_armed);

    // And a key typed afterwards still reaches the program.
    payload.clearRetainingCapacity();
    _ = try client.handleByte('a', &payload);
    try std.testing.expectEqualStrings("a", payload.items);
}
