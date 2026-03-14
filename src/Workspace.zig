const std = @import("std");
const Pane = @import("Pane.zig");
const c = @import("c.zig").c;
pub const Workspace = @This();

panes: std.ArrayList(Pane),
active_pane: usize,
cols: u16,
rows: u16,
termios: c.termios,

pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, termios: c.termios) !Workspace {
    var panes = std.ArrayList(Pane){};
    errdefer panes.deinit(alloc);

    const first_pane = try Pane.init(alloc, termios, 0, 0, cols, rows);
    try panes.append(alloc, first_pane);

    return .{
        .panes = panes,
        .active_pane = 0,
        .cols = cols,
        .rows = rows,
        .termios = termios,
    };
}

pub fn deinit(self: *Workspace, alloc: std.mem.Allocator) void {
    for (self.panes.items) |*pane| {
        pane.deinit(alloc);
    }
    self.panes.deinit(alloc);
}

/// 現在のワークスペース内におけるアクティブペインへの参照を返す
pub fn activePane(self: *Workspace) ?*Pane {
    if (self.panes.items.len == 0) return null;
    if (self.active_pane >= self.panes.items.len) {
        self.active_pane = 0;
        // TODO カーソル位置をリセットする必要があるかも
    }
    return &self.panes.items[self.active_pane];
}

/// 指定された fd を持つ ペインを返す
pub fn getPane(self: *Workspace, fd: c_int) ?*Pane {
    for (self.panes.items) |*pane| {
        if (pane.pty.master_fd == fd) {
            return pane;
        }
    }
    return null;
}

/// 指定された fd を持つペインの index を返す
pub fn getPaneIndex(self: *Workspace, fd: c_int) ?usize {
    for (self.panes.items, 0..) |*pane, i| {
        if (pane.pty.master_fd == fd) return i;
    }
    return null;
}

/// ペインを分割して epoll に登録すべき新しい fd を返す
pub fn splitPane(self: *Workspace, alloc: std.mem.Allocator, dir: SplitDir) !c_int {
    const active = self.activePane() orelse return error.ActivePaneLost;

    const new_size = try calcNewPaneSize(active.x, active.y, active.cols, active.rows, dir);

    // 既存のアクティブペインをリサイズ
    try active.resize(alloc, new_size.active_cols, new_size.active_rows);

    const new_pane = try Pane.init(alloc, self.termios, new_size.x, new_size.y, new_size.cols, new_size.rows);

    try self.panes.append(alloc, new_pane);

    // 新しく追加したPaneをアクティブに設定する
    self.active_pane = self.panes.items.len - 1;

    return self.panes.items[self.active_pane].pty.master_fd;
}

/// アクティブペインを切り替える
pub fn nextPain(self: *Workspace) void {
    if (self.panes.items.len == 0) return;
    self.active_pane = (self.active_pane + 1) % self.panes.items.len;
}

const NewPaneSize = struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
    // 分割前にactiveだった pane の分割後のサイズ
    active_cols: u16,
    active_rows: u16,
};

const SplitDir = enum { vertical, horizontal };
const MINIMUM_PANE_SIZE: u16 = 4;

// active pane の開始位置を渡すと、active_paneを分割した場合に、
// 新しく作成されるpaneの開始位置を返す
fn calcNewPaneSize(x: u16, y: u16, cols: u16, rows: u16, dir: SplitDir) !NewPaneSize {
    return switch (dir) {
        .vertical => {
            // 左右に分割
            if (cols / 2 < MINIMUM_PANE_SIZE) return error.PaneTooSmall;
            const new_cols = cols / 2;
            const active_cols = cols - new_cols - 1; // 1 は境界線の幅

            return .{
                .x = x + active_cols + 1,
                .y = y,
                .cols = new_cols,
                .rows = rows,
                .active_cols = active_cols,
                .active_rows = rows,
            };
        },
        .horizontal => {
            // 上下に分割
            if (rows / 2 < MINIMUM_PANE_SIZE) return error.PaneTooSmall;
            const new_rows = rows / 2;
            const active_rows = rows - new_rows - 1; // 1 は境界線の幅
            return .{
                .x = x,
                .y = y + active_rows + 1,
                .cols = cols,
                .rows = new_rows,
                .active_cols = cols,
                .active_rows = active_rows,
            };
        },
    };
}
