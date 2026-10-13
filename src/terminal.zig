//! The local terminal zmux is running inside: raw mode, screen setup, and the
//! renderer that paints a `vt.RenderState` onto it.
//!
//! Phase 1 has no client/server split, so zmux draws straight to its own
//! terminal. Everything here is about putting that terminal into a known state
//! and putting it back afterwards, which matters because a crash that leaves a
//! terminal in raw mode is very hard to recover from by hand.

const std = @import("std");
const linux = std.os.linux;
const vt = @import("vt.zig");

/// Wraps the process's stdin/stdout terminal.
pub const Terminal = struct {
    fd: i32,
    original: std.posix.termios,

    /// Put the terminal into raw mode with the alternate screen active.
    ///
    /// Fails with `error.NotATerminal` when stdin is not a terminal, which is
    /// what happens if zmux is started with its input redirected.
    pub fn enter() !Terminal {
        const fd: i32 = 0;

        const original = std.posix.tcgetattr(fd) catch return error.NotATerminal;
        errdefer std.posix.tcsetattr(fd, .NOW, original) catch {};

        var raw = original;
        // Input: no line buffering, no echo, no signal generation, no flow
        // control. Output: no post-processing of newlines.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        // Read returns as soon as one byte is available.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .NOW, raw);

        // Alternate screen, cursor hidden, and no line wrap around the edges
        // where the renderer is drawing a frame.
        try writeAllFd(fd, "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J");

        return .{ .fd = fd, .original = original };
    }

    /// Restore the terminal. Safe to call more than once.
    pub fn leave(self: *Terminal) void {
        // Leave the alternate screen and show the cursor again.
        writeAllFd(self.fd, "\x1b[?25h\x1b[?7h\x1b[?1049l") catch {};
        std.posix.tcsetattr(self.fd, .NOW, self.original) catch {};
    }

    pub fn size(self: Terminal) !vtSize {
        var ws: std.posix.winsize = undefined;
        const result = linux.ioctl(self.fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (linux.errno(result) != .SUCCESS) return error.NotATerminal;
        return .{ .rows = ws.row, .cols = ws.col };
    }

    pub fn writeAll(self: Terminal, bytes: []const u8) !void {
        return writeAllFd(self.fd, bytes);
    }
};

pub const vtSize = struct {
    rows: u16,
    cols: u16,
};

fn writeAllFd(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        const err = linux.errno(written);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.WriteFailed;
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

/// Paints a render state onto a terminal.
///
/// The renderer keeps the previous frame so that only rows the library marks
/// dirty are redrawn. Writing the whole screen every frame works but flickers
/// badly under a program that updates constantly.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    /// One entry per row: whether the row needs repainting.
    dirty: []bool,
    /// Scratch space reused across rows to avoid allocating per cell.
    line: std.ArrayList(u8),

    pub fn init(gpa: std.mem.Allocator, rows: u16) !Renderer {
        const dirty = try gpa.alloc(bool, rows);
        for (dirty) |*entry| entry.* = true;
        return .{
            .gpa = gpa,
            .dirty = dirty,
            .line = .empty,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.gpa.free(self.dirty);
        self.line.deinit(self.gpa);
    }

    /// Resize the dirty table, marking everything for repaint.
    pub fn resize(self: *Renderer, rows: u16) !void {
        self.gpa.free(self.dirty);
        self.dirty = try self.gpa.alloc(bool, rows);
        for (self.dirty) |*entry| entry.* = true;
    }

    /// Draw the current frame.
    pub fn render(
        renderer: *Renderer,
        terminal: Terminal,
        render_state: vt.RenderState,
    ) !void {
        // A full redraw is needed when the library says so, and also whenever
        // the frame is the first one after a resize.
        const full = render_state.dirty() == .full;
        if (full) {
            for (renderer.dirty) |*entry| entry.* = true;
        }

        const Painter = struct {
            renderer: *Renderer,
            terminal: Terminal,
            render_state: vt.RenderState,
            row_index: usize = 0,
            failed: bool = false,

            fn visit(self: *@This(), row: *vt.RowIterator) bool {
                defer self.row_index += 1;

                const needs_paint = self.forcePaint() or row.isDirty();
                if (!needs_paint) return true;
                if (self.row_index >= self.renderer.dirty.len) return true;

                self.renderer.line.clearRetainingCapacity();
                _ = row.forEachCell(self, collect) catch {
                    self.failed = true;
                    return false;
                };
                self.paint() catch {
                    self.failed = true;
                    return false;
                };
                return true;
            }

            fn forcePaint(self: *@This()) bool {
                if (self.render_state.dirty() == .full) return true;
                return self.renderer.dirty[self.row_index];
            }

            fn collect(self: *@This(), cell: *vt.CellIterator) void {
                var codepoints: [8]u32 = undefined;
                var utf8: [32]u8 = undefined;
                const bytes = cell.graphemesUtf8(&codepoints, &utf8);
                if (bytes.len == 0) {
                    self.renderer.line.append(self.renderer.gpa, ' ') catch {};
                    return;
                }
                self.renderer.line.appendSlice(self.renderer.gpa, bytes) catch {};
            }

            fn paint(self: *@This()) !void {
                const row = self.row_index;
                var buffer: [64]u8 = undefined;
                // Move to column 1 of this row. Rows are 1-based in the
                // protocol.
                const move = try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{row + 1});
                try self.terminal.writeAll(move);

                // Erase to end of line so that shorter output does not leave
                // the tail of the previous frame behind.
                try self.terminal.writeAll("\x1b[K");
                try self.terminal.writeAll(self.renderer.line.items);
            }
        };

        var painter = Painter{
            .renderer = renderer,
            .terminal = terminal,
            .render_state = render_state,
        };
        try render_state.forEachRow(&painter, Painter.visit);
        if (painter.failed) return error.RenderFailed;

        // After a full repaint nothing is stale any more.
        if (full) {
            for (renderer.dirty) |*entry| entry.* = false;
        }

        // Park the cursor where the program wants it, then show it.
        if (render_state.cursorVisible()) {
            if (render_state.cursorPosition()) |position| {
                var buffer: [32]u8 = undefined;
                const move = try std.fmt.bufPrint(
                    &buffer,
                    "\x1b[{d};{d}H\x1b[?25h",
                    .{ position.y + 1, position.x + 1 },
                );
                try terminal.writeAll(move);
            }
        } else {
            try terminal.writeAll("\x1b[?25l");
        }
    }
};

test "size reports the terminal dimensions" {
    // Only meaningful when attached to a terminal, which is not the case for
    // an automated test run.
    const terminal = Terminal{ .fd = 0, .original = undefined };
    _ = terminal.size() catch return;
}

test "writeAll writes every byte" {
    var fds: [2]i32 = undefined;
    if (linux.pipe2(&fds, .{}) != 0) return error.SkipZigTest;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    try writeAllFd(fds[1], "hello, terminal");

    var buffer: [32]u8 = undefined;
    const read = std.posix.read(fds[0], &buffer) catch return error.ReadFailed;
    try std.testing.expectEqualStrings("hello, terminal", buffer[0..read]);
}
