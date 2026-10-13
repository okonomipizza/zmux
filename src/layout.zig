//! The pane tree: how a session's area is divided between programs.
//!
//! A workspace is a binary tree. Leaves are panes and interior nodes are splits,
//! each with an axis and the fraction of space the first child gets. A tree
//! rather than a list of rectangles because splitting a pane has to divide
//! exactly the space that pane occupied, and because closing a pane has to give
//! its space back to its sibling rather than to the whole window.
//!
//! Panes are addressed by `PaneId`, a counter, and never by pointer or index. The
//! tree is rebuilt as panes are added and removed, so a pointer into it would not
//! survive the next split, and an index would change meaning when a sibling is
//! closed. An identifier stays valid until the pane itself is gone, which is what
//! lets focus, the float list and the client's idea of which pane is which all
//! refer to a pane without holding the tree still.
//!
//! Geometry is computed, never stored. `layout` walks the tree and writes a
//! rectangle per pane; nothing else records positions, so a resize is one walk
//! rather than a migration of stored coordinates that could disagree with the
//! tree.

const std = @import("std");

/// A stable handle for one pane.
pub const PaneId = u64;

/// A rectangle in cells.
///
/// All four fields are absolute and zero-based: `x` and `y` are the top-left
/// cell, and `width` and `height` count cells. Keeping them absolute rather than
/// relative means drawing a pane needs no accumulated offset, which is where
/// off-by-one errors in nested splits usually come from.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.width == other.width and self.height == other.height;
    }
};

/// Which way a split divides its rectangle.
pub const Axis = enum {
    /// Children are side by side; the split line is vertical.
    horizontal,
    /// Children are stacked; the split line is horizontal.
    vertical,
};

pub const Error = error{
    /// No pane has that identifier.
    NoSuchPane,
    /// The tree has no room for another node.
    OutOfMemory,
    /// A ratio outside the range the tree can represent.
    BadRatio,
};

/// A node is either a pane or a split between two subtrees.
const Node = union(enum) {
    leaf: PaneId,
    branch: struct {
        axis: Axis,
        /// The fraction of the rectangle the first child gets, in (0, 1).
        ratio: f32,
        first: *Node,
        second: *Node,
    },

    fn deinit(self: *Node, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => {},
            .branch => |node_split| {
                node_split.first.deinit(gpa);
                node_split.second.deinit(gpa);
                gpa.destroy(node_split.first);
                gpa.destroy(node_split.second);
            },
        }
    }
};

/// One pane's place in the tree, plus the size it was laid out at.
pub const Placement = struct {
    id: PaneId,
    rect: Rect,
};

