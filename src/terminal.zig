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

/// Draws a one-row status line along the bottom of the terminal.
///
/// The row is *reserved*, not overlaid: the session's terminal is one row shorter
/// than the window, so no program ever draws underneath this and nothing is
/// covered up. tmux and screen make the same choice, and for the same reason — a
/// full-screen editor uses every row it is given, so an overlay would hide real
/// output.
///
/// The line is drawn in inverse video so that it reads as chrome rather than as
/// part of the program's output.
/// Writes the escape sequence that puts a terminal into a given style.
///
/// Colour is what makes a terminal usable: a shell colours its prompt, an editor colours syntax, and
/// a shell's autosuggestion is drawn in a dimmed colour that is the only thing distinguishing it
/// from what the user has already typed. Dropping the style makes all of those read as
/// undifferentiated text.
///
/// Each sequence starts from a reset (`0`) rather than being a delta from the previous cell's style.
/// A delta would be shorter but needs the previous style tracked across rows and panes, and getting
/// it wrong bleeds a colour into the rest of the screen. The reset costs a few bytes per styled cell
/// and cannot be wrong.
pub const SgrWriter = struct {
    /// Append the sequence for `style` to `buffer`.
    ///
    /// A default style writes nothing, because a cell with no styling should inherit whatever the
    /// terminal is already doing rather than being forced to something explicit. That also keeps the
    /// common case, a screenful of plain text, free of escapes.
    ///
    /// A colour the cell does not set is written as the terminal's *default* (39 or 49) rather than
    /// as an RGB value. zmux does not know the user's palette, so guessing white-on-black would
    /// override the theme the terminal was configured with; and the reset clears the attributes but
    /// does not by itself restore the default colour.
    pub fn write(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, style: vt.Style) !void {
        if (style.isDefault()) return;

        try buffer.appendSlice(gpa, "\x1b[0");

        if (style.bold) try buffer.appendSlice(gpa, ";1");
        if (style.faint) try buffer.appendSlice(gpa, ";2");
        if (style.italic) try buffer.appendSlice(gpa, ";3");
        if (style.underline) try buffer.appendSlice(gpa, ";4");
        if (style.blink) try buffer.appendSlice(gpa, ";5");
        if (style.inverse) try buffer.appendSlice(gpa, ";7");
        if (style.invisible) try buffer.appendSlice(gpa, ";8");
        if (style.strikethrough) try buffer.appendSlice(gpa, ";9");

        if (style.fg) |colour| {
            try writeColor(buffer, gpa, 38, colour);
        } else {
            try buffer.appendSlice(gpa, ";39");
        }

        if (style.bg) |colour| {
            try writeColor(buffer, gpa, 48, colour);
        } else {
            try buffer.appendSlice(gpa, ";49");
        }

        try buffer.append(gpa, 'm');
    }

    /// Write one colour as a 24-bit value.
    ///
    /// Truecolor is used rather than the nearest palette entry. The library has already resolved
    /// palette indices to RGB, so the colour is exact, and a terminal running zmux supports 24-bit
    /// colour; quantising here would throw away information that was handed to us.
    ///
    /// The parameter is the whole introducer, 38 or 48, not its leading digit. The extended-colour
    /// form is `38;2;r;g;b`, where the `2` is a separate field; writing `3` and then a literal `2`
    /// produces `3;2;r;g;b`, which is the 8-colour form with stray parameters and draws a different
    /// colour than intended.
    fn writeColor(
        buffer: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        introducer: u8,
        colour: vt.Rgb,
    ) !void {
        var sequence: [32]u8 = undefined;
        const text = std.fmt.bufPrint(
            &sequence,
            ";{d};2;{d};{d};{d}",
            .{ introducer, colour.r, colour.g, colour.b },
        ) catch return;
        try buffer.appendSlice(gpa, text);
    }
};

