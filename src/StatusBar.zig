const std = @import("std");
const WorkspaceManager = @import("WorkspaceManager.zig");

pub const StatusBar = @This();

pub fn render(
    wm: *WorkspaceManager,
    status_row: u16,
    term_cols: u16,
    writer: anytype,
) !void {
    try writer.print("\x1b[{d};1H", .{status_row});
    try writer.writeAll("\x1b[0;100m");

    var written: u16 = 0;

    for (0..wm.workspaces.items.len) |i| {
        const is_active = (i == wm.active_workspace);

        if (is_active) {
            try writer.writeAll("\x1b[42;30m");
        }

        try writer.print(" {d} ", .{i + 1});
        written += 3;

        if (is_active) {
            try writer.writeAll("\x1b[100;37m");
        }
    }

    while (written < term_cols) : (written += 1) {
        try writer.writeByte(' ');
    }

    try writer.writeAll("\x1b[0m");
}
