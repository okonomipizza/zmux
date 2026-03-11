const std = @import("std");
const Pane = @import("Pane.zig");
const c = @import("c.zig").c;
pub const Workspace = @This();

panes: std.ArrayList(Pane),
active_pane: usize,
cols: u16,
rows: u16,
termios: c.termios,

pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, termios: c.termios) !Workspace {
    var panes = std.ArrayList(Pane){};
    errdefer panes.deinit(allocator);

    const first_pane = try Pane.init(termios, 1, 1, cols, rows);
    try panes.append(allocator, first_pane);

    return .{
        .panes = panes,
        .active_pane = 0,
        .cols = cols,
        .rows = rows,
        .termios = termios,
    };
}

pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
    for (self.panes.items) |*pane| {
        pane.deinit();
    }
    self.panes.deinit(allocator);
}

pub fn activePane(self: *Workspace) *Pane {
    return &self.panes.items[self.active_pane];
}

pub fn getPane(self: *Workspace, fd: c_int) ?*Pane {
    for (self.panes.items) |*pane| {
        if (pane.pty.master_fd == fd) {
            return pane;
        }
    }

    return null;
}

fn divPane(self: *Workspace, allocator: std.mem.Allocator, dir: SplitDir) !c_int {
    if (self.active_pane >= self.panes.items.len) return error.InvalidActivePane;
    const active_pane = self.panes.items[self.active_pane];

    const new_pane_size = try calcNewPaneSize(active_pane.x, active_pane.y, active_pane.cols, active_pane.rows, dir);
    const new_pane = try Pane.init(self.termios, new_pane_size.x, new_pane_size.y, new_pane_size.cols, new_pane_size.rows);

    try self.panes.append(allocator, new_pane);
    // 新しく追加したPaneをアクティブに設定する
    self.active_pane = self.panes.items.len;

    return new_pane.pty.master_fd;
}

const SplitDir = enum { vertical, horizontal };
const MINIMUM_PANE_SIZE: u16 = 4;

// active pane の開始位置を渡すと、active_paneを分割した場合に、
// 新しく作成されるpaneの開始位置を返す
fn calcNewPaneSize(x: u16, y: u16, cols: u16, rows: u16, dir: SplitDir) !struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
} {
    if (cols / 2 < MINIMUM_PANE_SIZE or rows / 2 < MINIMUM_PANE_SIZE) {
        return error.PaneTooSmall;
    }
    return switch (dir) {
        .vertical => {
            return .{
                .x = x + cols / 2 + 1,
                .y = y,
                .cols = cols / 2,
                .rows = rows,
            };
        },
        .horizontal => .{
            .x = x,
            .y = y + rows / 2 + 1,
            .cols = cols,
            .rows = rows / 2,
        },
    };
}

// 水平分割
// pub fn splitHorizontal(self: *Workspace) !void {
//
// }
