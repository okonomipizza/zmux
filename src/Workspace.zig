const std = @import("std");
const Pane = @import("Pane.zig");
const c = @import("c.zig").c;
pub const Workspace = @This();

active_pane: *Pane,
floating_pane: *Pane,
cols: u16,
rows: u16,
termios: c.termios,
root: *PaneNode,
show_floating: bool,

/// A tree is used to represent the relationships among split panes.
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
    pane.vt_stream = pane.terminal.vtStream();

    const floating_geometry = calcFloatingGeometry(cols, rows);

    const floating_pane = try alloc.create(Pane);
    errdefer alloc.destroy(floating_pane);
    floating_pane.* = try Pane.init(
        alloc,
        termios,
        floating_geometry.x,
        floating_geometry.y,
        floating_geometry.cols,
        floating_geometry.rows,
    );
    floating_pane.vt_stream = floating_pane.terminal.vtStream();

    const root = try alloc.create(PaneNode);
    errdefer alloc.destroy(root);
    root.* = .{ .leaf = pane };

    return .{
        .active_pane = pane,
        .floating_pane = floating_pane,
        .cols = cols,
        .rows = rows,
        .termios = termios,
        .root = root,
        .show_floating = false,
    };
}

const FloatingGeometry = struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
};

fn calcFloatingGeometry(ws_cols: u16, ws_rows: u16) FloatingGeometry {
    const float_cols: u16 = @max(ws_cols * 8 / 10, 10);
    const float_rows: u16 = @max(ws_rows * 8 / 10, 4);
    const x: u16 = (ws_cols -| float_cols) / 2;
    const y: u16 = (ws_rows -| float_rows) / 2;

    return .{
        .x = x,
        .y = y,
        .cols = float_cols,
        .rows = float_rows,
    };
}

pub fn deinit(self: *Workspace, alloc: std.mem.Allocator) void {
    self.root.deinit(alloc);
    alloc.destroy(self.root);
    self.floating_pane.deinit(alloc);
    alloc.destroy(self.floating_pane);
}

fn deinitPanes(node: *PaneNode) void {
    switch (node) {
        .leaf => node,
    }
}

pub fn activePane(self: *Workspace) *Pane {
    return self.active_pane;
}

pub fn getPane(self: *Workspace, fd: c_int) ?*Pane {
    if (self.floating_pane.pty.master_fd == fd) return self.floating_pane;
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

/// Split panes and returns new pane's master_fd
/// New pane will be a next active pane
pub fn splitPane(self: *Workspace, alloc: std.mem.Allocator, dir: SplitDir) !c_int {
    // Find the active pane node
    const leaf_node = findLeafNode(self.root, self.active_pane) orelse return error.ActivePaneLost;
    const active = leaf_node.leaf;

    const new_size = try calcNewPaneSize(active.x, active.y, active.cols, active.rows, dir);

    try active.resize(alloc, new_size.active_cols, new_size.active_rows);

    const new_pane = try alloc.create(Pane);
    errdefer alloc.destroy(new_pane);
    new_pane.* = try Pane.init(alloc, self.termios, new_size.x, new_size.y, new_size.cols, new_size.rows);
    new_pane.vt_stream = new_pane.terminal.vtStream();

    const first_node = try alloc.create(PaneNode);
    errdefer alloc.destroy(first_node);
    first_node.* = .{ .leaf = active };

    const second_node = try alloc.create(PaneNode);
    errdefer alloc.destroy(second_node);
    second_node.* = .{ .leaf = new_pane };

    leaf_node.* = .{ .split = .{
        .dir = dir,
        .ratio = 0.5,
        .first = first_node,
        .second = second_node,
    } };

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
            if (s.first.* == .leaf and s.first.leaf == target) {
                return .{ .parent = node, .closing = s.first, .sibling = s.second };
            }
            if (s.second.* == .leaf and s.second.leaf == target) {
                return .{ .parent = node, .closing = s.second, .sibling = s.first };
            }
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

/// Calculate all panes size
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
                    const second_cols = cols - first_cols - 1; // 1 is for border width
                    try relayout(alloc, s.first, first_cols, rows, x, y);
                    try relayout(alloc, s.second, second_cols, rows, x + first_cols + 1, y);
                },
                .horizontal => {
                    const first_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(rows)) * s.ratio)) -| 1;
                    const second_rows = rows - first_rows - 1; // 1 is for border height
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
    // The size of original pane after splitting
    active_cols: u16,
    active_rows: u16,
};

pub const SplitDir = enum { vertical, horizontal };
const MINIMUM_PANE_SIZE: u16 = 4;

