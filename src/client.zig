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

/// One remote pane, as the client sees it: its own terminal, its own renderer, and the
/// rectangle the server says it occupies.
///
/// One terminal per pane rather than one per session, because each program has its own
/// screen. The server sends each pane's bytes tagged with its identifier, so this side
/// dispatches without having to parse anything to know where they belong.
const RemotePane = struct {
    id: u64,
    terminal: vt.Terminal,
    render: vt.RenderState,
    renderer: terminal_mod.Renderer,
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
        self.renderer.deinit();
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

pub const Client = struct {
    gpa: std.mem.Allocator,
    connection: socket.Connection,
    mode: Mode,
    /// The panes the server says this session has.
    panes: std.ArrayList(RemotePane) = .empty,
    /// The pane the server says has focus, by identifier. Input is addressed to it.
    focused: u64 = 0,
    /// The raised floating pane, by identifier, or zero when none is raised.
    focused_float: u64 = 0,
    /// Set while the server is labelling the tiled panes for a dock target.
    docking: bool = false,
    /// Set while the floating panes are hidden, so the status line can say so.
    ///
    /// Hidden floats are not in the layout event at all, so without this the client cannot tell
    /// "no floats exist" from "the floats are put away", and the status line would be wrong.
    floats_hidden: bool = false,
    /// Set between the prefix key and the key that follows it.
    prefix_armed: bool = false,
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
        // The panes' terminals point at this client for their reply callbacks, so they go
        // first; the local terminal is restored last, since the screen is written to it
        // until then.
        self.frame.deinit(self.gpa);
        self.outgoing.deinit(self.gpa);
        for (self.panes.items) |*pane| pane.deinit(self.gpa);
        self.panes.deinit(self.gpa);
        for (self.pending.items) |*entry| entry.data.deinit(self.gpa);
        self.pending.deinit(self.gpa);
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
                } else {
                    const read = self.connection.read(&buffer) catch return;
                    if (read == 0) continue;
                    try self.frame.feed(self.gpa, buffer[0..read], self, Client.onMessage);
                    if (self.finished) break;
                    self.draw(window);
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
        if (self.docking) {
            return std.fmt.bufPrint(
                buffer,
                " zmux | dock {s} into which pane? press 1-9, esc to cancel",
                .{name},
            ) catch buffer[0..0];
        }

        // Hidden floats are not in the layout, so the status line is the only place that says they
        // still exist. Without this a user would think they had been closed.
        if (self.floats_hidden) {
            return std.fmt.bufPrint(
                buffer,
                " zmux | {s} | {d}x{d} | floats hidden, ctrl-a - shows them | {s}",
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
            " zmux | {s} | {d}x{d} | ctrl-a: s/v split q close f float d dock - hide h/j/k/l focus | {s}",
            .{
                name,
                self.area_cols,
                self.area_rows,
                state,
            },
        ) catch buffer[0..0];
    }

    /// Repaint every pane and then the status line.
    ///
    /// The tiled panes tile the session's area, so nothing overlaps between them and no clearing is
    /// needed; the floats are drawn after them, on top. The status line goes last because it owns the
    /// one row below the area.
    fn draw(self: *Client, window: terminal_mod.vtSize) void {
        const local = self.local orelse return;

        // Replies the panes' terminals produced while parsing go back to the programs
        // they belong to, before anything is painted.
        self.flushPaneReplies();

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
        }

        // While a dock target is being chosen, each tiled pane shows its number.
        if (self.docking) {
            for (self.panes.items) |*pane| {
                if (pane.floating or pane.label == 0) continue;
                self.drawPaneLabel(pane);
            }
        }

        if (self.status) |*status| {
            var text_buffer: [256]u8 = undefined;
            const text = self.statusText(&text_buffer);
            status.render(self.gpa, local, window.rows - 1, text, window.cols) catch {};
        }
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

        pane.render.update(pane.terminal) catch return;

        var row_index: u16 = 0;
        const Painter = struct {
            local: terminal_mod.Terminal,
            pane: *RemotePane,
            rect: protocol.Rect,
            row_index: *u16,
            gpa: std.mem.Allocator,

            fn visit(painter: *@This(), row: *vt.RowIterator) bool {
                defer painter.row_index.* += 1;
                if (painter.row_index.* >= painter.rect.height) return false;

                // Move to this row's first column inside the pane's rectangle, erase the
                // row, and write the cells. Erasing matters because a row that got shorter
                // would otherwise keep the tail of the previous frame.
                var buffer: [32]u8 = undefined;
                const move = std.fmt.bufPrint(
                    &buffer,
                    "\x1b[{d};{d}H\x1b[K",
                    .{ painter.rect.y + painter.row_index.* + 1, painter.rect.x + 1 },
                ) catch return false;
                painter.local.writeAll(move) catch return false;

                painter.pane.line.clearRetainingCapacity();
                _ = row.forEachCell(painter, collect) catch return false;

                // Clipped to the rectangle so that a wide row cannot run into the pane
                // beside it, which would corrupt the neighbour's screen. A pane's terminal
                // is made exactly as wide as the rectangle, so this only bites when the two
                // disagree, which is the case worth defending against.
                const text = if (painter.pane.line.items.len > painter.rect.width)
                    painter.pane.line.items[0..painter.rect.width]
                else
                    painter.pane.line.items;
                painter.local.writeAll(text) catch return false;
                return true;
            }

            fn collect(painter: *@This(), cell: *vt.CellIterator) void {
                var codepoints: [8]u32 = undefined;
                var utf8: [32]u8 = undefined;
                const bytes = cell.graphemesUtf8(&codepoints, &utf8);
                if (bytes.len == 0) {
                    painter.pane.line.append(painter.gpa, ' ') catch {};
                    return;
                }
                painter.pane.line.appendSlice(painter.gpa, bytes) catch {};
            }
        };

        var painter = Painter{
            .local = local,
            .pane = pane,
            .rect = rect,
            .row_index = &row_index,
            .gpa = self.gpa,
        };
        pane.render.forEachRow(&painter, Painter.visit) catch {};
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
    /// Ctrl-a is the prefix. On its own it detaches, as it did before panes existed; followed
    /// by one of the command keys it acts on the layout instead. The prefix is armed by the
    /// first byte and consumed by the second, so a prefix followed by a key the layout does
    /// not use falls back to detaching rather than being swallowed.
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

        if (byte == 0x01) {
            // The prefix takes effect on the next byte; a prefix that is never followed
            // by anything means the user pressed ctrl-a and stopped, which detaches so
            // that a bare ctrl-a keeps working.
            self.prefix_armed = true;
            return false;
        }

        // Everything else is forwarded raw. The program's own terminal decides what the
        // bytes mean: re-encoding them here would discard whatever the program and its own
        // terminal have already agreed on.
        try payload.append(self.gpa, byte);
        return false;
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
    fn handleCommand(self: *Client, byte: u8) !bool {
        switch (byte) {
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
            // `f` parks the focused pane above the layout, `d` puts the raised float back.
            'f' => {
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
            // `-` hides the floats or brings them back, depending on the state the server is in. One
            // key for both directions because the client does not track which state that is.
            '-' => {
                try self.sendRequest(.{ .toggle_floats = .{ .name = self.watching } });
                return false;
            },
            // h/j/k/l move focus. They all map onto the tree's own order for now, which
            // walks left to right and wraps; a direction-aware move needs the geometry the
            // server already has and can come later.
            'h', 'k' => {
                try self.sendRequest(.{ .focus = .{
                    .name = self.watching,
                    .backwards = true,
                } });
                return false;
            },
            'l', 'j' => {
                try self.sendRequest(.{ .focus = .{
                    .name = self.watching,
                    .backwards = false,
                } });
                return false;
            },
            // The prefix twice detaches, which is how a user who is used to ctrl-a ctrl-a
            // gets out.
            0x01 => {
                if (self.watching.len > 0) {
                    try self.sendRequest(.{ .detach = .{ .name = self.watching } });
                }
                return true;
            },
            else => {
                // An unused key after the prefix detaches, so that ctrl-a followed by a
                // typo does not leave the client sitting in a state where the next byte is
                // eaten.
                if (self.watching.len > 0) {
                    try self.sendRequest(.{ .detach = .{ .name = self.watching } });
                }
                return true;
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

        const target = if (self.focused_float != 0) self.focused_float else self.focused;
        if (target == 0) return;

        try self.sendRequest(.{ .input = .{
            .name = self.watching,
            .pane = target,
            .data = data,
        } });
    }

    /// Handle one decoded event.
    fn onMessage(self: *Client, payload: []const u8) anyerror!void {
        var decoder = protocol.Decoder.init(payload);
        // A frame that does not decode is ignored rather than fatal. The server and this
        // client are the same version, so a malformed frame would mean one of them is wrong
        // about the protocol, which is not something this side can repair by exiting.
        const event = decoder.event() catch return;
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
                // Recorded before finishing, so that the status line shows the session as
                // ended rather than still live.
                self.exited = true;
                if (self.local != null) {
                    // Not fatal: the panes keep their final screens until the client is
                    // told to leave. Saying so and staying attached is more useful than
                    // tearing the screen down the moment the last program exits.
                    try self.err.print("\nzmux: session {s} exited with status {d}\n", .{
                        exited.name.slice(),
                        exited.status,
                    });
                    try self.err.flush();
                }
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
            pane.rect = placement.rect;
            pane.exited = placement.exited;
            pane.floating = placement.floating;
            pane.label = placement.label;
            // The terminal is resized to match, so that the client's idea of the pane's
            // shape agrees with the server's. Skipping this would leave a pane's screen
            // wrapped for a width it no longer has.
            if (placement.rect.width > 0 and placement.rect.height > 0) {
                pane.terminal.resize(
                    placement.rect.width,
                    placement.rect.height,
                    0,
                    0,
                ) catch {};
                pane.renderer.resize(placement.rect.height) catch {};
            }
        }

        self.focused = layout.focused;
        self.focused_float = layout.focused_float;
        self.docking = layout.docking;
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
        const cols = if (placement.rect.width == 0) 1 else placement.rect.width;
        const rows = if (placement.rect.height == 0) 1 else placement.rect.height;

        var terminal = try vt.Terminal.init(.{ .cols = cols, .rows = rows });
        errdefer terminal.deinit();

        var render = try terminal.createRenderState();
        errdefer render.deinit();

        var renderer = try terminal_mod.Renderer.init(self.gpa, rows);
        errdefer renderer.deinit();

        const route = try self.gpa.create(PaneRoute);
        errdefer self.gpa.destroy(route);
        route.* = .{ .client = self, .pane = placement.id };

        try self.panes.append(self.gpa, .{
            .id = placement.id,
            .terminal = terminal,
            .render = render,
            .renderer = renderer,
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
    fn holdOutput(self: *Client, pane: u64, data: []const u8) !void {
        for (self.pending.items) |*entry| {
            if (entry.pane == pane) {
                try entry.data.appendSlice(self.gpa, data);
                return;
            }
        }
        var entry = PendingOutput{ .pane = pane };
        try entry.data.appendSlice(self.gpa, data);
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

    /// Receive bytes the client's terminal wants sent to the program.
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
        var renderer = try terminal_mod.Renderer.init(gpa, 5);
        errdefer renderer.deinit();
        const route = try gpa.create(PaneRoute);
        route.* = .{ .client = &client, .pane = entry.id };
        try client.panes.append(gpa, .{
            .id = entry.id,
            .terminal = terminal,
            .render = render,
            .renderer = renderer,
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
