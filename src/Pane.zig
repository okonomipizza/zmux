const std = @import("std");
const Pty = @import("Pty.zig");
const Terminal = @import("ghostty-vt").Terminal;

const c = @import("c.zig").c;

pub const Pane = @This();

pty: Pty,
// lib-ghostty でターミナルのバッファを管理
terminal: Terminal,
x: u16, // 端末上の左端列 (0-indexed)
y: u16, // 端末上の上端行 (0-indexed)
cols: u16, // 横幅
rows: u16, // 縦幅
is_active: bool,

pub fn init(
    alloc: std.mem.Allocator,
    termios: c.termios,
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
) !Pane {
    return .{
        .pty = try Pty.init(cols, rows, termios),
        .terminal = try Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
        }),
        .x = x,
        .y = y,
        .cols = cols,
        .rows = rows,
        .is_active = false,
    };
}

pub fn deinit(self: *Pane, alloc: std.mem.Allocator) void {
    self.pty.deinit();
    self.terminal.deinit(alloc);
}

/// PTYからの出力をVTパーサで処理してスクリーンバッファを更新
pub fn feed(self: *Pane, data: []const u8) !void {
    var stream = self.terminal.vtStream();
    defer stream.deinit();

    try stream.nextSlice(data);
}

pub fn resize(
    self: *Pane,
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
) !void {
    self.cols = cols;
    self.rows = rows;
    try self.terminal.resize(alloc, cols, rows);
    try self.pty.resize(cols, rows);
}

pub fn activate(self: *Pane, writer: *std.Io.Writer) !void {
    // スクロール領域を設定（上端y 〜 下端y+rows-1）
    try writer.print("\x1b[{d};{d}r", .{ self.y, self.y + self.rows - 1 });
    // カーソルをペインの左上へ
    try writer.print("\x1b[{d};{d}H", .{ self.y, self.x });

    try writer.flush();

    self.is_active = true;
}

/// ペインの境界線を描画（縦線）
pub fn drawBorder(self: *Pane, writer: *std.Io.Writer) !void {
    if (self.x == 1) return; // 一番左のペインは左ボーダー不要
    var row: u16 = self.y;
    while (row < self.y + self.rows) : (row += 1) {
        try writer.print("\x1b[{d};{d}H│", .{ row, self.x - 1 });
    }

    try writer.flush();
}