pub const StatusLine = struct {
    /// A scratch buffer for composing the row, reused between frames.
    buffer: std.ArrayList(u8) = .empty,

    pub fn init() StatusLine {
        return .{};
    }

    pub fn deinit(self: *StatusLine, gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
    }

    /// Paint the status row.
    ///
    /// `row` is zero-based and is the last row of the window. The text is
    /// truncated rather than wrapped, because a wrapped status line would push
    /// the terminal's own scroll region around.
    pub fn render(
        self: *StatusLine,
        gpa: std.mem.Allocator,
        terminal: Terminal,
        row: u16,
        text: []const u8,
        cols: u16,
    ) !void {
        var buffer = &self.buffer;
        buffer.clearRetainingCapacity();

        // Move to the row, erase it, then draw inverse video. The list's own
        // `print` is used rather than a writer: `ArrayList.writer` does not exist
        // in Zig 0.16, and the list takes the allocator per call instead.
        try buffer.print(gpa, "\x1b[{d};1H\x1b[K\x1b[7m", .{row + 1});

        // Truncating here rather than letting the terminal wrap keeps the layout
        // predictable. The column count is authoritative.
        const visible = if (text.len > cols) text[0..cols] else text;
        try buffer.appendSlice(gpa, visible);

        // Pad to the full width so the inverse background covers the row.
        var written: usize = visible.len;
        while (written < cols) : (written += 1) try buffer.append(gpa, ' ');

        try buffer.appendSlice(gpa, "\x1b[0m");
        try terminal.writeAll(buffer.items);
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

test "a default style writes nothing at all" {
    // Most cells are unstyled, and a screenful of plain text should not carry an escape per cell.
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    try SgrWriter.write(&buffer, gpa, .{});
    try std.testing.expectEqualStrings("", buffer.items);
}

test "colours are written as truecolor with the whole introducer" {
    // 38 and 48, not 3 and 4: the extended form is `38;2;r;g;b` and the 2 is a separate field.
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    try SgrWriter.write(
        &buffer,
        gpa,
        .{ .fg = .{ .r = 1, .g = 2, .b = 3 }, .bg = .{ .r = 4, .g = 5, .b = 6 } },
    );

    try std.testing.expectEqualStrings("\x1b[0;38;2;1;2;3;48;2;4;5;6m", buffer.items);
}

test "a colour the cell does not set falls back to the terminal default" {
    // 39 and 49, not an RGB guess: zmux does not know the user's theme, and the reset alone does not
    // restore the default colour.
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    try SgrWriter.write(&buffer, gpa, .{ .bold = true });
    try std.testing.expectEqualStrings("\x1b[0;1;39;49m", buffer.items);
}

test "only the set colour falls back" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    try SgrWriter.write(&buffer, gpa, .{ .fg = .{ .r = 255, .g = 0, .b = 0 } });
    try std.testing.expectEqualStrings("\x1b[0;38;2;255;0;0;49m", buffer.items);
}

test "attributes are written in one sequence, in a fixed order" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    try SgrWriter.write(&buffer, gpa, .{
        .bold = true,
        .faint = true,
        .italic = true,
        .underline = true,
        .blink = true,
        .inverse = true,
        .invisible = true,
        .strikethrough = true,
    });

    try std.testing.expectEqualStrings("\x1b[0;1;2;3;4;5;7;8;9;39;49m", buffer.items);
}

test "a style is not default when only a colour is set" {
    // `isDefault` decides whether an escape is written at all, so a colour alone must make it false
    // or every coloured cell would be drawn in the default colour.
    try std.testing.expect(!(vt.Style{ .fg = .{ .r = 1, .g = 2, .b = 3 } }).isDefault());
    try std.testing.expect(!(vt.Style{ .bg = .{ .r = 1, .g = 2, .b = 3 } }).isDefault());
    try std.testing.expect(!(vt.Style{ .underline = true }).isDefault());
    try std.testing.expect((vt.Style{}).isDefault());
}
