const std = @import("std");
const Pty = @import("Pty.zig");
const Terminal = @import("ghostty-vt").Terminal;
const ReadonlyStream = @import("ghostty-vt").ReadonlyStream;

const c = @import("c.zig").c;

pub const Pane = @This();

pty: Pty,
// lib-ghostty でターミナルのバッファを管理
terminal: Terminal,
// VT パーサーストリーム: エスケープシーケンスが read() をまたいで分割されても
// 状態を保持するため、Pane の生存期間と同じにする。
// 注意: vtStream() は &terminal へのポインタを持つため、
//       heap 配置後に terminal.vtStream() で初期化すること。
vt_stream: ReadonlyStream,
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
        // vt_stream は heap 配置後に呼び出し元が terminal.vtStream() で設定する
        .vt_stream = undefined,
        .x = x,
        .y = y,
        .cols = cols,
        .rows = rows,
        .is_active = false,
    };
}

pub fn deinit(self: *Pane, alloc: std.mem.Allocator) void {
    self.pty.deinit();
    self.vt_stream.deinit();
    self.terminal.deinit(alloc);
}

/// PTYからの出力をVTパーサで処理してスクリーンバッファを更新
pub fn feed(self: *Pane, data: []const u8) !void {
    try self.vt_stream.nextSlice(data);
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
