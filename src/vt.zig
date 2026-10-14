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
        ///
        /// Two thousand, which is tmux's default. Measured on the pinned library, a full history
        /// costs about 680 bytes per row whatever the limit, so this is the ceiling of a pane's
        /// memory: 1.3 MiB per pane here against 6.4 MiB at ten thousand. An empty pane costs 44 KiB
        /// at either limit, so this is not a start-up cost; it is what a pane can grow to.
        ///
        /// The number is a judgement about how much history is worth paying for. Ten thousand lines
        /// is more than a screenful-by-screenful reader ever walks, and the panes that fill up
        /// fastest are the ones printing long output, which is exactly when the memory is least
        /// welcome.
        max_scrollback: usize = 2_000,
        /// Maximum bytes of scrollback history, or null for the library's default.
        ///
        /// The line limit alone is not enough, and this is the reason a long run of output stopped
        /// being reachable part-way. The library keeps *both* limits and prunes at whichever is
        /// reached first, and its default byte limit is small enough to be hit long before the line
        /// limit: printing `seq 1 1000` into an 80-column pane retained only about 870 rows and
        /// silently discarded the rest. Raising it is what lets the line limit be the one that
        /// governs, which is the limit a reader expects.
        ///
        /// Four mebibytes is ample for two thousand rows, which measure about 1.3 MiB for ordinary
        /// text. It is a ceiling that is not reached in the ordinary case, which is the right shape
        /// for one: it exists to bound a pathological row, such as one carrying a great many styles,
        /// not to decide how much history a pane keeps.
        max_scrollback_bytes: ?usize = 4 * 1024 * 1024,
    };

    pub fn init(options: Options) Error!Terminal {
        // libghostty-vt requires at least one cell in each direction, and a
        // zero-sized terminal is the kind of thing that only shows up much
        // later as an empty screen, so reject it here.
        if (options.cols == 0 or options.rows == 0) return Error.InvalidValue;

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

        // The byte limit as well, because the library prunes at whichever limit is reached first and
        // its own default byte limit is reached long before ten thousand lines. Setting this is not
        // a tuning knob: without it the line limit is not the one that applies, so a long run of
        // output is cut off at a few hundred rows with nothing to say so.
        if (options.max_scrollback_bytes) |limit| {
            var max_bytes = limit;
            _ = c.ghostty_terminal_set(
                terminal.handle,
                c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                &max_bytes,
            );
        }

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

    /// How many rows of history are above the active area.
    ///
    /// Zero on the alternate screen, which has no scrollback, so this is also what says whether
    /// scrolling is possible at all.
    pub fn scrollbackRows(self: Terminal) usize {
        var value: usize = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &value);
        return value;
    }

    /// Whether the viewport is following the active area rather than sitting in history.
    ///
    /// The library says outright that there is no change notification for this, so it is polled
    /// rather than watched.
    pub fn viewportActive(self: Terminal) bool {
        var value: bool = false;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &value);
        return value;
    }

    /// Move the viewport by a number of rows, negative meaning up into history.
    ///
    /// The library clamps at both ends, so a scroll past the top or the bottom is not an error and
    /// needs no bounds check here. Scrolling does not disturb the program: it changes which rows are
    /// drawn, not the terminal's contents, and output arriving meanwhile still goes to the screen.
    pub fn scrollBy(self: Terminal, count: i32) void {
        const request = c.GhosttyTerminalScrollViewport{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = count },
        };
        c.ghostty_terminal_scroll_viewport(self.handle, request);
    }

    /// Move the viewport to an absolute row of the scrollable area, zero being the oldest.
    pub fn scrollToRow(self: Terminal, row: usize) void {
        const request = c.GhosttyTerminalScrollViewport{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_ROW,
            .value = .{ .row = row },
        };
        c.ghostty_terminal_scroll_viewport(self.handle, request);
    }

    /// Return the viewport to the bottom, where new output is.
    pub fn scrollToBottom(self: Terminal) void {
        const request = c.GhosttyTerminalScrollViewport{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            .value = .{ .row = 0 },
        };
        c.ghostty_terminal_scroll_viewport(self.handle, request);
    }

    /// Move the viewport to the oldest row held.
    pub fn scrollToTop(self: Terminal) void {
        const request = c.GhosttyTerminalScrollViewport{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_TOP,
            .value = .{ .row = 0 },
        };
        c.ghostty_terminal_scroll_viewport(self.handle, request);
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

    /// Clear the dirty state after a frame has been painted.
    ///
    /// The library only ever sets dirty flags; clearing them is the renderer's
    /// job, and both layers have to be cleared. `update` reports the frame as
    /// fully dirty for as long as this is not called.
    ///
    /// The row flags are not cleared here because they live on the row
    /// iterator, which is only valid while the rows are being walked. The
    /// caller clears each row with `RowIterator.clearDirty` as it paints it.
    pub fn clearDirty(self: RenderState) void {
        var value: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_set(
            self.handle,
            c.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
            &value,
        );
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

    /// Clear this row's dirty flag, once its repaint has been written.
    ///
    /// The iterator must be positioned on a row for this to have any effect;
    /// `forEachRow` guarantees that inside its visitor.
    pub fn clearDirty(self: RowIterator) void {
        var value = false;
        _ = c.ghostty_render_state_row_set(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
            &value,
        );
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

/// A colour, as the terminal should draw it.
///
/// The library hands back a colour per channel. A renderer writing SGR wants the numbers, so
/// keeping them in this shape avoids a conversion on the drawing path.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// How one cell should look.
///
/// The colours are resolved: what the library reports is what to draw, whether the program asked
/// for a palette entry or gave an explicit RGB value. A null colour means the cell does not set
/// one and the terminal's default applies, which the renderer expresses by not emitting that
/// part of the sequence at all rather than by choosing a colour of its own.
pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,

    /// Whether this style asks for anything at all.
    ///
    /// Used to skip emitting a reset sequence for a cell that needs no styling, which is most of
    /// them.
    pub fn isDefault(self: Style) bool {
        return self.fg == null and self.bg == null and
            !self.bold and !self.faint and !self.italic and
            !self.underline and !self.blink and !self.inverse and
            !self.invisible and !self.strikethrough;
    }

    pub fn eql(self: Style, other: Style) bool {
        return rgbEql(self.fg, other.fg) and rgbEql(self.bg, other.bg) and
            self.bold == other.bold and self.faint == other.faint and
            self.italic == other.italic and self.underline == other.underline and
            self.blink == other.blink and self.inverse == other.inverse and
            self.invisible == other.invisible and
            self.strikethrough == other.strikethrough;
    }
};

fn rgbEql(a: ?Rgb, b: ?Rgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

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

    /// Whether this cell carries any styling of its own.
    ///
    /// This is the flag that says whether a style is worth writing at all. The colour accessors
    /// *resolve* a colour for every cell, including one that never asked for any: a plain cell
    /// reports the terminal's default foreground rather than nothing. Reading that as a style made
    /// every cell look styled, so a re-sent screen wrote an explicit colour for text that had none,
    /// and the rest of the row inherited it.
    pub fn hasStyling(self: CellIterator) bool {
        var value: bool = false;
        _ = c.ghostty_render_state_row_cells_get(
            self.handle,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
            &value,
        );
        return value;
    }

    /// Everything needed to draw this cell, gathered in one call.
    ///
    /// The colours come from the resolved accessors rather than from the style's own fields,
    /// because those may hold palette indices while these are RGB. A renderer would otherwise have
    /// to carry a palette and keep it matching the terminal's, which is a way to get the colours
    /// subtly wrong rather than to get them right.
    ///
    /// A cell with no styling reports no colours, whatever the resolved accessors say. A cell that
    /// has styling keeps them, and one that asked only for a colour the terminal did not change is
    /// indistinguishable from a plain cell by design: what matters for drawing is whether anything
    /// has to be written, not whether the program mentioned it.
    pub fn resolvedStyle(self: CellIterator) Style {
        const raw = self.style();
        if (!self.hasStyling()) return .{};

        const fg = self.foregroundColor();
        const bg = self.backgroundColor();

        return .{
            .fg = if (fg) |colour| Rgb{ .r = colour.r, .g = colour.g, .b = colour.b } else null,
            .bg = if (bg) |colour| Rgb{ .r = colour.r, .g = colour.g, .b = colour.b } else null,
            .bold = raw.bold,
            .faint = raw.faint,
            .italic = raw.italic,
            .underline = raw.underline != c.GHOSTTY_SGR_UNDERLINE_NONE,
            .blink = raw.blink,
            .inverse = raw.inverse,
            .invisible = raw.invisible,
            .strikethrough = raw.strikethrough,
        };
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

/// Encodes key events into the byte sequences a terminal program expects.
///
/// The encoding is not fixed: a program that enables the kitty keyboard
/// protocol or DECCKM must receive different bytes for the same key. Rather
/// than track those modes ourselves, `syncFromTerminal` copies the state out of
/// the terminal that is already parsing the program's output.
pub const KeyEncoder = struct {
    handle: c.GhosttyKeyEncoder,
    event: c.GhosttyKeyEvent,

    pub fn init(terminal: Terminal) Error!KeyEncoder {
        var handle: c.GhosttyKeyEncoder = null;
        try check(c.ghostty_key_encoder_new(null, &handle));
        errdefer c.ghostty_key_encoder_free(handle);

        var event: c.GhosttyKeyEvent = null;
        try check(c.ghostty_key_event_new(null, &event));
        errdefer c.ghostty_key_event_free(event);

        var encoder = KeyEncoder{ .handle = handle, .event = event };
        encoder.syncFromTerminal(terminal);
        return encoder;
    }

    pub fn deinit(self: *KeyEncoder) void {
        c.ghostty_key_event_free(self.event);
        c.ghostty_key_encoder_free(self.handle);
        self.event = null;
        self.handle = null;
    }

    /// Adopt the terminal's current keyboard-related modes.
    ///
    /// Call this after feeding the terminal any output that may have changed
    /// them, or the encoding will lag behind the program's expectations.
    pub fn syncFromTerminal(self: KeyEncoder, terminal: Terminal) void {
        c.ghostty_key_encoder_setopt_from_terminal(self.handle, terminal.handle);
    }

    /// Encode a key press into `buffer`.
    ///
    /// Returns the slice of `buffer` holding the bytes to write to the pty, or
    /// an empty slice when the key produces no output (for example a bare
    /// modifier press).
    pub fn encode(
        self: KeyEncoder,
        key: c.GhosttyKey,
        mods: c.GhosttyMods,
        action: c.GhosttyKeyAction,
        utf8: ?[]const u8,
        buffer: []u8,
    ) Error![]const u8 {
        c.ghostty_key_event_set_key(self.event, key);
        c.ghostty_key_event_set_mods(self.event, mods);
        c.ghostty_key_event_set_action(self.event, action);

        if (utf8) |text| {
            c.ghostty_key_event_set_utf8(self.event, text.ptr, text.len);
        } else {
            c.ghostty_key_event_set_utf8(self.event, null, 0);
        }

        var written: usize = 0;
        try check(c.ghostty_key_encoder_encode(
            self.handle,
            self.event,
            buffer.ptr,
            buffer.len,
            &written,
        ));
        return buffer[0..written];
    }
};

/// Look up the key for an ASCII character, for the printable range.
///
/// libghostty-vt names keys for letters, digits and punctuation; anything
/// outside that set is sent as text rather than as a key.
///
/// `GhosttyKey` is an unsigned integer rather than an enum, so letters and
/// digits are reached by offsetting from the first of each run. The offsets
/// hold because the header declares `A` through `Z` and `DIGIT_0` through
/// `DIGIT_9` contiguously.
pub fn keyForAscii(character: u8) ?c.GhosttyKey {
    const Key = c.GhosttyKey;
    return switch (character) {
        'a'...'z' => @as(Key, @intCast(c.GHOSTTY_KEY_A)) + (character - 'a'),
        'A'...'Z' => @as(Key, @intCast(c.GHOSTTY_KEY_A)) + (character - 'A'),
        '0'...'9' => @as(Key, @intCast(c.GHOSTTY_KEY_DIGIT_0)) + (character - '0'),
        ' ' => @intCast(c.GHOSTTY_KEY_SPACE),
        '-' => @intCast(c.GHOSTTY_KEY_MINUS),
        '.' => @intCast(c.GHOSTTY_KEY_PERIOD),
        '\'' => @intCast(c.GHOSTTY_KEY_QUOTE),
        ';' => @intCast(c.GHOSTTY_KEY_SEMICOLON),
        '/' => @intCast(c.GHOSTTY_KEY_SLASH),
        else => null,
    };
}

test "key encoder sends a plain letter as itself" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    var encoder = try KeyEncoder.init(term);
    defer encoder.deinit();

    var buffer: [64]u8 = undefined;
    const encoded = try encoder.encode(
        c.GHOSTTY_KEY_A,
        0,
        c.GHOSTTY_KEY_ACTION_PRESS,
        "a",
        &buffer,
    );
    try std.testing.expectEqualStrings("a", encoded);
}

test "key encoder sends ctrl-c as the interrupt byte" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    var encoder = try KeyEncoder.init(term);
    defer encoder.deinit();

    var buffer: [64]u8 = undefined;
    const encoded = try encoder.encode(
        c.GHOSTTY_KEY_C,
        c.GHOSTTY_MODS_CTRL,
        c.GHOSTTY_KEY_ACTION_PRESS,
        null,
        &buffer,
    );
    try std.testing.expectEqualStrings("\x03", encoded);
}

test "key encoder follows the terminal into application cursor mode" {
    var term = try Terminal.init(.{ .cols = 20, .rows = 4 });
    defer term.deinit();

    var encoder = try KeyEncoder.init(term);
    defer encoder.deinit();

    var buffer: [64]u8 = undefined;

    // In normal mode the up arrow is CSI A.
    const normal = try encoder.encode(
        c.GHOSTTY_KEY_ARROW_UP,
        0,
        c.GHOSTTY_KEY_ACTION_PRESS,
        null,
        &buffer,
    );
    try std.testing.expectEqualStrings("\x1b[A", normal);

    // DECCKM (DEC private mode 1) switches the arrows to SS3 A. Syncing from
    // the terminal is what picks this up, so it must change the result.
    term.write("\x1b[?1h");
    encoder.syncFromTerminal(term);

    const application = try encoder.encode(
        c.GHOSTTY_KEY_ARROW_UP,
        0,
        c.GHOSTTY_KEY_ACTION_PRESS,
        null,
        &buffer,
    );
    try std.testing.expectEqualStrings("\x1bOA", application);
}

test "keyForAscii maps letters, digits and punctuation" {
    const Key = c.GhosttyKey;
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_A)), keyForAscii('a').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_Z)), keyForAscii('z').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_J)), keyForAscii('J').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_DIGIT_0)), keyForAscii('0').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_DIGIT_9)), keyForAscii('9').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_SPACE)), keyForAscii(' ').?);
    try std.testing.expectEqual(@as(Key, @intCast(c.GHOSTTY_KEY_SLASH)), keyForAscii('/').?);
}