// Start position and size of the (active) pane will be splitted is needed for calculating new pane size
fn calcNewPaneSize(x: u16, y: u16, cols: u16, rows: u16, dir: SplitDir) !NewPaneSize {
    return switch (dir) {
        .vertical => {
            if (cols / 2 < MINIMUM_PANE_SIZE) return error.PaneTooSmall;
            const new_cols = cols / 2;
            const active_cols = cols - new_cols - 1; // 1 is width for border line

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
            if (rows / 2 < MINIMUM_PANE_SIZE) return error.PaneTooSmall;
            const new_rows = rows / 2;
            const active_rows = rows - new_rows - 1; // 1 is height for border line
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

/// アクティブペインの親splitのratioを調整してリサイズ
pub fn resizePane(self: *Workspace, alloc: std.mem.Allocator, delta: f32) !void {
    const info = findParentOf(self.root, self.active_pane) orelse return;

    switch (info.parent.*) {
        .split => |*s| {
            if (info.is_first) {
                s.ratio = std.math.clamp(s.ratio + delta, 0.1, 0.9);
            } else {
                s.ratio = std.math.clamp(s.ratio - delta, 0.1, 0.9);
            }
        },
        .leaf => return,
    }

    try relayout(alloc, self.root, self.cols, self.rows, 0, 0);
}

const ParentInfo = struct {
    parent: *PaneNode,
    is_first: bool,
};

fn findParentOf(node: *PaneNode, target: *Pane) ?ParentInfo {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if (s.first.* == .leaf and s.first.leaf == target)
                return .{ .parent = node, .is_first = true };
            if (s.second.* == .leaf and s.second.leaf == target)
                return .{ .parent = node, .is_first = false };
            return findParentOf(s.first, target) orelse findParentOf(s.second, target);
        },
    }
}

pub const Direction = enum { left, right, up, down };

/// 指定方向の隣接ペインにフォーカスを移す
pub fn focusPane(self: *Workspace, dir: Direction) void {
    const target = findAdjacentPane(self.root, self.active_pane, dir) orelse return;
    self.active_pane = target;
}

pub fn swapPane(self: *Workspace, alloc: std.mem.Allocator, dir: Direction) !void {
    const active = self.active_pane;
    const target = findAdjacentPane(self.root, active, dir) orelse return;

    const tmp_x = active.x;
    const tmp_y = active.y;
    const tmp_cols = active.cols;
    const tmp_rows = active.rows;

    active.x = target.x;
    active.y = target.y;
    try active.resize(alloc, target.cols, target.rows);

    target.x = tmp_x;
    target.y = tmp_y;
    try target.resize(alloc, tmp_cols, tmp_rows);

    swapLeafPointers(self.root, active, target);
}

fn findAdjacentPane(root: *PaneNode, active: *Pane, dir: Direction) ?*Pane {
    var buf: [64]*Pane = undefined;
    const leaves = collectLeaves(root, &buf);

    var best: ?*Pane = null;
    var best_gap: i32 = std.math.maxInt(i32);
    var best_overlap: i32 = 0;

    const ax: i32 = @intCast(active.x);
    const ay: i32 = @intCast(active.y);
    const aw: i32 = @intCast(active.cols);
    const ah: i32 = @intCast(active.rows);

    for (leaves) |pane| {
        if (pane == active) continue;

        const px: i32 = @intCast(pane.x);
        const py: i32 = @intCast(pane.y);
        const pw: i32 = @intCast(pane.cols);
        const ph: i32 = @intCast(pane.rows);

        // 主軸方向のギャップ (ペイン端同士の距離) と
        // 副軸方向のオーバーラップ量で判定する
        var gap: i32 = undefined;
        var overlap: i32 = undefined;

        switch (dir) {
            .down => {
                if (py < ay + ah) continue; // 下側にない
                gap = py - (ay + ah);
                overlap = @min(ax + aw, px + pw) - @max(ax, px);
            },
            .up => {
                if (py + ph > ay) continue; // 上側にない
                gap = ay - (py + ph);
                overlap = @min(ax + aw, px + pw) - @max(ax, px);
            },
            .right => {
                if (px < ax + aw) continue; // 右側にない
                gap = px - (ax + aw);
                overlap = @min(ay + ah, py + ph) - @max(ay, py);
            },
            .left => {
                if (px + pw > ax) continue; // 左側にない
                gap = ax - (px + pw);
                overlap = @min(ay + ah, py + ph) - @max(ay, py);
            },
        }

        if (overlap <= 0) continue; // 副軸方向に重なりがない

        if (gap < best_gap) {
            best_gap = gap;
            best_overlap = overlap;
            best = pane;
        } else if (gap == best_gap) {
            // 同距離の場合: 方向に応じた位置優先でタイブレーク
            // down/right → 左上を優先、up/left → 右下を優先
            const bx = @as(i32, @intCast(best.?.x));
            const prefer = switch (dir) {
                .down, .right => px < bx,
                .up, .left => px > bx,
            };
            if (prefer or (!prefer and px == bx and overlap > best_overlap)) {
                best_gap = gap;
                best_overlap = overlap;
                best = pane;
            }
        }
    }
    return best;
}

fn swapLeafPointers(node: *PaneNode, a: *Pane, b: *Pane) void {
    switch (node.*) {
        .leaf => |*pane_ptr| {
            if (pane_ptr.* == a) pane_ptr.* = b else if (pane_ptr.* == b) pane_ptr.* = a;
        },
        .split => |s| {
            swapLeafPointers(s.first, a, b);
            swapLeafPointers(s.second, a, b);
        },
    }
}

/// アクティブペインをツリーから切り離して返す。
/// Pane 自体は deinit しない（別ワークスペースで再利用するため）。
/// ルートが leaf（ペインが1つだけ）の場合は null を返す。
/// → 呼び出し側で extractLastPane を使うこと。
pub fn detachPane(self: *Workspace, alloc: std.mem.Allocator) !?*Pane {
    const target = self.active_pane;

    if (self.root.* == .leaf) {
        return null;
    }

    const result = findParentSplit(self.root, target) orelse return error.ActivePaneLost;
    const parent = result.parent;
    const sibling = result.sibling;
    const closing_node = result.closing;

    // PaneNode だけ解放。Pane 自体は移動先で使うので解放しない。
    alloc.destroy(closing_node);

    // 兄弟ノードで親を上書き
    const sibling_copy = sibling.*;
    alloc.destroy(sibling);
    parent.* = sibling_copy;

    try relayout(alloc, self.root, self.cols, self.rows, 0, 0);

    self.active_pane = firstLeaf(parent);

    return target;
}

/// ルートが leaf 1つだけの場合に、そのペインを取り出す。
/// 呼び出し後、このワークスペースは無効になるため削除すること。
pub fn extractLastPane(self: *Workspace) *Pane {
    return self.root.leaf;
}

/// 外部から渡されたペインをこのワークスペースに挿入する。
/// 既存ツリーの右側に vertical split で追加する。
pub fn attachPane(self: *Workspace, alloc: std.mem.Allocator, pane: *Pane) !void {
    const new_cols = self.cols / 2;
    const first_cols = self.cols - new_cols - 1; // 1 は境界線

    // 挿入するペインの位置・サイズを設定
    pane.x = first_cols + 1;
    pane.y = 0;
    try pane.resize(alloc, new_cols, self.rows);

    try relayout(alloc, self.root, first_cols, self.rows, 0, 0);

    // 新しい leaf ノード
    const new_leaf = try alloc.create(PaneNode);
    errdefer alloc.destroy(new_leaf);
    new_leaf.* = .{ .leaf = pane };

    // 既存ルートを first 側に退避
    const old_root = try alloc.create(PaneNode);
    errdefer alloc.destroy(old_root);
    old_root.* = self.root.*;

    // ルートを split に書き換え
    self.root.* = .{ .split = .{
        .dir = .vertical,
        .ratio = 0.5,
        .first = old_root,
        .second = new_leaf,
    } };

    self.active_pane = pane;
}

/// フローティングペインの表示をトグルする。
/// 表示時: フローティングにフォーカスを移す
/// 非表示時: タイルツリーの先頭ペインにフォーカスを戻す
pub fn toggleFloating(self: *Workspace) void {
    self.show_floating = !self.show_floating;
    if (self.show_floating) {
        self.active_pane = self.floating_pane;
        // Reset viewport to bottom to show current cursor position
        self.floating_pane.terminal.scrollViewport(.{ .bottom = {} });
    } else {
        self.active_pane = firstLeaf(self.root);
    }
}

/// ワークスペース全体をリサイズする（タイルペイン + フローティングペイン）
pub fn resizeWorkspace(self: *Workspace, alloc: std.mem.Allocator, cols: u16, rows: u16) !void {
    self.cols = cols;
    self.rows = rows;

    // タイルペインをリレイアウト
    try relayout(alloc, self.root, cols, rows, 0, 0);

    // フローティングペインをリサイズ
    const fg = calcFloatingGeometry(cols, rows);
    self.floating_pane.x = fg.x;
    self.floating_pane.y = fg.y;
    try self.floating_pane.resize(alloc, fg.cols, fg.rows);
}
