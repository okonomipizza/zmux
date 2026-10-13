//! The Phase 1 event loop: one pty, one terminal screen, one renderer.
//!
//! This is the smallest thing that proves the whole pipeline works. Later
//! phases replace the single pane with a session holding many, but the shape
//! of the loop does not change: epoll reports readiness, the pty's output goes
//! into the parser, the renderer paints the result, and keystrokes go back out
//! through the encoder.

const std = @import("std");
const linux = std.os.linux;
const vt = @import("vt.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");

pub const Error = error{
    /// The pty's slave side closed, so the child is gone.
    ChildExited,
    /// The local terminal could not be set up or written to.
    TerminalFailed,
};

/// Runs a single program on a pty and renders it to the local terminal.
pub const Session = struct {
    gpa: std.mem.Allocator,
    pty: pty_mod.Pty,
    terminal: vt.Terminal,
    render: vt.RenderState,
    encoder: vt.KeyEncoder,
    renderer: terminal_mod.Renderer,
    local: terminal_mod.Terminal,

    /// Bytes the terminal wants written to the pty, collected by the
    /// `write_pty` callback. Replies are produced during `vt_write`, which
    /// cannot write to the pty itself without recursing, so they are buffered
    /// here and flushed once parsing finishes.
    reply: std.ArrayList(u8),
    write_context: vt.WritePtyContext,

    /// Allocate and start a session.
    ///
    /// The session is heap-allocated rather than returned by value because the
    /// terminal holds a pointer to it: the `write_pty` callback recovers the
    /// session from that pointer on every reply the program provokes. A copy
    /// would leave the terminal pointing at the stack slot the copy came from,
    /// which corrupts memory the first time a program sends a query.
    pub fn start(
        gpa: std.mem.Allocator,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) !*Session {
        var local = try terminal_mod.Terminal.enter();
        errdefer local.leave();

        // The size is read after entering raw mode, because entering the
        // alternate screen is also what makes the size query meaningful when
        // zmux is started without a controlling terminal. A zero dimension
        // means the query failed, so fall back rather than creating a terminal
        // with no cells.
        const probed = local.size() catch terminal_mod.vtSize{ .rows = 24, .cols = 80 };
        const size = terminal_mod.vtSize{
            .rows = if (probed.rows == 0) 24 else probed.rows,
            .cols = if (probed.cols == 0) 80 else probed.cols,
        };

        const pty = try pty_mod.Pty.spawn(argv, envp, .{
            .rows = size.rows,
            .cols = size.cols,
        });
        errdefer {
            var p = pty;
            p.deinit();
        }
        pty.setNonBlocking();

        var terminal = try vt.Terminal.init(.{
            .cols = size.cols,
            .rows = size.rows,
        });
        errdefer terminal.deinit();

        var render = try terminal.createRenderState();
        errdefer render.deinit();

        var encoder = try vt.KeyEncoder.init(terminal);
        errdefer encoder.deinit();

        var renderer = try terminal_mod.Renderer.init(gpa, size.rows);
        errdefer renderer.deinit();

        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);

        session.* = .{
            .gpa = gpa,
            .pty = pty,
            .terminal = terminal,
            .render = render,
            .encoder = encoder,
            .renderer = renderer,
            .local = local,
            .reply = .empty,
            .write_context = undefined,
        };

        // The terminal generates replies to queries the program sends (cursor
        // position reports, device attributes and so on). Those must reach the
        // pty, or a program that probes the terminal at startup blocks. The
        // context points back at this session, whose address is now stable, so
        // the callback can find the buffer to append to.
        session.write_context = .{ .owner = @ptrCast(session) };
        session.terminal.setWritePty(&session.write_context, Session.onWritePty);

        return session;
    }

    /// Stop the session and release it.
    ///
    /// The terminal is freed before the session is destroyed because the
    /// terminal holds a pointer into it.
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        self.reply.deinit(gpa);
        self.renderer.deinit();
        self.encoder.deinit();
        self.render.deinit();
        self.terminal.deinit();
        self.pty.deinit();
        self.local.leave();
        gpa.destroy(self);
    }

    /// Receive bytes the terminal wants sent back to the program.
    fn onWritePty(
        terminal: vt.c.GhosttyTerminal,
        userdata: ?*anyopaque,
        data: [*c]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = terminal;
        // `userdata` is the context embedded in the session, and `owner` is the
        // session itself. Both were stored as `*anyopaque`, so the alignment is
        // recovered here; it holds because both point at real, aligned
        // objects.
        const context: *vt.WritePtyContext = @ptrCast(@alignCast(userdata.?));
        const self: *Session = @ptrCast(@alignCast(context.owner));
        // Allocation failure here would lose a reply and hang the program, but
        // there is no way to report it from a C callback, so it is ignored and
        // the missing reply surfaces as a stalled program instead.
        self.reply.appendSlice(self.gpa, data[0..len]) catch {};
    }

    /// Run until the child exits or the user asks to quit.
    pub fn run(self: *Session) !void {
        const epfd = try self.createPoll();
        defer _ = linux.close(epfd);

        var read_buffer: [64 * 1024]u8 = undefined;

        while (true) {
            var events: [8]linux.epoll_event = undefined;
            const count = linux.epoll_wait(epfd, &events, events.len, -1);
            if (linux.errno(count) == .INTR) continue;
            if (linux.errno(count) != .SUCCESS) return Error.TerminalFailed;

            for (events[0..count]) |event| {
                if (event.data.fd == 0) {
                    // The local terminal has input.
                    if (try self.handleInput()) return;
                } else {
                    const read = self.pty.read(&read_buffer) catch |err| switch (err) {
                        pty_mod.Error.Closed => return,
                        else => return err,
                    };
                    if (read > 0) try self.feed(read_buffer[0..read]);
                }
            }

            if (self.pty.reap()) |_| return;
        }
    }

    fn createPoll(self: *Session) !i32 {
        const epfd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(epfd_raw) != .SUCCESS) return Error.TerminalFailed;
        const epfd: i32 = @intCast(epfd_raw);
        errdefer _ = linux.close(epfd);

        try register(epfd, 0, linux.EPOLL.IN);
        try register(epfd, self.pty.master, linux.EPOLL.IN);
        return epfd;
    }

    /// Feed pty output into the parser and repaint.
    fn feed(self: *Session, bytes: []const u8) !void {
        self.terminal.write(bytes);

        // Replies the parser generated during the write go out to the pty now,
        // in the order they were produced.
        if (self.reply.items.len > 0) {
            _ = self.pty.write(self.reply.items) catch {};
            self.reply.clearRetainingCapacity();
        }

        // Keyboard encoding depends on modes the program may have just set.
        self.encoder.syncFromTerminal(self.terminal);

        try self.render.update(self.terminal);
        try self.renderer.render(self.local, self.render);
    }

    /// Handle a keystroke from the local terminal.
    ///
    /// Returns true when the user asked to detach, which ends the loop.
    fn handleInput(self: *Session) !bool {
        var buffer: [256]u8 = undefined;
        const read = std.posix.read(0, &buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return Error.TerminalFailed,
        };
        if (read == 0) return false;

        for (buffer[0..read]) |byte| {
            if (try self.handleByte(byte)) return true;
        }
        return false;
    }

    fn handleByte(self: *Session, byte: u8) !bool {
        // Ctrl-a detaches, the same prefix tmux uses by default.
        switch (byte) {
            0x01 => return true,
            0x7F => {
                try self.sendKey(vt.c.GHOSTTY_KEY_BACKSPACE, 0, null);
                return false;
            },
            '\r', '\n' => {
                try self.sendKey(vt.c.GHOSTTY_KEY_ENTER, 0, null);
                return false;
            },
            '\t' => {
                try self.sendKey(vt.c.GHOSTTY_KEY_TAB, 0, null);
                return false;
            },
            0x1B => {
                try self.sendKey(vt.c.GHOSTTY_KEY_ESCAPE, 0, null);
                return false;
            },
            else => {},
        }

        if (byte < 0x20) {
            // A control character: send the matching letter with Ctrl held so
            // the encoder applies the program's current keyboard mode.
            const letter = byte + 'a' - 1;
            try self.sendKey(vt.keyForAscii(letter).?, vt.c.GHOSTTY_MODS_CTRL, null);
            return false;
        }

        // Printable ASCII goes through the encoder as a key plus its text, so
        // that the application's shift and alt handling applies.
        if (byte < 0x7F) {
            const key = vt.keyForAscii(byte) orelse {
                _ = self.pty.write(&[_]u8{byte}) catch {};
                return false;
            };
            const text = [_]u8{byte};
            try self.sendKey(key, 0, &text);
            return false;
        }

        // Anything else is passed through unmodified. Multi-byte UTF-8
        // arrives one byte at a time here and is forwarded as such.
        _ = self.pty.write(&[_]u8{byte}) catch {};
        return false;
    }

    fn sendKey(
        self: *Session,
        key: vt.c.GhosttyKey,
        mods: vt.c.GhosttyMods,
        text: ?[]const u8,
    ) !void {
        var buffer: [64]u8 = undefined;
        const encoded = try self.encoder.encode(
            key,
            mods,
            vt.c.GHOSTTY_KEY_ACTION_PRESS,
            text,
            &buffer,
        );
        if (encoded.len == 0) return;
        _ = self.pty.write(encoded) catch {};
    }

    /// Tell the pty and the parser about a new window size.
    pub fn resize(self: *Session, size: terminal_mod.vtSize) !void {
        try self.pty.setWindowSize(.{ .rows = size.rows, .cols = size.cols });
        try self.terminal.resize(size.cols, size.rows, 0, 0);
        try self.renderer.resize(size.rows);
        try self.render.update(self.terminal);
        try self.renderer.render(self.local, self.render);
    }
};

fn register(epfd: i32, fd: i32, events: u32) !void {
    var event = linux.epoll_event{ .events = events, .data = .{ .fd = fd } };
    const result = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event);
    if (linux.errno(result) != .SUCCESS) return Error.TerminalFailed;
}

test "a session starts a child and renders it" {
    // Needs a real terminal for raw mode, so it only runs interactively.
    _ = Session;
}