/// The tree of panes filling one session's area.
pub const Tree = struct {
    gpa: std.mem.Allocator,
    root: ?*Node = null,
    /// The pane that has focus, or null when the tree is empty.
    focused: ?PaneId = null,
    /// Handed out to panes so that each has an identifier no other can take,
    /// even after panes have been closed and their slots reused.
    next_id: PaneId = 1,

    pub fn init(gpa: std.mem.Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tree) void {
        if (self.root) |root| {
            root.deinit(self.gpa);
            self.gpa.destroy(root);
        }
        self.root = null;
        self.focused = null;
    }

    pub fn isEmpty(self: Tree) bool {
        return self.root == null;
    }

    /// Allocate an identifier for a new pane.
    ///
    /// Identifiers are never reused within a session, so a stale reference from a
    /// client names a pane that no longer exists rather than a different pane that
    /// took its identifier.
    pub fn allocateId(self: *Tree) PaneId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Put the first pane in the tree, filling it entirely.
    pub fn setRoot(self: *Tree, id: PaneId) !void {
        std.debug.assert(self.root == null);
        const node = try self.gpa.create(Node);
        node.* = .{ .leaf = id };
        self.root = node;
        self.focused = id;
    }

    /// Split the pane `target` in two.
    ///
    /// The existing pane keeps the first half and `new_id` takes the second, so
    /// the pane the user was looking at stays where it was and the new one appears
    /// after it. Focus moves to the new pane, which is what makes a split useful
    /// immediately: the next thing typed goes into the new program.
    pub fn split(self: *Tree, target: PaneId, axis: Axis, new_id: PaneId) !void {
        const leaf = self.findLeaf(target) orelse return Error.NoSuchPane;

        const first = try self.gpa.create(Node);
        errdefer self.gpa.destroy(first);
        const second = try self.gpa.create(Node);
        errdefer self.gpa.destroy(second);

        // The leaf's identifier is read before the leaf is overwritten.
        first.* = leaf.*;
        second.* = .{ .leaf = new_id };

        leaf.* = .{ .branch = .{
            .axis = axis,
            .ratio = 0.5,
            .first = first,
            .second = second,
        } };

        self.focused = new_id;
    }

    /// Remove a pane, giving its space to its sibling.
    ///
    /// Returns the pane that should hold focus afterwards, or null when the tree
    /// became empty. The sibling is the natural choice: it is where the space went,
    /// so it is what the user is now looking at.
    pub fn close(self: *Tree, target: PaneId) !?PaneId {
        const root = self.root orelse return Error.NoSuchPane;
        if (root.* == .leaf) {
            // The last pane: the tree becomes empty rather than leaving a split
            // with nothing in it.
            if (root.leaf != target) return Error.NoSuchPane;
            root.deinit(self.gpa);
            self.gpa.destroy(root);
            self.root = null;
            self.focused = null;
            return null;
        }

        const parent = findParent(root, target) orelse return Error.NoSuchPane;
        const parent_split = parent.branch;
        const target_is_first = switch (parent_split.first.*) {
            .leaf => |id| id == target,
            .branch => false,
        };
        const doomed = if (target_is_first) parent_split.first else parent_split.second;
        const survivor = if (target_is_first) parent_split.second else parent_split.first;

        // The surviving subtree is lifted into the parent's place, so the split
        // disappears rather than being left holding one child.
        const survivor_value = survivor.*;
        parent.* = survivor_value;

        doomed.deinit(self.gpa);
        self.gpa.destroy(doomed);
        self.gpa.destroy(survivor);

        const next_focus = firstPaneOf(parent);
        self.focused = next_focus;
        return next_focus;
    }

    /// Move focus to the next pane in tree order, wrapping around.
    ///
    /// Tree order is left-to-right and top-to-bottom for the layout the tree
    /// describes, so "next" follows what the eye does.
    ///
    /// The order is recomputed on each call rather than cached, because the tree
    /// changes as panes are split and closed and a cached order would have to be
    /// invalidated in every one of those paths. The walk is over a fixed buffer, so
    /// a keystroke can move focus without allocating.
    pub fn focusNext(self: *Tree) ?PaneId {
        var ids: [max_panes]PaneId = undefined;
        var found: usize = 0;
        if (self.root) |root| collectInto(root, &ids, &found);

        if (found == 0) return null;

        const current = self.focused orelse {
            self.focused = ids[0];
            return self.focused;
        };
        for (ids[0..found], 0..) |id, index| {
            if (id == current) {
                self.focused = ids[(index + 1) % found];
                return self.focused;
            }
        }
        // The focused pane is not in the tree, which should not happen; falling
        // back to the first is better than leaving focus pointing nowhere.
        self.focused = ids[0];
        return self.focused;
    }

    /// Move focus to the previous pane in tree order, wrapping around.
    pub fn focusPrevious(self: *Tree) ?PaneId {
        var ids: [max_panes]PaneId = undefined;
        var found: usize = 0;
        if (self.root) |root| collectInto(root, &ids, &found);

        if (found == 0) return null;

        const current = self.focused orelse {
            self.focused = ids[0];
            return self.focused;
        };
        for (ids[0..found], 0..) |id, index| {
            if (id == current) {
                self.focused = ids[(index + found - 1) % found];
                return self.focused;
            }
        }
        self.focused = ids[0];
        return self.focused;
    }

    /// Give a pane a new share of its parent split.
    ///
    /// The ratio is the first child's fraction, and is clamped away from the ends
    /// so that neither child can be squeezed to nothing: a zero-width pane has no
    /// cells for its pty and libghostty-vt rejects a zero-sized terminal.
    pub fn setRatio(self: *Tree, target: PaneId, ratio: f32) !void {
        if (!(ratio > 0.0 and ratio < 1.0)) return Error.BadRatio;
        const root = self.root orelse return Error.NoSuchPane;
        const parent = findParent(root, target) orelse return Error.NoSuchPane;
        parent.branch.ratio = ratio;
    }

    /// Compute every pane's rectangle for a window of `cols` by `rows`.
    ///
    /// The result is appended to `out`, in tree order. The rectangles tile the
    /// window exactly when the window is at least as large as the number of panes
    /// in each direction; a window too small produces empty rectangles rather than
    /// overlapping ones, because overlapping panes would each believe they own
    /// cells the other is also drawing.
    pub fn layout(self: *Tree, out: *std.ArrayList(Placement), cols: u16, rows: u16) !void {
        out.clearRetainingCapacity();
        const root = self.root orelse return;
        try self.layoutNode(root, .{
            .x = 0,
            .y = 0,
            .width = cols,
            .height = rows,
        }, out);
    }

    fn layoutNode(
        self: *Tree,
        node: *Node,
        rect: Rect,
        out: *std.ArrayList(Placement),
    ) !void {
        switch (node.*) {
            .leaf => |id| try out.append(self.gpa, .{ .id = id, .rect = rect }),
            .branch => |node_split| {
                const first, const second = divide(rect, node_split.axis, node_split.ratio);
                try self.layoutNode(node_split.first, first, out);
                try self.layoutNode(node_split.second, second, out);
            },
        }
    }

    /// The pane identifiers in tree order.
    pub fn collect(self: *Tree, out: *std.ArrayList(PaneId)) !void {
        out.clearRetainingCapacity();
        const root = self.root orelse return;
        try self.collectNode(root, out);
    }

    fn collectNode(self: *Tree, node: *Node, out: *std.ArrayList(PaneId)) !void {
        switch (node.*) {
            .leaf => |id| try out.append(self.gpa, id),
            .branch => |node_split| {
                try self.collectNode(node_split.first, out);
                try self.collectNode(node_split.second, out);
            },
        }
    }

    /// How many panes the tree holds.
    pub fn count(self: *Tree) usize {
        const root = self.root orelse return 0;
        return countNode(root);
    }

    fn countNode(node: *Node) usize {
        return switch (node.*) {
            .leaf => 1,
            .branch => |node_split| countNode(node_split.first) + countNode(node_split.second),
        };
    }

    fn findLeaf(self: *Tree, target: PaneId) ?*Node {
        const root = self.root orelse return null;
        return findLeafIn(root, target);
    }

    fn findLeafIn(node: *Node, target: PaneId) ?*Node {
        return switch (node.*) {
            .leaf => |id| if (id == target) node else null,
            .branch => |node_split| findLeafIn(node_split.first, target) orelse
                findLeafIn(node_split.second, target),
        };
    }

    /// Find the split node that directly contains `target` as a leaf child.
    fn findParent(node: *Node, target: PaneId) ?*Node {
        return switch (node.*) {
            .leaf => null,
            .branch => |node_split| {
                const first_is_target = switch (node_split.first.*) {
                    .leaf => |id| id == target,
                    .branch => false,
                };
                const second_is_target = switch (node_split.second.*) {
                    .leaf => |id| id == target,
                    .branch => false,
                };
                if (first_is_target or second_is_target) return node;
                return findParent(node_split.first, target) orelse
                    findParent(node_split.second, target);
            },
        };
    }

    /// The leftmost-topmost pane of a subtree, which is what gets focus after a
    /// close.
    fn firstPaneOf(node: *Node) PaneId {
        return switch (node.*) {
            .leaf => |id| id,
            .branch => |node_split| firstPaneOf(node_split.first),
        };
    }
};

