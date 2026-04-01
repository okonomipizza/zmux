const std = @import("std");
const Config = @import("Config.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");

pub const StatusBar = @This();

/// Japanese formal numerals (大字) for workspace numbers 1-10
const DAIJI = [_][]const u8{ "壱", "弐", "参", "肆", "伍", "陸", "漆", "捌", "玖", "拾" };

pub fn renderWithMode(
    wm: *WorkspaceManager,
    status_row: u16,
    term_cols: u16,
    writer: anytype,
    mode_label: ?[]const u8,
    config: Config,
) !void {
    try writer.print("\x1b[{d};1H", .{status_row});
    try writer.writeAll("\x1b[0m");
    try writer.writeAll(config.status_bg.toBgAnsiSeq());
    try writer.writeAll(config.status_fg.toFgAnsiSeq());

    var written: u16 = 0;

    for (0..wm.workspaces.items.len) |i| {
        const is_active = (i == wm.active_workspace);

        if (is_active) {
            try writer.writeAll(config.active_workspace_bg.toBgAnsiSeq());
            try writer.writeAll(config.active_workspace_fg.toFgAnsiSeq());
        }

        // Use 大字 for numbers 1-10, fallback to regular digits for > 10
        if (i < DAIJI.len) {
            try writer.writeByte(' ');
            try writer.writeAll(DAIJI[i]);
            try writer.writeByte(' ');
            written += 4; // space + full-width char (2 cols) + space
        } else {
            try writer.print(" {d} ", .{i + 1});
            written += 3;
        }

        if (is_active) {
            try writer.writeAll(config.status_bg.toBgAnsiSeq());
            try writer.writeAll(config.status_fg.toFgAnsiSeq());
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
            try writer.writeAll(config.mode_label_bg.toBgAnsiSeq());
            try writer.writeAll(config.mode_label_fg.toFgAnsiSeq());
            try writer.writeByte(' ');
            try writer.writeAll(label);
            try writer.writeByte(' ');
            try writer.writeAll(config.status_bg.toBgAnsiSeq());
            try writer.writeAll(config.status_fg.toFgAnsiSeq());
            written += label_len;
        }
    }

    while (written < term_cols) : (written += 1) {
        try writer.writeByte(' ');
    }

    try writer.writeAll("\x1b[0m");
}
