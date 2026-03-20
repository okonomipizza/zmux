const std = @import("std");
const Pane = @import("Pane.zig");

pub const CopyMode = @This();

cursor_x: u16,
cursor_y: u16,
selecting: bool,
sel_start_x: u16,
sel_start_y: u16,

pub fn init(pane: *Pane) CopyMode {
    const screen = pane.terminal.screens.active;
    return .{
        .cursor_x = @intCast(screen.cursor.x),
        .cursor_y = @intCast(screen.cursor.y),
        .selecting = false,
        .sel_start_x = 0,
        .sel_start_y = 0,
    };
}

pub fn moveLeft(self: *CopyMode) void {
    self.cursor_x -|= 1;
}

pub fn moveRight(self: *CopyMode, pane: *Pane) void {
    if (self.cursor_x + 1 < pane.cols) self.cursor_x += 1;
}

pub fn moveUp(self: *CopyMode, pane: *Pane) void {
    if (self.cursor_y > 0) {
        self.cursor_y -= 1;
    } else {
        pane.terminal.scrollViewport(.{ .delta = -1 });
    }
}

pub fn moveDown(self: *CopyMode, pane: *Pane) void {
    if (self.cursor_y + 1 < pane.rows) {
        self.cursor_y += 1;
    } else {
        pane.terminal.scrollViewport(.{ .delta = 1 });
    }
}

pub fn startSelection(self: *CopyMode) void {
    self.selecting = true;
    self.sel_start_x = self.cursor_x;
    self.sel_start_y = self.cursor_y;
}

pub fn beginOfLine(self: *CopyMode) void {
    self.cursor_x = 0;
}

pub fn endOfLine(self: *CopyMode, pane: *Pane) void {
    self.cursor_x = pane.cols -| 1;
}

pub fn topOfScreen(self: *CopyMode) void {
    self.cursor_y = 0;
}

pub fn bottomOfScreen(self: *CopyMode, pane: *Pane) void {
    self.cursor_y = pane.rows -| 1;
}

pub fn halfPageUp(self: *CopyMode, pane: *Pane) void {
    const half = pane.rows / 2;
    if (self.cursor_y >= half) {
        self.cursor_y -= half;
    } else {
        const scroll_amount = half - self.cursor_y;
        self.cursor_y = 0;
        pane.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(scroll_amount)) });
    }
}

pub fn halfPageDown(self: *CopyMode, pane: *Pane) void {
    const half = pane.rows / 2;
    if (self.cursor_y + half < pane.rows) {
        self.cursor_y += half;
    } else {
        const overflow = (self.cursor_y + half) -| (pane.rows - 1);
        self.cursor_y = pane.rows - 1;
        if (overflow > 0) {
            pane.terminal.scrollViewport(.{ .delta = @intCast(overflow) });
        }
    }
}

pub fn nextWord(self: *CopyMode, pane: *Pane) void {
    const screen = pane.terminal.screens.active;
    var x = self.cursor_x;
    var y = self.cursor_y;

    // Skip current word (non-space characters)
    while (y < pane.rows) {
        const ch = getChar(screen, x, y);
        if (ch == ' ' or ch == 0) break;
        x += 1;
        if (x >= pane.cols) {
            x = 0;
            y += 1;
        }
    }
    // Skip spaces
    while (y < pane.rows) {
        const ch = getChar(screen, x, y);
        if (ch != ' ' and ch != 0) break;
        x += 1;
        if (x >= pane.cols) {
            x = 0;
            y += 1;
        }
    }

    if (y < pane.rows) {
        self.cursor_x = x;
        self.cursor_y = y;
    }
}