test "write_pty keeps working when the owner is heap-allocated" {
    // A session used to pass its own address to the terminal, then return
    // itself by value. The copy left the terminal pointing at the stack slot,
    // and the first program that sent a query corrupted memory. Heap
    // allocation is what makes the address stable, so this checks that the
    // callback still reaches its owner after many replies.
    const Owner = struct {
        context: WritePtyContext = undefined,
        replies: usize = 0,

        fn callback(
            terminal: c.GhosttyTerminal,
            userdata: ?*anyopaque,
            data: [*c]const u8,
            len: usize,
        ) callconv(.c) void {
            _ = terminal;
            _ = data;
            _ = len;
            const ctx: *WritePtyContext = @ptrCast(@alignCast(userdata.?));
            const self: *@This() = @ptrCast(@alignCast(ctx.owner));
            self.replies += 1;
        }
    };

    var term = try Terminal.init(.{ .cols = 80, .rows = 24 });
    defer term.deinit();

    const owner = try std.testing.allocator.create(Owner);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{};
    owner.context = .{ .owner = @ptrCast(owner) };

    const callback: WritePtyFn = Owner.callback;
    term.setWritePty(&owner.context, callback);

    // Each cursor position report produces one reply. Sending many exercises
    // the callback repeatedly, which is what a full-screen editor does.
    for (0..64) |_| term.write("\x1b[6n");

    try std.testing.expectEqual(@as(usize, 64), owner.replies);
}

