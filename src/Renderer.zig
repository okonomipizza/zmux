const std = @import("std");
const Workspace = @import("Workspace.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const Pane = @import("Pane.zig");
const StatusBar = @import("StatusBar.zig");

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

prev_cells: []Cell,
term_cols: u16,
term_rows: u16,
alloc: std.mem.Allocator,

pub fn init(
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
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
    };
}

pub fn deinit(self: *Renderer) void {
    self.alloc.free(self.prev_cells);
}

fn prevCell(self: *Renderer, x: u16, y: u16) *Cell {
    return &self.prev_cells[@as(usize, y) * self.term_cols + x];
}

/// 全ペインの差分を描画する
pub fn renderAll(
    self: *Renderer,
    workspace: *Workspace,
    wm: *WorkspaceManager,
    status_row: u16,
    writer: anytype,
) !void {
    // ちらつき防止：カーソル非表示
    try writer.writeAll("\x1b[?25l");

    for (workspace.panes.items) |*pane| {
        try self.renderPane(pane, writer);
    }

    // 境界線描画
    try self.drawBorders(workspace, writer);

    try StatusBar.render(wm, status_row, self.term_cols, writer);

    // アクティブペインのカーソル位置を反映
    if (workspace.activePane()) |active| {
        const screen = active.terminal.screens.active;
        try writer.print("\x1b[{d};{d}H", .{
            active.y + screen.cursor.y + 1,
            active.x + screen.cursor.x + 1,
        });
    }

    // カーソル再表示
    try writer.writeAll("\x1b[?25h");
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
                .active = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                },
            }) orelse continue;
            const cell = lc.cell;

            // 画面上の絶対座標を計算
            const abs_x: u16 = pane.x + @as(u16, @intCast(col));
            const abs_y: u16 = pane.y + @as(u16, @intCast(row));

            if (abs_x >= self.term_cols or abs_y >= self.term_rows) continue;

            // wide_char の右側部分はスキップ
            if (cell.wide == .spacer_tail) continue;

            //
            const current: Cell = .{
                .codepoint = cell.codepoint(),
                .wide = @intFromEnum(cell.wide),
                .style_id = cell.style_id,
                .content_tag = @intFromEnum(cell.content_tag),
                .r = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.r else 0,
                .g = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.g else 0,
                .b = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.b else 0,
            };

            // 前のフレームから変更がなければ何もしない
            const prev = self.prevCell(abs_x, abs_y);
            if (std.meta.eql(current, prev.*)) continue;

            // カーソル移動
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

                        // grapheme の追加コードポイントも出力
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
    // まずリセット
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

    // 前景色
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

    // 背景色
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

    // 各セルに直接 UP/DOWN/LEFT/RIGHT を蓄積する
    var border = try self.alloc.alloc(u8, size);
    defer self.alloc.free(border);
    @memset(border, 0);

    for (workspace.panes.items) |*pane| {
        // 左辺の縦線: 各セルから上下に接続
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
        // 上辺の横線: 各セルから左右に接続
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
        // 交差点: 左上角（右と下に線が伸びる）
        if (pane.x > 0 and pane.y > 0) {
            const cx = pane.x - 1;
            const cy = pane.y - 1;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= RIGHT | DOWN;
            }
        }
        // 右上角（左と下に線が伸びる）
        if (pane.x + pane.cols < W and pane.y > 0) {
            const cx = pane.x + pane.cols;
            const cy = pane.y - 1;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= LEFT | DOWN;
            }
        }
        // 左下角（右と上に線が伸びる）
        if (pane.x > 0 and pane.y + pane.rows < H) {
            const cx = pane.x - 1;
            const cy = pane.y + pane.rows;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= RIGHT | UP;
            }
        }
        // 右下角（左と上に線が伸びる）
        if (pane.x + pane.cols < W and pane.y + pane.rows < H) {
            const cx = pane.x + pane.cols;
            const cy = pane.y + pane.rows;
            if (cx < W and cy < H) {
                border[@as(usize, cy) * W + cx] |= LEFT | UP;
            }
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

            try writer.print("\x1b[{d};{d}H\x1b[0m{s}", .{
                row + 1,
                col + 1,
                ch,
            });
        }
    }
}

pub fn invalidate(self: *Renderer) void {
    @memset(self.prev_cells, .{
        .codepoint = std.math.maxInt(u21), // 全セルを「前回と違う」状態にする
    });
}