/// The most panes one tree may hold.
///
/// This bounds the stack buffer `focusNext` walks into. It is not a limit on the
/// tree itself, which grows on the heap; it is the point past which focus cycling
/// would have to allocate, and a user navigating that many panes one keypress at a
/// time is not the case worth allocating for.
pub const max_panes = 256;

fn collectInto(node: *Node, out: *[max_panes]PaneId, count: *usize) void {
    switch (node.*) {
        .leaf => |id| {
            if (count.* < out.len) {
                out[count.*] = id;
                count.* += 1;
            }
        },
        .branch => |node_split| {
            collectInto(node_split.first, out, count);
            collectInto(node_split.second, out, count);
        },
    }
}

/// Split a rectangle along an axis and return the two halves.
///
/// The rounding is the interesting part. A window of 81 columns split evenly
/// cannot give both children 40.5, and giving them 40 and 40 loses a column that
/// then belongs to no pane. Instead the first child takes the floor and the second
/// takes the remainder, so the two always add back to the original and no cell is
/// lost or double-counted. A child that would become zero-width is clamped to one
/// cell where the rectangle is wide enough to spare it.
pub fn divide(rect: Rect, axis: Axis, ratio: f32) struct { Rect, Rect } {
    const clamped = std.math.clamp(ratio, 0.05, 0.95);
    switch (axis) {
        .horizontal => {
            if (rect.width < 2) return .{ rect, .{ .x = rect.x, .y = rect.y } };
            const first_width: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.width)) * clamped);
            const safe_first = std.math.clamp(first_width, 1, rect.width - 1);
            const second_width = rect.width - safe_first;
            return .{
                .{ .x = rect.x, .y = rect.y, .width = safe_first, .height = rect.height },
                .{
                    .x = rect.x + safe_first,
                    .y = rect.y,
                    .width = second_width,
                    .height = rect.height,
                },
            };
        },
        .vertical => {
            if (rect.height < 2) return .{ rect, .{ .x = rect.x, .y = rect.y } };
            const first_height: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.height)) * clamped);
            const safe_first = std.math.clamp(first_height, 1, rect.height - 1);
            const second_height = rect.height - safe_first;
            return .{
                .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = safe_first },
                .{
                    .x = rect.x,
                    .y = rect.y + safe_first,
                    .width = rect.width,
                    .height = second_height,
                },
            };
        },
    }
}

