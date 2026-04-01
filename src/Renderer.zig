const std = @import("std");
const CopyMode = @import("CopyMode.zig");
const Workspace = @import("Workspace.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const Pane = @import("Pane.zig");
const StatusBar = @import("StatusBar.zig");
const Config = @import("Config.zig");

pub const Renderer = @This();

const Cell = struct {
    codepoint: u21 = 0,
    wide: u2 = 0,
    style_id: u16 = 0,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    content_tag: u2 = 0,
};

// Cell state
prev_cells: []Cell,
// Terminal width
term_cols: u16,
// Terminal height
term_rows: u16,

alloc: std.mem.Allocator,
config: Config,

pub fn init(
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    config: Config,
) !Renderer {
    const cells = try alloc.alloc(
        Cell,
        @as(usize, cols) * @as(usize, rows),
    );
    @memset(cells, .{});
    return .{
        .prev_cells = cells,
        .term_cols = cols,
        .term_rows = rows,
        .alloc = alloc,
        .config = config,
    };
}

pub fn deinit(self: *Renderer) void {
    self.alloc.free(self.prev_cells);
}

// Returns a reference to the previous cell at the given position (x, y)
fn prevCell(self: *Renderer, x: u16, y: u16) *Cell {
    return &self.prev_cells[@as(usize, y) * self.term_cols + x];
}

/// Renders the differences for all panes held by the active workspace.
pub fn renderAll(
    self: *Renderer,
    workspace: *Workspace,
    wm: *WorkspaceManager,
    status_row: u16,
    writer: anytype,
    mode_label: ?[]const u8,
    clear_screen: bool,
    copy_mode: ?CopyMode.CopyMode,
) !void {
    // Hide the cursor
    try writer.writeAll("\x1b[?25l");

    // Clear screen if requested (e.g., after closing a pane)
    if (clear_screen) {
        try writer.writeAll("\x1b[2J\x1b[H");
    }

    // TODO Consider appropriate maximum number of panes
    var buf: [64]*Pane = undefined;
    const panes = workspace.getPanes(&buf);

    for (panes) |pane| {
        try self.renderPane(pane, writer);
    }

    try self.drawBorders(workspace, writer);

    if (workspace.show_floating) {
        try self.renderFloatingPane(workspace.floating_pane, workspace.active_pane == workspace.floating_pane, writer);
    }

    // Render copy mode overlay if active
    if (copy_mode) |cm| {
        try self.renderCopyModeOverlay(workspace.activePane(), &cm, writer);
    }

    // Render status bar at the bottom of floor
    try StatusBar.renderWithMode(wm, status_row, self.term_cols, writer, mode_label, self.config);

    // Move the cursor to saved position (unless in copy mode, where we position in overlay)
    if (copy_mode == null) {
        const active = workspace.activePane();
        const screen = active.terminal.screens.active;
        try writer.print("\x1b[{d};{d}H", .{
            active.y + screen.cursor.y + 1,
            active.x + screen.cursor.x + 1,
        });

        // Set cursor style (DECSCUSR) based on active pane's terminal state
        try writeCursorStyle(screen.cursor.cursor_style, writer);

        // Show the cursor
        try writer.writeAll("\x1b[?25h");
    }
}

fn writeCursorStyle(style: anytype, writer: anytype) !void {
    // DECSCUSR: 0/1 = blinking block, 2 = steady block, 3 = blinking underline,
    // 4 = steady underline, 5 = blinking bar, 6 = steady bar
    const code: u8 = switch (style) {
        .block, .block_hollow => 2,
        .underline => 4,
        .bar => 6,
    };
    try writer.print("\x1b[{d} q", .{code});
}

fn renderPane(
    self: *Renderer,
    pane: *Pane,
    writer: anytype,
) !void {
    const screen = pane.terminal.screens.active;
    var prev_style_id: u16 = std.math.maxInt(u16);

    for (0..pane.rows) |row| {
        for (0..pane.cols) |col| {
            const lc = screen.pages.getCell(.{
                .viewport = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                },
            }) orelse continue;
            const cell = lc.cell;

            // Calculate absolute position
            const abs_x: u16 = pane.x + @as(u16, @intCast(col));
            const abs_y: u16 = pane.y + @as(u16, @intCast(row));

            if (abs_x >= self.term_cols or abs_y >= self.term_rows) continue;

            const current: Cell = .{
                .codepoint = cell.codepoint(),
                .wide = @intFromEnum(cell.wide),
                .style_id = cell.style_id,
                .content_tag = @intFromEnum(cell.content_tag),
                .r = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.r else 0,
                .g = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.g else 0,
                .b = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.b else 0,
            };

            const prev = self.prevCell(abs_x, abs_y);

            // For wide-width spacer cells: update state tracking but don't render.
            // Without this, prev_cells falls out of sync when a spacer_tail replaces
            // a regular character, causing stale content to not be redrawn later.
            if (cell.wide == .spacer_tail) {
                prev.* = current;
                continue;
            }

            // Handling the case where no changes have occurred.
            if (std.meta.eql(current, prev.*)) continue;

            // Move cursor
            try writer.print("\x1b[{d};{d}H", .{ abs_y + 1, abs_x + 1 });

            if (cell.style_id != prev_style_id) {
                const page = &lc.node.data;
                try writeStyle(writer, page, cell.style_id);
                prev_style_id = cell.style_id;
            }

            switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => {
                    const cp = cell.content.codepoint;
                    if (cp == 0) {
                        try writer.writeByte(' ');
                    } else {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch {
                            try writer.writeByte('?');
                            prev.* = current;
                            continue;
                        };
                        try writer.writeAll(buf[0..len]);

                        if (cell.content_tag == .codepoint_grapheme) {
                            const page = &lc.node.data;
                            if (page.lookupGrapheme(cell)) |cps| {
                                for (cps) |gcp| {
                                    const glen = std.unicode.utf8Encode(gcp, &buf) catch continue;
                                    try writer.writeAll(buf[0..glen]);
                                }
                            }
                        }
                    }
                },
                .bg_color_palette => {
                    try writer.print("\x1b[48;5;{d}m ", .{cell.content.color_palette});
                    prev_style_id = std.math.maxInt(u16);
                },
                .bg_color_rgb => {
                    const rgb = cell.content.color_rgb;
                    try writer.print("\x1b[48;2;{d};{d};{d}m ", .{ rgb.r, rgb.g, rgb.b });
                },
            }
            prev.* = current;
        }
    }

    try writer.writeAll("\x1b[0m");
}

