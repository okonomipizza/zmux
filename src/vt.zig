//! Thin Zig wrapper over libghostty-vt's C API.
//!
//! zmux delegates escape sequence parsing, screen state, reflow and
//! scrollback to Ghostty's VT library. This module is the single place that
//! knows about the C ABI, so the rest of the codebase can work with plain Zig
//! types and explicit error handling.

const std = @import("std");

pub const c = @cImport({
    @cInclude("ghostty/vt.h");
});

pub const Error = error{
    /// libghostty-vt reported a failure for the requested operation.
    GhosttyFailure,
    /// The caller passed something libghostty-vt rejected as invalid.
    InvalidValue,
    /// An output buffer was too small for the value being read.
    OutOfSpace,
};

fn check(result: c.GhosttyResult) Error!void {
    return switch (result) {
        c.GHOSTTY_SUCCESS => {},
        c.GHOSTTY_OUT_OF_SPACE => Error.OutOfSpace,
        c.GHOSTTY_INVALID_VALUE => Error.InvalidValue,
        else => Error.GhosttyFailure,
    };
}

/// A terminal screen: the parsed state of one VT byte stream.
///
/// This owns no file descriptor. A pane pairs one `Terminal` with one pty.
pub const Terminal = struct {
    handle: c.GhosttyTerminal,

    pub const Options = struct {
        cols: u16,
        rows: u16,
        /// Maximum lines retained in scrollback history.
        max_scrollback: usize = 10_000,
    };

    pub fn init(options: Options) Error!Terminal {
        std.debug.assert(options.cols > 0);
        std.debug.assert(options.rows > 0);

        var handle: c.GhosttyTerminal = null;
        try check(c.ghostty_terminal_new(null, &handle, options.cols, options.rows));
        errdefer c.ghostty_terminal_free(handle);

        const terminal = Terminal{ .handle = handle };

        // Scrollback is a post-creation option rather than a constructor
        // argument. A NULL pointer would remove the limit entirely, so this is
        // passed by address.
        var max_lines = options.max_scrollback;
        _ = c.ghostty_terminal_set(
            terminal.handle,
            c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            &max_lines,
        );

        return terminal;
    }

    pub fn deinit(self: *Terminal) void {
        c.ghostty_terminal_free(self.handle);
        self.handle = null;
    }

    /// Feed raw bytes read from a pty into the parser.
    ///
    /// Sequences that provoke a reply (device status reports, cursor position
    /// reports, mode reports) are not written back here; they arrive through
    /// the `write_pty` callback registered with `setWritePty`.
    pub fn write(self: Terminal, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    pub fn resize(
        self: Terminal,
        new_cols: u16,
        new_rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) Error!void {
        try check(c.ghostty_terminal_resize(
            self.handle,
            new_cols,
            new_rows,
            cell_width_px,
            cell_height_px,
        ));
    }

    /// Install the callback that receives replies the terminal generates for
    /// the application, such as cursor position reports.
    ///
    /// This must be wired up before the first `write`, or programs that probe
    /// the terminal at startup will block waiting for a reply.
    ///
    /// `context` is passed back to `write` on every call. The caller must keep
    /// it alive for as long as the terminal is used.
    pub fn setWritePty(self: Terminal, context: *WritePtyContext, callback: WritePtyFn) void {
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_USERDATA, context);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(callback));
    }

    /// Ask libghostty-vt whether the application enabled a terminal mode.
    ///
    /// zmux uses this to decide whether mouse events belong to the program
    /// running in the pane or to zmux's own pane handling.
    pub fn modeEnabled(self: Terminal, mode: c.GhosttyMode) Error!bool {
        // The caller fills in the mode and the library fills in the value.
        var config: c.GhosttyTerminalModeConfig = .{ .mode = mode, .value = false };
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &config));
        return config.value;
    }

    /// Whether the application asked for mouse reports in any tracking mode.
    pub fn wantsMouse(self: Terminal) bool {
        const tracking_modes = [_]u16{ 9, 1000, 1002, 1003 };
        for (tracking_modes) |value| {
            const enabled = self.modeEnabled(decMode(value)) catch continue;
            if (enabled) return true;
        }
        return false;
    }

    pub fn cols(self: Terminal) u16 {
        var value: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLS, &value);
        return value;
    }

    pub fn rows(self: Terminal) u16 {
        var value: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ROWS, &value);
        return value;
    }

    pub fn cursorVisible(self: Terminal) bool {
        var value: bool = false;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &value);
        return value;
    }

    /// The terminal title as set by OSC 0/2, or an empty slice.
    ///
    /// The returned slice is borrowed and only valid until the next call that
    /// mutates the terminal.
    pub fn title(self: Terminal) []const u8 {
        var value: c.GhosttyString = .{ .ptr = null, .len = 0 };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_TITLE, &value);
        if (value.ptr == null or value.len == 0) return "";
        return value.ptr[0..value.len];
    }

    /// Create a render state that tracks this terminal's screen.
    pub fn createRenderState(self: Terminal) Error!RenderState {
        return RenderState.init(self);
    }
};