pub fn prevWord(self: *CopyMode, pane: *Pane) void {
    const screen = pane.terminal.screens.active;
    var x = self.cursor_x;
    var y = self.cursor_y;

    // Move back one
    if (x > 0) {
        x -= 1;
    } else if (y > 0) {
        y -= 1;
        x = pane.cols - 1;
    } else return;

    // Skip spaces backward
    while (true) {
        const ch = getChar(screen, x, y);
        if (ch != ' ' and ch != 0) break;
        if (x > 0) {
            x -= 1;
        } else if (y > 0) {
            y -= 1;
            x = pane.cols - 1;
        } else break;
    }
    // Skip word backward to find start
    while (true) {
        if (x > 0) {
            const prev_ch = getChar(screen, x - 1, y);
            if (prev_ch == ' ' or prev_ch == 0) break;
            x -= 1;
        } else if (y > 0) {
            const prev_ch = getChar(screen, pane.cols - 1, y - 1);
            if (prev_ch == ' ' or prev_ch == 0) break;
            y -= 1;
            x = pane.cols - 1;
        } else break;
    }

    self.cursor_x = x;
    self.cursor_y = y;
}

fn getChar(screen: anytype, x: u16, y: u16) u21 {
    const lc = screen.pages.getCell(.{
        .viewport = .{ .x = @intCast(x), .y = @intCast(y) },
    }) orelse return 0;
    return lc.cell.codepoint();
}

/// Check if a cell is within the selection
pub fn isSelected(self: *const CopyMode, x: u16, y: u16) bool {
    if (!self.selecting) return false;

    var start_y = self.sel_start_y;
    var start_x = self.sel_start_x;
    var end_y = self.cursor_y;
    var end_x = self.cursor_x;

    if (start_y > end_y or (start_y == end_y and start_x > end_x)) {
        const tmp_y = start_y;
        const tmp_x = start_x;
        start_y = end_y;
        start_x = end_x;
        end_y = tmp_y;
        end_x = tmp_x;
    }

    if (y < start_y or y > end_y) return false;
    if (y == start_y and y == end_y) return x >= start_x and x <= end_x;
    if (y == start_y) return x >= start_x;
    if (y == end_y) return x <= end_x;
    return true;
}

/// Extract selected text as a string
pub fn getSelectedText(self: *CopyMode, alloc: std.mem.Allocator, pane: *Pane) ![]u8 {
    const screen = pane.terminal.screens.active;

    var start_y = self.sel_start_y;
    var start_x = self.sel_start_x;
    var end_y = self.cursor_y;
    var end_x = self.cursor_x;

    // Normalize: start should be before end
    if (start_y > end_y or (start_y == end_y and start_x > end_x)) {
        const tmp_y = start_y;
        const tmp_x = start_x;
        start_y = end_y;
        start_x = end_x;
        end_y = tmp_y;
        end_x = tmp_x;
    }

    var text_buf: std.ArrayList(u8) = .empty;
    errdefer text_buf.deinit(alloc);

    var y = start_y;
    while (y <= end_y) : (y += 1) {
        const row_start: u16 = if (y == start_y) start_x else 0;
        const row_end: u16 = if (y == end_y) end_x else pane.cols - 1;

        var last_non_space: usize = text_buf.items.len;

        var x = row_start;
        while (x <= row_end) : (x += 1) {
            const lc = screen.pages.getCell(.{
                .viewport = .{ .x = @intCast(x), .y = @intCast(y) },
            }) orelse continue;
            const cell = lc.cell;

            // Skip spacer tails (part of wide chars)
            if (cell.wide == .spacer_tail) continue;

            const cp = cell.codepoint();
            if (cp == 0) {
                try text_buf.append(alloc, ' ');
            } else {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                try text_buf.appendSlice(alloc, utf8_buf[0..len]);

                // Handle grapheme clusters
                if (cell.content_tag == .codepoint_grapheme) {
                    const page = &lc.node.data;
                    if (page.lookupGrapheme(cell)) |cps| {
                        for (cps) |gcp| {
                            const glen = std.unicode.utf8Encode(gcp, &utf8_buf) catch continue;
                            try text_buf.appendSlice(alloc, utf8_buf[0..glen]);
                        }
                    }
                }

                last_non_space = text_buf.items.len;
            }
        }

        // Trim trailing spaces on this line
        text_buf.shrinkRetainingCapacity(last_non_space);

        // Add newline between rows (but not after last)
        if (y < end_y) {
            try text_buf.append(alloc, '\n');
        }
    }

    return text_buf.toOwnedSlice(alloc);
}
