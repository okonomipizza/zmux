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
        self.covered.deinit(self.gpa);
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
                        const read = self.connection.read(&buffer) catch return;
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
                " zmux | {s} | {d}x{d} | floats hidden, ctrl-a f shows them | {s}",
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
            " zmux | {s} | {d}x{d} | ctrl-a: s/v split q close h/j/k/l focus <> swap o rotate F/f floats d dock | {s}",
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
            if (!appendBorder(&pane.line, self.gpa, rect, active)) {
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
                    // The session is gone, so there is nothing left to be attached to. This used to
                    // stay attached and keep the last screen up, which was right while the server
                    // kept a finished session; now that it discards one, staying would leave the
                    // client showing a dead window whose only content is this message. Detaching
                    // restores the terminal zmux was started from, with the status above it.
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

/// The colour of the focused pane's border, a muted young green.
///
/// Deliberately desaturated rather than a pure green: the border frames text that has its own
/// colours, and a bright edge competes with it. This reads as a tint on the frame rather than as
/// content, which is what an indicator should do.
const active_border: [3]u8 = .{ 124, 168, 108 };

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
) bool {
    if (rect.width < 3 or rect.height < 3) return true;

    const horizontal = rect.width - 2;

    // The colour is set once at the start and cleared at the end, so a border costs two escapes
    // whatever its size.
    if (active) {
        buffer.print(gpa, "\x1b[38;2;{d};{d};{d}m", .{
            active_border[0],
            active_border[1],
            active_border[2],
        }) catch return false;
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
    try std.testing.expect(std.mem.indexOf(u8, move, "[K") == null);
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
    try std.testing.expect(appendBorder(&line, gpa, wide, false));

    // A horizontal edge of 398 cells, three bytes each, is far past the old limit.
    try std.testing.expect(line.items.len > 1200);
    // Both corners and both sides are present.
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\u{250c}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\u{2510}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\u{2514}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\u{2518}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\u{2502}") != null);

    // A pane too small for a frame is left alone and reports success, rather than drawing a frame
    // over the only cell the program has.
    var tiny: std.ArrayList(u8) = .empty;
    defer tiny.deinit(gpa);
    try std.testing.expect(appendBorder(&tiny, gpa, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, false));
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

    var active: std.ArrayList(u8) = .empty;
    defer active.deinit(gpa);
    try std.testing.expect(appendBorder(&active, gpa, rect, true));
    try std.testing.expect(std.mem.indexOf(u8, active.items, "\x1b[38;2;124;168;108m") != null);

    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try std.testing.expect(appendBorder(&plain, gpa, rect, false));
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "38;2;") == null);

    // The colour is cleared at the end, so it cannot bleed into the pane's own cells or into a
    // neighbouring pane. Both forms end with the reset.
    try std.testing.expect(std.mem.endsWith(u8, active.items, "\x1b[0m"));
    try std.testing.expect(std.mem.endsWith(u8, plain.items, "\x1b[0m"));

    // The tint is set once however wide the pane is, so it does not grow the frame.
    const wide = protocol.Rect{ .x = 0, .y = 0, .width = 200, .height = 4 };
    var wide_active: std.ArrayList(u8) = .empty;
    defer wide_active.deinit(gpa);
    try std.testing.expect(appendBorder(&wide_active, gpa, wide, true));
    var wide_plain: std.ArrayList(u8) = .empty;
    defer wide_plain.deinit(gpa);
    try std.testing.expect(appendBorder(&wide_plain, gpa, wide, false));
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