/// Context that libghostty-vt passes back to the `write_pty` callback.
///
/// A pane embeds this and recovers its own type with `@fieldParentPtr`, which
/// is how the callback reaches the pty to write the reply to.
pub const WritePtyContext = struct {
    /// The pane that owns the terminal, or any other value the callback needs.
    owner: *anyopaque,
};

/// Signature of the `write_pty` callback that libghostty-vt invokes.
///
/// `userdata` is the `WritePtyContext` passed to `Terminal.setWritePty`.
pub const WritePtyFn = *const fn (
    terminal: c.GhosttyTerminal,
    userdata: ?*anyopaque,
    data: [*c]const u8,
    len: usize,
) callconv(.c) void;

/// The drawable state of a terminal, updated incrementally.
pub const RenderState = struct {
    handle: c.GhosttyRenderState,

    pub fn init(terminal: Terminal) Error!RenderState {
        var handle: c.GhosttyRenderState = null;
        try check(c.ghostty_render_state_new(null, &handle));
        errdefer c.ghostty_render_state_free(handle);

        try check(c.ghostty_render_state_update(handle, terminal.handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RenderState) void {
        c.ghostty_render_state_free(self.handle);
        self.handle = null;
    }

    /// Refresh from the terminal. Call once per frame before reading.
    pub fn update(self: RenderState, terminal: Terminal) Error!void {
        try check(c.ghostty_render_state_update(self.handle, terminal.handle));
    }

    /// How much of the frame changed since the previous update.
    pub fn dirty(self: RenderState) Dirty {
        var value: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
        _ = c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &value);
        return switch (value) {
            c.GHOSTTY_RENDER_STATE_DIRTY_FALSE => .clean,
            c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL => .partial,
            else => .full,
        };
    }

    pub fn cursorVisible(self: RenderState) bool {
        var value: bool = false;
        _ = c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &value);
        return value;
    }

    /// Cursor position in viewport coordinates, or null when the cursor is
    /// scrolled out of view.
    pub fn cursorPosition(self: RenderState) ?struct { x: u16, y: u16 } {
        var in_viewport: bool = false;
        _ = c.ghostty_render_state_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &in_viewport,
        );
        if (!in_viewport) return null;

        var x: u16 = 0;
        var y: u16 = 0;
        _ = c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
        _ = c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
        return .{ .x = x, .y = y };
    }

    /// Iterate the viewport rows, invoking `visitor` for each one.
    ///
    /// `visitor` receives a row iterator to read row-local data and cells.
    /// Returning `false` stops the walk early.
    pub fn forEachRow(
        self: RenderState,
        context: anytype,
        comptime visitor: fn (@TypeOf(context), *RowIterator) bool,
    ) Error!void {
        var iter: c.GhosttyRenderStateRowIterator = null;
        try check(c.ghostty_render_state_row_iterator_new(null, &iter));
        defer c.ghostty_render_state_row_iterator_free(iter);

        try check(c.ghostty_render_state_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            @ptrCast(&iter),
        ));

        var row = RowIterator{ .handle = iter };
        while (c.ghostty_render_state_row_iterator_next(iter)) {
            if (!visitor(context, &row)) return;
        }
    }
};

pub const Dirty = enum { clean, partial, full };