fn writeStyle(
    writer: anytype,
    page: anytype,
    style_id: u16,
) !void {
    try writer.writeAll("\x1b[0");

    if (style_id == 0) {
        try writer.writeByte('m');
        return;
    }

    const s = page.styles.get(page.memory, style_id);

    if (s.flags.bold) try writer.writeAll(";1");
    if (s.flags.faint) try writer.writeAll(";2");
    if (s.flags.italic) try writer.writeAll(";3");
    if (s.flags.underline != .none) try writer.writeAll(";4");
    if (s.flags.blink) try writer.writeAll(";5");
    if (s.flags.inverse) try writer.writeAll(";7");
    if (s.flags.invisible) try writer.writeAll(";8");
    if (s.flags.strikethrough) try writer.writeAll(";9");

    switch (s.fg_color) {
        .none => {},
        .palette => |idx| {
            const n = idx;
            if (n < 8)
                try writer.print(";3{d}", .{n})
            else if (n < 16)
                try writer.print(";9{d}", .{n - 8})
            else
                try writer.print(";38;5;{d}", .{n});
        },
        .rgb => |rgb| try writer.print(";38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
    }

    switch (s.bg_color) {
        .none => {},
        .palette => |idx| {
            const n = idx;
            if (n < 8)
                try writer.print(";4{d}", .{n})
            else if (n < 16)
                try writer.print(";10{d}", .{n - 8})
            else
                try writer.print(";48;5;{d}", .{n});
        },
        .rgb => |rgb| try writer.print(";48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
    }

    try writer.writeByte('m');
}

fn drawBorders(
    self: *Renderer,
    workspace: *Workspace,
    writer: anytype,
) !void {
    const UP: u8 = 0b0001;
    const DOWN: u8 = 0b0010;
    const LEFT: u8 = 0b0100;
    const RIGHT: u8 = 0b1000;

    const W = self.term_cols;
    const H = self.term_rows;
    const size = @as(usize, W) * @as(usize, H);

    // Accumulate UP/DOWN/LEFT/RIGHT flags directory into each cell
    var border = try self.alloc.alloc(u8, size);
    defer self.alloc.free(border);
    @memset(border, 0);

    // Track which border cells are adjacent to the active pane
    var active_border = try self.alloc.alloc(bool, size);
    defer self.alloc.free(active_border);
    @memset(active_border, false);

    var buf: [64]*Pane = undefined;
    const panes = workspace.getPanes(&buf);

    for (panes) |pane| {
        // Left vertical border: connect each cell upward and downward
        if (pane.x > 0) {
            const bx = pane.x - 1;
            for (0..pane.rows) |row| {
                const by = pane.y + @as(u16, @intCast(row));
                if (bx < W and by < H) {
                    const idx = @as(usize, by) * W + bx;
                    if (row > 0) border[idx] |= UP;
                    if (row + 1 < pane.rows) border[idx] |= DOWN;
                    // 1行ペインでも縦線にする
                    if (pane.rows == 1) border[idx] |= UP | DOWN;
                }
            }
        }
        // Top horizontal border: connect each cell leftward and rightward
        if (pane.y > 0) {
            const by = pane.y - 1;
            for (0..pane.cols) |col| {
                const bx = pane.x + @as(u16, @intCast(col));
                if (bx < W and by < H) {
                    const idx = @as(usize, by) * W + bx;
                    if (col > 0) border[idx] |= LEFT;
                    if (col + 1 < pane.cols) border[idx] |= RIGHT;
                    if (pane.cols == 1) border[idx] |= LEFT | RIGHT;
                }
            }
        }
        // Corner intersections: top-left corner (line extends right and down)
        if (pane.x > 0 and pane.y > 0) {
            const cx = pane.x - 1;
            const cy = pane.y - 1;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= RIGHT | DOWN;
            }
        }
        // Top-right corner (line extends left and down)
        if (pane.x + pane.cols < W and pane.y > 0) {
            const cx = pane.x + pane.cols;
            const cy = pane.y - 1;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= LEFT | DOWN;
            }
        }
        // Bottom-left corner (line extends right and up)
        if (pane.x > 0 and pane.y + pane.rows < H) {
            const cx = pane.x - 1;
            const cy = pane.y + pane.rows;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= RIGHT | UP;
            }
        }
        // Bottom-right corner (line extends left and up)
        if (pane.x + pane.cols < W and pane.y + pane.rows < H) {
            const cx = pane.x + pane.cols;
            const cy = pane.y + pane.rows;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= LEFT | UP;
            }
        }
    }

    // Mark border cells adjacent to the active pane on all four sides
    const ap = workspace.active_pane;
    // Left border
    if (ap.x > 0) {
        const bx = ap.x - 1;
        for (0..ap.rows) |row| {
            const by = ap.y + @as(u16, @intCast(row));
            if (by < H) active_border[@as(usize, by) * W + bx] = true;
        }
    }
    // Right border
    if (ap.x + ap.cols < W) {
        const bx = ap.x + ap.cols;
        for (0..ap.rows) |row| {
            const by = ap.y + @as(u16, @intCast(row));
            if (by < H) active_border[@as(usize, by) * W + bx] = true;
        }
    }
    // Top border
    if (ap.y > 0) {
        const by = ap.y - 1;
        for (0..ap.cols) |col| {
            const bx = ap.x + @as(u16, @intCast(col));
            if (bx < W) active_border[@as(usize, by) * W + bx] = true;
        }
    }
    // Bottom border
    if (ap.y + ap.rows < H) {
        const by = ap.y + ap.rows;
        for (0..ap.cols) |col| {
            const bx = ap.x + @as(u16, @intCast(col));
            if (bx < W) active_border[@as(usize, by) * W + bx] = true;
        }
    }

    for (0..H) |row| {
        for (0..W) |col| {
            const v = border[row * W + col];
            if (v == 0) continue;

            const ch: []const u8 = switch (v) {
                UP | DOWN => "│",
                LEFT | RIGHT => "─",
                UP | DOWN | RIGHT => "├",
                UP | DOWN | LEFT => "┤",
                LEFT | RIGHT | DOWN => "┬",
                LEFT | RIGHT | UP => "┴",
                UP | DOWN | LEFT | RIGHT => "┼",
                DOWN | RIGHT => "┌",
                DOWN | LEFT => "┐",
                UP | RIGHT => "└",
                UP | LEFT => "┘",
                UP, DOWN => "│",
                LEFT, RIGHT => "─",
                else => continue,
            };

            const is_intersection = @popCount(v) >= 3;
            const color: []const u8 = if (!is_intersection and active_border[row * W + col]) self.config.active_border_color.toAnsiSeq() else self.config.inactive_border_color.toAnsiSeq();
            try writer.print("\x1b[{d};{d}H{s}{s}", .{
                row + 1,
                col + 1,
                color,
                ch,
            });
        }
    }
}

