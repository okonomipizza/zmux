const std = @import("std");
const WorkspaceManager = @import("WorkspaceManager.zig");

pub const StatusBar = @This();

pub fn render(
    wm: *WorkspaceManager,
    status_row: u16,
    term_cols: u16,
    writer: anytype,
) !void {
    try renderWithMode(wm, status_row, term_cols, writer, null);
}

pub fn renderWithMode(
    wm: *WorkspaceManager,
    status_row: u16,
    term_cols: u16,
    writer: anytype,
    mode_label: ?[]const u8,
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

    // Show mode indicator on the right side
    if (mode_label) |label| {
        const label_len: u16 = @intCast(label.len + 2); // " COPY "
        if (written + label_len < term_cols) {
            // Fill space up to the label
            const padding = term_cols - written - label_len;
            for (0..padding) |_| {
                try writer.writeByte(' ');
            }
            written += padding;
            // Render mode label with highlight
            try writer.writeAll("\x1b[43;30m");
            try writer.writeByte(' ');
            try writer.writeAll(label);
            try writer.writeByte(' ');
            try writer.writeAll("\x1b[100;37m");
            written += label_len;
        }
    }

    while (written < term_cols) : (written += 1) {
        try writer.writeByte(' ');
    }

    try writer.writeAll("\x1b[0m");
}