/// Pack a DEC private mode number into the representation libghostty-vt uses.
///
/// `modes.h` documents the layout as a 15-bit mode value with bit 15 clear for
/// DEC private modes. The `GHOSTTY_MODE_*` convenience macros cannot be used
/// from Zig because they expand to a call to a non-comptime inline function.
pub fn decMode(value: u16) c.GhosttyMode {
    std.debug.assert(value <= 0x7FFF);
    return value;
}

/// Pack an ANSI (non-private) mode number.
pub fn ansiMode(value: u16) c.GhosttyMode {
    std.debug.assert(value <= 0x7FFF);
    return value | 0x8000;
}

pub const RowIterator = struct {
    handle: c.GhosttyRenderStateRowIterator,

    pub fn isDirty(self: RowIterator) bool {
        var value: bool = false;
        _ = c.ghostty_render_state_row_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
            &value,
        );
        return value;
    }

    /// Walk the cells of this row, invoking `visitor` for each one.
    pub fn forEachCell(
        self: RowIterator,
        context: anytype,
        comptime visitor: fn (@TypeOf(context), *CellIterator) void,
    ) Error!void {
        var cells: c.GhosttyRenderStateRowCells = null;
        try check(c.ghostty_render_state_row_cells_new(null, &cells));
        defer c.ghostty_render_state_row_cells_free(cells);

        try check(c.ghostty_render_state_row_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
            @ptrCast(&cells),
        ));

        var cell = CellIterator{ .handle = cells };
        while (c.ghostty_render_state_row_cells_next(cells)) {
            visitor(context, &cell);
        }
    }
};

pub const CellIterator = struct {
    handle: c.GhosttyRenderStateRowCells,

    /// The number of grapheme codepoints in this cell, including the base.
    ///
    /// Zero means the cell holds no text and should be drawn as blank.
    pub fn graphemeLen(self: CellIterator) u32 {
        var value: u32 = 0;
        _ = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &value,
        );
        return value;
    }

    /// UTF-8 bytes of the grapheme in this cell, or an empty slice when the
    /// cell is blank.
    ///
    /// `codepoints` is scratch space for the raw cluster and must hold at
    /// least `graphemeLen()` entries. `buffer` receives the encoded bytes, so
    /// it must be at least three times the length of `codepoints`.
    pub fn graphemesUtf8(self: CellIterator, codepoints: []u32, buffer: []u8) []const u8 {
        const count = self.graphemeLen();
        if (count == 0) return "";

        const to_read = @min(count, codepoints.len);
        _ = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
            codepoints.ptr,
        );

        var written: usize = 0;
        for (codepoints[0..to_read]) |codepoint| {
            const encoded = std.unicode.utf8Encode(@intCast(codepoint), buffer[written..]) catch return "";
            written += encoded;
        }
        return buffer[0..written];
    }

    /// The style SGR attributes of this cell, such as bold and underline.
    pub fn style(self: CellIterator) c.GhosttyStyle {
        var value: c.GhosttyStyle = std.mem.zeroes(c.GhosttyStyle);
        value.size = @sizeOf(c.GhosttyStyle);
        _ = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &value,
        );
        return value;
    }

    /// The resolved foreground color, or null when the cell has none and the
    /// caller should fall back to the terminal default.
    pub fn foregroundColor(self: CellIterator) ?c.GhosttyColorRgb {
        var value: c.GhosttyColorRgb = undefined;
        const result = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &value,
        );
        if (result != c.GHOSTTY_SUCCESS) return null;
        return value;
    }

    /// The resolved background color, or null when the cell has none.
    pub fn backgroundColor(self: CellIterator) ?c.GhosttyColorRgb {
        var value: c.GhosttyColorRgb = undefined;
        const result = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &value,
        );
        if (result != c.GHOSTTY_SUCCESS) return null;
        return value;
    }
};