test "a single pane fills the window" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const id = tree.allocateId();
    try tree.setRoot(id);
    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expectEqual(@as(?PaneId, id), tree.focused);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    try std.testing.expectEqual(@as(usize, 1), placements.items.len);
    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 80,
        .height = 24,
    }));
}

test "a horizontal split divides the width and keeps the height" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const first = tree.allocateId();
    try tree.setRoot(first);
    const second = tree.allocateId();
    try tree.split(first, .horizontal, second);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    try std.testing.expectEqual(@as(usize, 2), placements.items.len);
    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 40,
        .height = 24,
    }));
    try std.testing.expect(placements.items[1].rect.eql(.{
        .x = 40,
        .y = 0,
        .width = 40,
        .height = 24,
    }));
}

test "a vertical split divides the height and keeps the width" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const first = tree.allocateId();
    try tree.setRoot(first);
    const second = tree.allocateId();
    try tree.split(first, .vertical, second);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 80,
        .height = 12,
    }));
    try std.testing.expect(placements.items[1].rect.eql(.{
        .x = 0,
        .y = 12,
        .width = 80,
        .height = 12,
    }));
}

test "an odd width loses no column" {
    // 81 split evenly cannot be 40.5 each. The halves must still add up to 81, or
    // a column belongs to no pane and is never drawn.
    const even = divide(.{ .width = 81, .height = 10 }, .horizontal, 0.5);
    try std.testing.expectEqual(@as(u16, 81), even[0].width + even[1].width);
    // A horizontal split leaves the height alone.
    try std.testing.expectEqual(@as(u16, 10), even[0].height);
    try std.testing.expectEqual(@as(u16, 10), even[1].height);
}

test "an odd height loses no row" {
    const split = divide(.{ .width = 10, .height = 25 }, .vertical, 0.5);
    try std.testing.expectEqual(@as(u16, 25), split[0].height + split[1].height);
}

test "a nested split stays inside its parent's rectangle" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    // Split the right half vertically.
    const c = tree.allocateId();
    try tree.split(b, .vertical, c);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    try std.testing.expectEqual(@as(usize, 3), placements.items.len);

    // `a` keeps the left half.
    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 40,
        .height = 24,
    }));
    // `b` and `c` share the right half, and neither leaves it.
    for (placements.items[1..]) |placement| {
        try std.testing.expectEqual(@as(u16, 40), placement.rect.x);
        try std.testing.expectEqual(@as(u16, 40), placement.rect.width);
        try std.testing.expect(placement.rect.y + placement.rect.height <= 24);
    }
    // `c` is the new pane and takes focus.
    try std.testing.expectEqual(@as(?PaneId, c), tree.focused);
}