/// Make all cells as dirty so they will be redrawn on the next render pass
pub fn invalidate(self: *Renderer) void {
    @memset(self.prev_cells, .{
        .codepoint = std.math.maxInt(u21),
    });
}

/// Invalidate only the cells within a specific rectangular region
pub fn invalidateRect(self: *Renderer, x: u16, y: u16, cols: u16, rows: u16) void {
    const dirty: Cell = .{ .codepoint = std.math.maxInt(u21) };
    for (y..y + rows) |row| {
        if (row >= self.term_rows) break;
        for (x..x + cols) |col| {
            if (col >= self.term_cols) break;
            self.prev_cells[row * self.term_cols + col] = dirty;
        }
    }
}

pub fn renderFloatingOnly(
    self: *Renderer,
    workspace: *Workspace,
    wm: *WorkspaceManager,
    status_row: u16,
    writer: anytype,
    mode_label: ?[]const u8,
) !void {
    try writer.writeAll("\x1b[?25l");

    if (workspace.show_floating) {
        try self.renderFloatingPane(
            workspace.floating_pane,
            workspace.active_pane == workspace.floating_pane,
            writer,
        );
    }

    try StatusBar.renderWithMode(wm, status_row, self.term_cols, writer, mode_label, self.config);

    const active = workspace.activePane();
    const screen = active.terminal.screens.active;
    try writer.print("\x1b[{d};{d}H", .{
        active.y + screen.cursor.y + 1,
        active.x + screen.cursor.x + 1,
    });

    try writeCursorStyle(screen.cursor.cursor_style, writer);
    try writer.writeAll("\x1b[?25h");
}

