const std = @import("std");

/// Resource limits enforced server-side to prevent memory / process exhaustion.

pub const MIN_COLS: u16 = 10;
pub const MIN_ROWS: u16 = 4;
pub const MAX_COLS: u16 = 512;
pub const MAX_ROWS: u16 = 256;

/// Matches the workspace keys documented in the README (1-9).
pub const MAX_WORKSPACES: usize = 9;

pub fn clampTermSize(cols: u16, rows: u16) struct { cols: u16, rows: u16 } {
    return .{
        .cols = @min(@max(cols, MIN_COLS), MAX_COLS),
        .rows = @min(@max(rows, MIN_ROWS), MAX_ROWS),
    };
}

test "clampTermSize enforces min and max bounds" {
    const small = clampTermSize(1, 1);
    try std.testing.expectEqual(MIN_COLS, small.cols);
    try std.testing.expectEqual(MIN_ROWS, small.rows);

    const huge = clampTermSize(65535, 65535);
    try std.testing.expectEqual(MAX_COLS, huge.cols);
    try std.testing.expectEqual(MAX_ROWS, huge.rows);

    const normal = clampTermSize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), normal.cols);
    try std.testing.expectEqual(@as(u16, 40), normal.rows);
}