test "a long run of output is retained up to the line limit" {
    // The defect this guards against: the library keeps both a line limit and a byte limit and prunes
    // at whichever is reached first, and its default byte limit is far smaller than what the line
    // limit needs. Printing `seq 1 1000` into an 80-column pane therefore kept only about 870 rows and
    // silently discarded the rest, so scrolling back stopped part-way with no indication why.
    //
    // Every line here is short and unstyled, which is the cheapest case for the byte limit; a run
    // with colour would be pruned sooner still.
    const limit = (Terminal.Options{ .cols = 1, .rows = 1 }).max_scrollback;
    var terminal = try Terminal.init(.{ .cols = 78, .rows = 21 });
    defer terminal.deinit();

    var n: usize = 1;
    var buf: [32]u8 = undefined;
    // Half the limit, so that the first half of the test is about retention rather than about what
    // the limit is.
    const below = limit / 2;
    while (n <= below) : (n += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "{d}\r\n", .{n}));
    }

    // Those lines into twenty-one rows leaves every line above the last screenful in history.
    const held = terminal.scrollbackRows();
    try std.testing.expect(held >= below - 21);

    // And the limit is still a limit: printing far past it keeps the configured number of lines
    // rather than growing without bound. The bound is the configured one and not a literal, so that
    // changing the default does not silently stop this from testing anything.
    var count: usize = below + 1;
    while (count <= limit * 3) : (count += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "{d}\r\n", .{count}));
    }
    const capped = terminal.scrollbackRows();
    try std.testing.expect(capped <= limit);
    try std.testing.expect(capped > limit * 9 / 10);
}