test "terminal replies to a cursor position report through write_pty" {
    const Recorder = struct {
        buffer: [128]u8 = undefined,
        len: usize = 0,

        /// Matches libghostty-vt's `GhosttyTerminalWritePtyFn`.
        fn reply(
            terminal: c.GhosttyTerminal,
            userdata: ?*anyopaque,
            data: [*c]const u8,
            len: usize,
        ) callconv(.c) void {
            _ = terminal;
            const context: *WritePtyContext = @ptrCast(@alignCast(userdata.?));
            const self: *@This() = @ptrCast(@alignCast(context.owner));
            @memcpy(self.buffer[self.len..][0..len], data[0..len]);
            self.len += len;
        }
    };

    var recorder = Recorder{};
    var context = WritePtyContext{ .owner = @ptrCast(&recorder) };

    var term = try Terminal.init(.{ .cols = 80, .rows = 24 });
    defer term.deinit();

    // Register the reply path before writing, exactly as a pane must.
    const callback: WritePtyFn = Recorder.reply;
    term.setWritePty(&context, callback);
    // DSR 6 asks for a cursor position report. Without this callback the
    // request would be dropped and a program waiting for the reply would hang.
    term.write("\x1b[6n");

    try std.testing.expect(recorder.len > 0);
    // The reply is CSI row ; col R, with the cursor at the home position.
    try std.testing.expectEqualStrings("\x1b[1;1R", recorder.buffer[0..recorder.len]);
}

test "terminal parses plain text" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    term.write("hello");

    try std.testing.expectEqual(@as(u16, 20), term.cols());
    try std.testing.expectEqual(@as(u16, 4), term.rows());
}

test "terminal tracks the title set by OSC" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    term.write("\x1b]2;zmux test\x07");

    try std.testing.expectEqualStrings("zmux test", term.title());
}

test "terminal reports mouse tracking mode" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    try std.testing.expect(!term.wantsMouse());

    // DECSET 1000 enables normal mouse tracking.
    term.write("\x1b[?1000h");
    try std.testing.expect(term.wantsMouse());

    term.write("\x1b[?1000l");
    try std.testing.expect(!term.wantsMouse());
}

test "render state exposes styled cells" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    term.write("hi");

    var render = try term.createRenderState();
    defer render.deinit();

    const Collector = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        saw_bold: bool = false,

        fn visit(self: *@This(), row: *RowIterator) bool {
            _ = row.forEachCell(self, collect) catch return false;
            return true;
        }

        fn collect(self: *@This(), cell: *CellIterator) void {
            var codepoints: [8]u32 = undefined;
            var utf8: [32]u8 = undefined;
            const bytes = cell.graphemesUtf8(&codepoints, &utf8);
            if (bytes.len == 0) return;
            @memcpy(self.text[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            if (cell.style().bold) self.saw_bold = true;
        }
    };

    var collector = Collector{};
    try render.forEachRow(&collector, Collector.visit);

    try std.testing.expectEqualStrings("hi", collector.text[0..collector.len]);
    try std.testing.expect(!collector.saw_bold);
}

test "render state reports style attributes" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    term.write("\x1b[1mB\x1b[0m");

    var render = try term.createRenderState();
    defer render.deinit();

    const Collector = struct {
        bold_cells: usize = 0,

        fn visit(self: *@This(), row: *RowIterator) bool {
            _ = row.forEachCell(self, collect) catch return false;
            return true;
        }

        fn collect(self: *@This(), cell: *CellIterator) void {
            if (cell.graphemeLen() == 0) return;
            if (cell.style().bold) self.bold_cells += 1;
        }
    };

    var collector = Collector{};
    try render.forEachRow(&collector, Collector.visit);

    try std.testing.expectEqual(@as(usize, 1), collector.bold_cells);
}

test "render state reports colors for a styled cell" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    // 24-bit red foreground.
    term.write("\x1b[38;2;255;0;0mR\x1b[0m");

    var render = try term.createRenderState();
    defer render.deinit();

    const Collector = struct {
        red: ?c.GhosttyColorRgb = null,

        fn visit(self: *@This(), row: *RowIterator) bool {
            _ = row.forEachCell(self, collect) catch return false;
            return true;
        }

        fn collect(self: *@This(), cell: *CellIterator) void {
            if (cell.graphemeLen() == 0) return;
            self.red = cell.foregroundColor();
        }
    };

    var collector = Collector{};
    try render.forEachRow(&collector, Collector.visit);

    const red = collector.red orelse return error.TestExpectedColor;
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);
    try std.testing.expectEqual(@as(u8, 0), red.b);
}