fn renderFloatingPane(
    self: *Renderer,
    pane: *Pane,
    is_active: bool,
    writer: anytype,
) !void {
    // Border coordinates (one cell outside the pane area)
    const bx = if (pane.x > 0) pane.x - 1 else 0;
    const by = if (pane.y > 0) pane.y - 1 else 0;
    const inner_cols = pane.cols;
    const inner_rows = pane.rows;

    // Border color: bright when active, dim when inactive
    const border_style: []const u8 = if (is_active) self.config.active_border_color.toAnsiSeq() else self.config.inactive_border_color.toAnsiSeq();

    // ── Top edge ──
    if (by < self.term_rows) {
        try writer.print("\x1b[{d};{d}H{s}┌", .{ by + 1, bx + 1, border_style });
        for (0..inner_cols) |_| {
            try writer.writeAll("─");
        }
        try writer.writeAll("┐");

        // Overwrite prev_cells with border chars so the diff renderer doeson't erase them
        if (bx < self.term_cols) {
            self.prevCell(bx, by).* = .{ .codepoint = std.math.maxInt(u21) };
        }
        for (0..inner_cols) |ci| {
            const cx = pane.x + @as(u16, @intCast(ci));
            if (cx < self.term_cols and by < self.term_rows) {
                self.prevCell(cx, by).* = .{ .codepoint = std.math.maxInt(u21) };
            }
        }
    }

    // ── Sides + pane content ──
    for (0..inner_rows) |row_i| {
        const ry = pane.y + @as(u16, @intCast(row_i));
        if (ry >= self.term_rows) break;

        // Left border
        if (bx < self.term_cols) {
            try writer.print("\x1b[{d};{d}H{s}│", .{ ry + 1, bx + 1, border_style });
            self.prevCell(bx, ry).* = .{ .codepoint = std.math.maxInt(u21) };
        }

        // Right border
        const rx = pane.x + inner_cols;
        if (rx < self.term_cols) {
            try writer.print("\x1b[{d};{d}H{s}│", .{ ry + 1, rx + 1, border_style });
            self.prevCell(rx, ry).* = .{ .codepoint = std.math.maxInt(u21) };
        }
    }

    // ── Bottom edge ──
    const bottom_y = pane.y + inner_rows;
    if (bottom_y < self.term_rows) {
        try writer.print("\x1b[{d};{d}H{s}└", .{ bottom_y + 1, bx + 1, border_style });
        for (0..inner_cols) |_| {
            try writer.writeAll("─");
        }
        try writer.writeAll("┘");

        if (bx < self.term_cols) {
            self.prevCell(bx, bottom_y).* = .{ .codepoint = std.math.maxInt(u21) };
        }
        for (0..inner_cols) |ci| {
            const cx = pane.x + @as(u16, @intCast(ci));
            if (cx < self.term_cols and bottom_y < self.term_rows) {
                self.prevCell(cx, bottom_y).* = .{ .codepoint = std.math.maxInt(u21) };
            }
        }
    }

    // ── Render pane content ──
    try writer.writeAll("\x1b[0m");
    try self.renderPane(pane, writer);
}