test "the byte limit can be lowered, and is what stops a run when it is" {
    // The counterpart of the test above: with a small byte limit the history is pruned early, which
    // is the behaviour that was being seen by default. This states the mechanism rather than trusting
    // that the option took effect.
    var terminal = try Terminal.init(.{
        .cols = 78,
        .rows = 21,
        .max_scrollback_bytes = 512 * 1024,
    });
    defer terminal.deinit();

    var n: usize = 1;
    var buf: [32]u8 = undefined;
    while (n <= 5000) : (n += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "{d}\r\n", .{n}));
    }

    const held = terminal.scrollbackRows();
    // Far fewer than the five thousand printed, and fewer than the ten thousand the line limit
    // allows: the byte limit is what decided.
    try std.testing.expect(held < 5000);
}

test "every scroll movement goes the way it says" {
    // The direction of a scroll is not visible in the code: `scrollBy(1)` and `scrollBy(-1)` differ
    // by a sign, and the library documents that up is negative. This checks the sign against the
    // viewport's own absolute row, which is the only thing that says which way the reader moved.
    //
    // It exists because the prefix was moved to ctrl-b, which had been page-up in the scroll mode.
    // Renaming a key is exactly the kind of change that leaves a movement pointing the wrong way
    // with nothing to catch it.
    var terminal = try Terminal.init(.{ .cols = 78, .rows = 20 });
    defer terminal.deinit();

    var n: usize = 1;
    var buf: [32]u8 = undefined;
    while (n <= 300) : (n += 1) {
        terminal.write(try std.fmt.bufPrint(&buf, "L{d}\r\n", .{n}));
    }

    // The viewport row, from the scrollbar, in the same row space the scroll API uses.
    const row = struct {
        fn of(t: Terminal) usize {
            var bar: c.GhosttyTerminalScrollbar = .{ .total = 0, .offset = 0, .len = 0 };
            const result = c.ghostty_terminal_get(
                t.handle,
                c.GHOSTTY_TERMINAL_DATA_SCROLLBAR,
                &bar,
            );
            if (result != c.GHOSTTY_SUCCESS) return 0;
            return @intCast(bar.offset);
        }
    }.of;

    // Each movement is tried from a row well away from both ends, so a wrong sign has room to show.
    const Movement = struct { name: []const u8, delta: i32, goes_up: bool };
    const movements = [_]Movement{
        .{ .name = "a line down", .delta = 1, .goes_up = false },
        .{ .name = "a line up", .delta = -1, .goes_up = true },
        .{ .name = "ten down", .delta = 10, .goes_up = false },
        .{ .name = "ten up", .delta = -10, .goes_up = true },
        .{ .name = "half a screen down", .delta = 9, .goes_up = false },
        .{ .name = "half a screen up", .delta = -9, .goes_up = true },
        .{ .name = "a screen down", .delta = 18, .goes_up = false },
        .{ .name = "a screen up", .delta = -18, .goes_up = true },
    };

    for (movements) |movement| {
        // An absolute row rather than a relative one, so every movement starts from the same place:
        // scrolling by a delta would drift, and a later movement would run out of room at an end and
        // be reported as going the wrong way.
        terminal.scrollToRow(140);
        const before = row(terminal);
        terminal.scrollBy(movement.delta);
        const after = row(terminal);
        if (movement.goes_up) {
            if (after >= before) {
                std.debug.print("scrollBy({d}) for {s} did not move up: row {d} to {d}\n", .{
                    movement.delta, movement.name, before, after,
                });
                return error.ScrollWentTheWrongWay;
            }
        } else {
            if (after <= before) {
                std.debug.print("scrollBy({d}) for {s} did not move down: row {d} to {d}\n", .{
                    movement.delta, movement.name, before, after,
                });
                return error.ScrollWentTheWrongWay;
            }
        }
    }

    // The ends are the ends: the top is row zero, and the bottom is past every row of history.
    terminal.scrollToTop();
    try std.testing.expectEqual(@as(usize, 0), row(terminal));
    terminal.scrollToBottom();
    try std.testing.expect(row(terminal) > 250);
    try std.testing.expect(terminal.viewportActive());

    // Scrolling past either end is clamped rather than wrapping or reporting an error, so a reader
    // holding a key at the top does not end up at the bottom, and one at the bottom does not end up
    // in the middle of history.
    //
    // Both ends are checked against a row read before the movement, because the assertion that was
    // here -- `row(terminal) - (row(terminal) - 0) == 0` -- is true for every value and was pinning
    // nothing at all.
    terminal.scrollToTop();
    const top = row(terminal);
    terminal.scrollBy(-5000);
    try std.testing.expectEqual(top, row(terminal));

    terminal.scrollToBottom();
    const bottom = row(terminal);
    // Scrolling down from the bottom must not move the viewport, whatever the amount.
    terminal.scrollBy(5000);
    try std.testing.expectEqual(bottom, row(terminal));
    // And it is still the live screen rather than somewhere in history.
    try std.testing.expect(terminal.viewportActive());

    // A scroll up from the bottom really does move, so the assertion above is not passing because
    // scrolling never works: without this, a `scrollBy` that did nothing at all would pass.
    terminal.scrollBy(-5);
    try std.testing.expect(row(terminal) < bottom);
    try std.testing.expect(!terminal.viewportActive());
}
