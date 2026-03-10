// StatusBar.zig
const std = @import("std");

pub const StatusBar = @This();

cols: u16,
rows: u16,

pub fn init(cols: u16, rows: u16) StatusBar {
    return .{ .cols = cols, .rows = rows };
}

/// ステータスバーを描画する
/// エスケープシーケンス：
///   \x1b[{row};{col}H  → カーソル移動
///   \x1b[7m            → 反転表示（背景と文字色を入れ替え）
///   \x1b[m             → 属性リセット
///   \x1b[s / \x1b[u   → カーソル位置保存/復元
pub fn draw(self: StatusBar, writer: *std.Io.Writer) !void {
    const left = "0  1  2";
    const right = "zmux";

    // 左右の間のスペース数を計算
    // const used = left.len + right.len;
    // const spaces = if (self.cols > used) self.cols - used else 0;

    // カーソル保存 → 最終行へ移動 → 反転表示 → 描画 → リセット → カーソル復元
    try writer.writeAll("\x1b[s"); // カーソル保存
    try writer.print("\x1b[{d};1H", .{self.rows}); // 最終行の先頭へ
    try writer.writeAll("\x1b[7m"); // 反転表示ON
    try writer.writeAll(left);
    // try writer.write(' '); // 中央の空白
    try writer.writeAll(right);
    try writer.writeAll("\x1b[m"); // 属性リセット
    try writer.writeAll("\x1b[u"); // カーソル復元
}

/// PTYのスクロール領域を rows-1 行に制限する
/// これで bash の出力がステータスバーを上書きしない
pub fn setScrollRegion(rows: u16, writer: anytype) !void {
    // \x1b[{top};{bottom}r → スクロール領域を設定
    try writer.print("\x1b[1;{d}r", .{rows - 1});
}

/// 終了時にスクロール領域をリセット
pub fn resetScrollRegion(writer: anytype) !void {
    try writer.writeAll("\x1b[r");
}