/// Render copy mode overlay: selection highlight and cursor
/// Also invalidates the affected cells so they will be redrawn correctly on the next frame
pub fn renderCopyModeOverlay(
    self: *Renderer,
    pane: *Pane,
    cm: *const CopyMode.CopyMode,
    writer: anytype,
) !void {
    const screen = pane.terminal.screens.active;
    const dirty_cell: Cell = .{ .codepoint = std.math.maxInt(u21) };

    // Hide cursor during overlay rendering
    try writer.writeAll("\x1b[?25l");

    // Render selected cells with reverse video
    if (cm.selecting) {
        var start_y = cm.sel_start_y;
        var start_x = cm.sel_start_x;
        var end_y = cm.cursor_y;
        var end_x = cm.cursor_x;

        if (start_y > end_y or (start_y == end_y and start_x > end_x)) {
            const tmp_y = start_y;
            const tmp_x = start_x;
            start_y = end_y;
            start_x = end_x;
            end_y = tmp_y;
            end_x = tmp_x;
        }

        var y = start_y;
        while (y <= end_y) : (y += 1) {
            const row_start: u16 = if (y == start_y) start_x else 0;
            const row_end: u16 = if (y == end_y) end_x else pane.cols -| 1;

            var x = row_start;
            while (x <= row_end) : (x += 1) {
                const abs_x = pane.x + x;
                const abs_y = pane.y + y;

                if (abs_x >= self.term_cols or abs_y >= self.term_rows) continue;

                try writer.print("\x1b[{d};{d}H\x1b[7m", .{ abs_y + 1, abs_x + 1 });

                const lc = screen.pages.getCell(.{
                    .viewport = .{ .x = @intCast(x), .y = @intCast(y) },
                });
                if (lc) |l| {
                    const cp = l.cell.codepoint();
                    if (cp == 0 or l.cell.wide == .spacer_tail) {
                        try writer.writeByte(' ');
                    } else {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                        if (len == 1 and utf8_buf[0] == 0) {
                            try writer.writeByte(' ');
                        } else {
                            try writer.writeAll(utf8_buf[0..len]);
                        }
                    }
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll("\x1b[0m");

                // Mark cell as dirty so it will be redrawn on next frame
                self.prevCell(abs_x, abs_y).* = dirty_cell;
            }
        }
    }

    // Render block cursor at copy mode position
    {
        const abs_x = pane.x + cm.cursor_x;
        const abs_y = pane.y + cm.cursor_y;

        if (abs_x < self.term_cols and abs_y < self.term_rows) {
            try writer.print("\x1b[{d};{d}H", .{ abs_y + 1, abs_x + 1 });

            const lc = screen.pages.getCell(.{
                .viewport = .{ .x = @intCast(cm.cursor_x), .y = @intCast(cm.cursor_y) },
            });

            // Block cursor for copy mode
            try writer.writeAll(self.config.copy_cursor_fg.toFgAnsiSeq());
            try writer.writeAll(self.config.copy_cursor_bg.toBgAnsiSeq());
            if (lc) |l| {
                const cp = l.cell.codepoint();
                if (cp == 0 or l.cell.wide == .spacer_tail) {
                    try writer.writeByte(' ');
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                    if (len == 1 and utf8_buf[0] == 0) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(utf8_buf[0..len]);
                    }
                }
            } else {
                try writer.writeByte(' ');
            }
            try writer.writeAll("\x1b[0m");

            // Mark cursor cell as dirty so it will be redrawn on next frame
            self.prevCell(abs_x, abs_y).* = dirty_cell;
        }
    }
}
