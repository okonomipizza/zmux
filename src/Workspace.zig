const std = @import("std");
const Pane = @import("Pane.zig");
const c = @import("c.zig").c;
pub const Workspace = @This();

// panes: std.ArrayList(Pane),
active_pane: *Pane,
cols: u16,
rows: u16,
termios: c.termios,
root: *PaneNode,

// ノードは分割されているか、されていないかのどっちか
const PaneNode = union(enum) {
    leaf: *Pane,
    split: struct {
        dir: SplitDir,
        ratio: f32,
        first: *PaneNode,
        second: *PaneNode,
    },

    pub fn deinit(self: *PaneNode, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => |pane| {
                pane.deinit(alloc);
                alloc.destroy(pane);
            },
            .split => |s| {
                s.first.deinit(alloc);
                alloc.destroy(s.first);
                s.second.deinit(alloc);
                alloc.destroy(s.second);
            },
        }
    }
};

pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, termios: c.termios) !Workspace {
    const pane = try alloc.create(Pane);
    errdefer alloc.destroy(pane);
    pane.* = try Pane.init(alloc, termios, 0, 0, cols, rows);

    const root = try alloc.create(PaneNode);
    errdefer alloc.destroy(root);
    root.* = .{ .leaf = pane };

    return .{
        // .panes = panes,
        .active_pane = pane,
        .cols = cols,
        .rows = rows,
        .termios = termios,
        .root = root,
    };
}

pub fn deinit(self: *Workspace, alloc: std.mem.Allocator) void {
    self.root.deinit(alloc);
}

fn deinitPanes(node: *PaneNode) void {
    switch (node) {
        .leaf => node,
    }
}

/// 現在のワークスペース内におけるアクティブペインへの参照を返す
pub fn activePane(self: *Workspace) *Pane {
    return self.active_pane;
}

/// 指定された fd を持つ ペインを返す
pub fn getPane(self: *Workspace, fd: c_int) ?*Pane {
    return findPane(self.root, fd);
}

fn findPane(node: *PaneNode, fd: c_int) ?*Pane {
    switch (node.*) {
        .leaf => |pane| {
            if (pane.pty.master_fd == fd) return pane;
            return null;
        },
        .split => |s| {
            return findPane(s.first, fd) orelse findPane(s.second, fd);
        },
    }
}

/// ペインを分割して epoll に登録すべき新しい fd を返す
pub fn splitPane(self: *Workspace, alloc: std.mem.Allocator, dir: SplitDir) !c_int {
    // active_paneを持つleafノードを探す
    const leaf_node = findLeafNode(self.root, self.active_pane) orelse return error.ActivePaneLost;
    const active = leaf_node.leaf;

    const new_size = try calcNewPaneSize(active.x, active.y, active.cols, active.rows, dir);

    // 既存ペインをリサイズ
    try active.resize(alloc, new_size.active_cols, new_size.active_rows);

    // 新しいペインを作成
    const new_pane = try alloc.create(Pane);
    errdefer alloc.destroy(new_pane);
    new_pane.* = try Pane.init(alloc, self.termios, new_size.x, new_size.y, new_size.cols, new_size.rows);

    // 子ノードを作成
    const first_node = try alloc.create(PaneNode);
    errdefer alloc.destroy(first_node);
    first_node.* = .{ .leaf = active };

    const second_node = try alloc.create(PaneNode);
    errdefer alloc.destroy(second_node);
    second_node.* = .{ .leaf = new_pane };

    // 元のleafノードをsplitに変換
    leaf_node.* = .{ .split = .{
        .dir = dir,
        .ratio = 0.5,
        .first = first_node,
        .second = second_node,
    } };

    // 新ペインをアクティブに
    self.active_pane = new_pane;

    return new_pane.pty.master_fd;
}

pub fn closePane(self: *Workspace, alloc: std.mem.Allocator) !void {
    if (self.root.* == .leaf) return;

    const result = findParentSplit(self.root, self.active_pane) orelse return;
    const parent = result.parent;
    const sibling = result.sibling;

    const closing_node = result.closing;
    const closing_pane = closing_node.leaf;
    closing_pane.deinit(alloc);
    alloc.destroy(closing_pane);
    alloc.destroy(closing_node);

    const sibling_copy = sibling.*;
    alloc.destroy(sibling);
    parent.* = sibling_copy;

    // ルートからワークスペース全体を再レイアウト
    try relayout(alloc, self.root, self.cols, self.rows, 0, 0);

    self.active_pane = firstLeaf(parent);
}