test "every cell of the window is covered exactly once" {
    // Tiling matters: a gap is an unpainted cell and an overlap is two panes
    // writing the same cell. This walks a three-pane layout and counts coverage.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    const c = tree.allocateId();
    try tree.split(b, .vertical, c);

    const cols: u16 = 80;
    const rows: u16 = 24;

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, cols, rows);

    var covered = try gpa.alloc(u8, cols * rows);
    defer gpa.free(covered);
    @memset(covered, 0);

    for (placements.items) |placement| {
        const rect = placement.rect;
        var y = rect.y;
        while (y < rect.y + rect.height) : (y += 1) {
            var x = rect.x;
            while (x < rect.x + rect.width) : (x += 1) {
                const index = @as(usize, y) * cols + x;
                covered[index] += 1;
            }
        }
    }

    for (covered) |count| {
        if (count != 1) return error.CellNotCoveredExactlyOnce;
    }
}

test "closing a pane gives its space to its sibling" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    // Close `b`; `a` should get the whole window back.
    const next = try tree.close(b);
    try std.testing.expectEqual(@as(?PaneId, a), next);
    try std.testing.expectEqual(@as(usize, 1), tree.count());

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);
    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 80,
        .height = 24,
    }));
}

test "closing the only pane empties the tree" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);

    try std.testing.expectEqual(@as(?PaneId, null), try tree.close(a));
    try std.testing.expect(tree.isEmpty());
    try std.testing.expectEqual(@as(?PaneId, null), tree.focused);
}

test "closing the first of a nested pair promotes the sibling subtree" {
    // Closing a pane whose sibling is a split must lift the whole subtree into the
    // parent's place, not leave a split holding one child.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    const c = tree.allocateId();
    try tree.split(b, .vertical, c);

    // Close `a`, whose sibling is the split of b and c.
    _ = try tree.close(a);
    try std.testing.expectEqual(@as(usize, 2), tree.count());

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    // b and c now share the whole window.
    try std.testing.expectEqual(@as(usize, 2), placements.items.len);
    try std.testing.expectEqual(@as(u16, 80), placements.items[0].rect.width);
    try std.testing.expectEqual(@as(u16, 80), placements.items[1].rect.width);
}

test "closing an unknown pane is an error" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    try std.testing.expectError(Error.NoSuchPane, tree.close(9999));
    try std.testing.expectError(Error.NoSuchPane, tree.split(9999, .horizontal, tree.allocateId()));
}

test "focus moves in tree order and wraps" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    // The split focused `b`.
    try std.testing.expectEqual(@as(?PaneId, b), tree.focused);
    try std.testing.expectEqual(@as(?PaneId, a), tree.focusNext());
    try std.testing.expectEqual(@as(?PaneId, b), tree.focusNext());
}

test "a ratio is clamped so neither pane can be squeezed away" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    try tree.setRatio(b, 0.9);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);

    // Both halves still have room for a program.
    for (placements.items) |placement| {
        try std.testing.expect(placement.rect.width > 0);
        try std.testing.expect(placement.rect.height > 0);
    }
    try std.testing.expectEqual(@as(u16, 80), placements.items[0].rect.width +
        placements.items[1].rect.width);
}

test "a ratio outside the unit interval is rejected" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    try std.testing.expectError(Error.BadRatio, tree.setRatio(a, 0.0));
    try std.testing.expectError(Error.BadRatio, tree.setRatio(a, 1.0));
    try std.testing.expectError(Error.BadRatio, tree.setRatio(a, -0.5));
}

test "a window too small for the panes produces empty rectangles, not overlaps" {
    // Two panes side by side in a one-column window cannot both have a column.
    // Overlapping them would mean both draw the same cell.
    const split = divide(.{ .width = 1, .height = 1 }, .horizontal, 0.5);
    try std.testing.expect(split[0].width + split[1].width <= 1);
}

test "dividing a two-cell rectangle leaves one cell each" {
    const split = divide(.{ .width = 2, .height = 1 }, .horizontal, 0.5);
    try std.testing.expectEqual(@as(u16, 1), split[0].width);
    try std.testing.expectEqual(@as(u16, 1), split[1].width);
}