const FindResult = struct {
    parent: *PaneNode,
    closing: *PaneNode,
    sibling: *PaneNode,
};

fn findParentSplit(node: *PaneNode, target: *Pane) ?FindResult {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            // firstが閉じる対象か
            if (s.first.* == .leaf and s.first.leaf == target) {
                return .{ .parent = node, .closing = s.first, .sibling = s.second };
            }
            // secondが閉じる対象か
            if (s.second.* == .leaf and s.second.leaf == target) {
                return .{ .parent = node, .closing = s.second, .sibling = s.first };
            }
            // 再帰的に探す
            return findParentSplit(s.first, target) orelse findParentSplit(s.second, target);
        },
    }
}

fn firstLeaf(node: *PaneNode) *Pane {
    switch (node.*) {
        .leaf => |pane| return pane,
        .split => |s| return firstLeaf(s.first),
    }
}

/// ツリーを再帰的に走査して、各ペインの位置とサイズを再計算する
fn relayout(alloc: std.mem.Allocator, node: *PaneNode, cols: u16, rows: u16, x: u16, y: u16) !void {
    switch (node.*) {
        .leaf => |pane| {
            pane.x = x;
            pane.y = y;
            pane.cols = cols;
            pane.rows = rows;
            try pane.resize(alloc, cols, rows);
        },
        .split => |s| {
            switch (s.dir) {
                .vertical => {
                    const first_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(cols)) * s.ratio)) -| 1;
                    const second_cols = cols - first_cols - 1; // 1は境界線
                    try relayout(alloc, s.first, first_cols, rows, x, y);
                    try relayout(alloc, s.second, second_cols, rows, x + first_cols + 1, y);
                },
                .horizontal => {
                    const first_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(rows)) * s.ratio)) -| 1;
                    const second_rows = rows - first_rows - 1;
                    try relayout(alloc, s.first, cols, first_rows, x, y);
                    try relayout(alloc, s.second, cols, second_rows, x, y + first_rows + 1);
                },
            }
        },
    }
}

fn findLeafNode(node: *PaneNode, target: *Pane) ?*PaneNode {
    switch (node.*) {
        .leaf => |pane| {
            if (pane == target) return node;
            return null;
        },
        .split => |s| {
            return findLeafNode(s.first, target) orelse findLeafNode(s.second, target);
        },
    }
}

pub fn nextPane(self: *Workspace) void {
    var buf: [64]*Pane = undefined;
    const leaves = collectLeaves(self.root, &buf);
    if (leaves.len <= 1) return;

    for (leaves, 0..) |pane, i| {
        if (pane == self.active_pane) {
            self.active_pane = leaves[(i + 1) % leaves.len];
            return;
        }
    }
}

pub fn prevPane(self: *Workspace) void {
    var buf: [64]*Pane = undefined;
    const leaves = collectLeaves(self.root, &buf);
    if (leaves.len <= 1) return;

    for (leaves, 0..) |pane, i| {
        if (pane == self.active_pane) {
            self.active_pane = leaves[(i + leaves.len - 1) % leaves.len];
            return;
        }
    }
}

fn collectLeaves(node: *PaneNode, buf: []*Pane) []*Pane {
    var count: usize = 0;
    collectLeavesInner(node, buf, &count);
    return buf[0..count];
}

pub fn getPanes(self: *Workspace, buf: []*Pane) []*Pane {
    var count: usize = 0;
    collectLeavesInner(self.root, buf, &count);
    return buf[0..count];
}

fn collectLeavesInner(node: *PaneNode, buf: []*Pane, count: *usize) void {
    switch (node.*) {
        .leaf => |pane| {
            if (count.* < buf.len) {
                buf[count.*] = pane;
                count.* += 1;
            }
        },
        .split => |s| {
            collectLeavesInner(s.first, buf, count);
            collectLeavesInner(s.second, buf, count);
        },
    }
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
