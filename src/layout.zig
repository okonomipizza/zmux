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
const protocol = @import("protocol.zig");

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

    /// The part of a pane its program is given, once the frame is taken off.
    ///
    /// Delegates to the same function the client uses, so that the rectangle the pty is sized to is
    /// provably the rectangle the program's cells are drawn in. Two copies of this arithmetic would
    /// drift, and the symptom would be text wrapping one column away from where the border is.
    pub fn interior(self: Rect) Rect {
        // Named rather than called on the literal, because Zig reads `Struct{...}.method()`
        // as a block followed by a statement.
        const wire: protocol.Rect = .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        };
        const result = wire.interior();
        return .{
            .x = result.x,
            .y = result.y,
            .width = result.width,
            .height = result.height,
        };
    }
};

/// Which way a split divides its rectangle.
pub const Axis = enum {
    /// Children are side by side; the split line is vertical.
    horizontal,
    /// Children are stacked; the split line is horizontal.
    vertical,
};

/// Which way the user is looking when they ask to move.
///
/// Separate from `Axis` because the two answer different questions and their names would
/// otherwise lie. A `horizontal` split puts its children side by side, but the key that moves to
/// one of them points left or right; `Axis.horizontal` is the split's own axis, and `.left` is
/// where the eye goes. Sharing one enum would make `left` mean `horizontal` at the call site and
/// read as a bug.
pub const Direction = enum {
    left,
    right,
    up,
    down,

    /// Which way the move runs along its axis, for callers comparing coordinates.
    ///
    /// Right and down run with increasing coordinates, left and up against them. The axis itself is
    /// not exposed: what a caller needs is which way along it to look, and the two comparisons that
    /// use this are written per direction anyway, because the band each one shares is different.
    pub fn forward(self: Direction) bool {
        return switch (self) {
            .right, .down => true,
            .left, .up => false,
        };
    }
};

pub const Error = error{
    /// No pane has that identifier.
    NoSuchPane,
    /// The tree has no room for another node.
    OutOfMemory,
    /// A ratio outside the range the tree can represent.
    BadRatio,
    /// The tree already holds `max_panes` panes.
    TooManyPanes,
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
    /// How many leaves the tree holds.
    ///
    /// Maintained on every add and remove rather than recomputed, because `count` is a
    /// whole-tree walk and the two places that need this need it per operation: `split`
    /// has to refuse a full tree, and `sendLayout` numbers the panes it emits. Asking the
    /// tree to walk itself each time would make splitting quadratic in the pane count.
    leaves: usize = 0,

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
        self.leaves = 0;
    }

    pub fn isEmpty(self: Tree) bool {
        return self.root == null;
    }

    /// Whether a pane is still in the tree.
    ///
    /// Needed by callers that remember a pane's identifier across a change and must check it is still
    /// there before pointing anything at it. The tree is the authority on which panes are tiled; a
    /// pane that has been floated or closed is not.
    pub fn contains(self: *Tree, id: PaneId) bool {
        const root = self.root orelse return false;
        return findLeafIn(root, id) != null;
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
        self.leaves = 1;
    }

    /// Split the pane `target` in two.
    ///
    /// The existing pane keeps the first half and `new_id` takes the second, so
    /// the pane the user was looking at stays where it was and the new one appears
    /// after it. Focus moves to the new pane, which is what makes a split useful
    /// immediately: the next thing typed goes into the new program.
    ///
    /// A tree at `max_panes` refuses rather than growing. That is not a limit on memory, which the
    /// heap could supply: it is the point past which the rest of zmux stops being able to describe
    /// the session. `sendLayout` numbers the tiled panes into a `u8`, and the focus keys read the
    /// arrangement into a `[max_panes]Placement` buffer instead of allocating on a keystroke, so the
    /// 256th pane is where a session's own bookkeeping runs out. Without this guard, reaching it
    /// panicked the server and took every session with it.
    pub fn split(self: *Tree, target: PaneId, axis: Axis, new_id: PaneId) !void {
        if (self.leaves >= max_panes) return Error.TooManyPanes;
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

        self.leaves += 1;
        self.focused = new_id;
    }

    /// Remove a pane from the tree and let its neighbour absorb the space.
    ///
    /// This is what parking a pane does: the pane leaves the layout without being closed,
    /// and the space it occupied is handed to a neighbour so that the remaining panes grow
    /// to fill the window rather than leaving a hole.
    ///
    /// The neighbour is chosen by direction, not by tree adjacency. A pane whose sibling
    /// happens to be a subtree would otherwise hand its space to whatever leaf that subtree
    /// puts first, which can be on the other side of the window. Instead the tree is walked
    /// for a leaf that is vertically adjacent — sharing a horizontal edge — and only if
    /// there is none is one that is horizontally adjacent used. Growing a pane upward or
    /// downward is the better default because terminal content is laid out in rows, so a
    /// pane that gains rows shows more of what it already has, while one that gains columns
    /// only gets wider margins.
    ///
    /// Returns the pane whose space the departing pane's was folded into, or null when the
    /// tree became empty.
    pub fn detach(self: *Tree, target: PaneId, cols: u16, rows: u16) !?PaneId {
        const root = self.root orelse return Error.NoSuchPane;
        if (findLeafIn(root, target) == null) return Error.NoSuchPane;

        // The geometry is needed to decide who is adjacent, and it has to be read before the
        // pane is removed or the tree no longer describes the arrangement the user saw.
        var before: std.ArrayList(Placement) = .empty;
        defer before.deinit(self.gpa);
        try self.layout(&before, cols, rows);

        const absorber = pickAbsorber(before.items, target);

        if (root.* == .leaf) {
            // The last pane: the tree becomes empty rather than leaving a branch with one
            // child.
            root.deinit(self.gpa);
            self.gpa.destroy(root);
            self.root = null;
            self.focused = null;
            self.leaves = 0;
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

        // The surviving subtree is lifted into the parent's place, so the branch disappears
        // rather than being left holding one child.
        const survivor_value = survivor.*;
        parent.* = survivor_value;

        doomed.deinit(self.gpa);
        self.gpa.destroy(doomed);
        self.gpa.destroy(survivor);
        self.leaves -= 1;

        if (self.focused) |focused| {
            if (focused == target) self.focused = firstPaneOf(parent);
        }

        return absorber orelse firstPaneOf(parent);
    }

    /// A rectangle's area in cells, for comparing which neighbour has the most to gain.
    fn area(rect: Rect) u32 {
        return @as(u32, rect.width) * @as(u32, rect.height);
    }

    /// Choose which pane should grow into the space a departing pane leaves.
    ///
    /// A pane is a candidate if it shares an edge with the departing one: the same horizontal
    /// band for a vertical neighbour, the same vertical band for a horizontal one. The largest
    /// candidate wins, so the space goes to the pane with the most to gain from it.
    fn pickAbsorber(placements: []const Placement, target: PaneId) ?PaneId {
        var departing: Rect = .{};
        var found = false;
        for (placements) |placement| {
            if (placement.id == target) {
                departing = placement.rect;
                found = true;
            }
        }
        if (!found) return null;

        var vertical_best: ?Placement = null;
        var horizontal_best: ?Placement = null;

        for (placements) |placement| {
            if (placement.id == target) continue;
            const rect = placement.rect;

            // A vertical neighbour: the two are stacked, so their columns overlap and one sits
            // directly above the other.
            const columns_overlap = rect.x < departing.x + departing.width and
                departing.x < rect.x + rect.width;
            const rows_touch = rect.y + rect.height == departing.y or
                departing.y + departing.height == rect.y;
            if (columns_overlap and rows_touch) {
                if (vertical_best == null or area(rect) > area(vertical_best.?.rect)) {
                    vertical_best = placement;
                }
                continue;
            }

            // A horizontal neighbour: side by side, so their rows overlap and one sits directly
            // beside the other.
            const rows_overlap = rect.y < departing.y + departing.height and
                departing.y < rect.y + rect.height;
            const columns_touch = rect.x + rect.width == departing.x or
                departing.x + departing.width == rect.x;
            if (rows_overlap and columns_touch) {
                if (horizontal_best == null or area(rect) > area(horizontal_best.?.rect)) {
                    horizontal_best = placement;
                }
            }
        }

        // Vertical neighbours are preferred, so a pane grows by gaining rows rather than columns.
        if (vertical_best) |best| return best.id;
        if (horizontal_best) |best| return best.id;
        return null;
    }

    /// Split `target` along whichever of its sides is longer.
    ///
    /// A pane that is wider than it is tall is divided into columns, and a taller-than-wide
    /// pane into rows. The point is that the two halves come out roughly square rather than
    /// producing a pair of thin slivers, which is what a fixed choice of axis does to the
    /// other orientation.
    ///
    /// The current geometry is needed to know which side is longer, so it is provided by the
    /// caller rather than guessed from the tree's ratios.
    pub fn splitLongest(
        self: *Tree,
        target: PaneId,
        new_id: PaneId,
        cols: u16,
        rows: u16,
    ) !Axis {
        var placements: std.ArrayList(Placement) = .empty;
        defer placements.deinit(self.gpa);
        try self.layout(&placements, cols, rows);

        var target_rect: Rect = .{};
        for (placements.items) |placement| {
            if (placement.id == target) target_rect = placement.rect;
        }

        // A tie goes to the vertical split, so that a square pane produces columns. Rows are
        // the scarcer resource in a terminal, and dividing into columns keeps both halves at
        // a usable height.
        const axis: Axis = if (target_rect.width >= target_rect.height)
            .horizontal
        else
            .vertical;

        try self.split(target, axis, new_id);
        return axis;
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
            self.leaves = 0;
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
        self.leaves -= 1;

        const next_focus = firstPaneOf(parent);
        self.focused = next_focus;
        return next_focus;
    }

    /// Move focus to the pane `direction` of the one that has it.
    ///
    /// The move is geometric, because that is what makes the keys mean what they look like: a
    /// layout with three panes side by side has nothing above or below them, so `j` and `k` have
    /// nowhere to go, while `h` and `l` walk the row. A tree-order walk cannot express that — it
    /// answers "which pane comes next", and the answer for `j` and `l` is the same pane, so half
    /// the keys look broken.
    ///
    /// The nearest pane in the direction wins, and a pane that only partly overlaps the current
    /// one's band still counts: it is on screen in that direction, so refusing to move there would
    /// read as a dead key. The distance is measured between the two panes' facing edges, so a
    /// neighbour that begins right at the current pane's edge is one step away however long either
    /// pane is, and a pane further along the same direction loses to the one beside it.
    ///
    /// The geometry is recomputed on each call rather than cached, because the tree changes as
    /// panes are split, closed and resized, and a cached arrangement would have to be invalidated
    /// in every one of those paths.
    ///
    /// Returns null and leaves focus alone when there is nothing in that direction, which is not an
    /// error: the user pressed a key that points at the edge of the layout. Nothing wraps, because
    /// wrapping would contradict the direction the key names — pressing `l` in the rightmost pane
    /// would send the eye back to the left.
    ///
    /// `cols` and `rows` must be the area the panes were last laid out in, or the neighbours are
    /// computed from rectangles that do not match the screen. The session stores both, and
    /// `relayout` is what keeps them in step with the tree.
    pub fn focusDirection(
        self: *Tree,
        direction: Direction,
        cols: u16,
        rows: u16,
    ) !?PaneId {
        var placements: std.ArrayList(Placement) = .empty;
        defer placements.deinit(self.gpa);
        try self.layout(&placements, cols, rows);

        const current = self.focused orelse return null;

        var from: Rect = .{};
        var found = false;
        for (placements.items) |placement| {
            if (placement.id == current) {
                from = placement.rect;
                found = true;
                break;
            }
        }
        // The focused pane is not in the tree. That should not happen; leaving focus where it is
        // beats moving it to a pane the user did not ask for.
        if (!found) return null;

        const neighbour = adjacentTo(placements.items, current, from, direction) orelse return null;
        self.focused = neighbour;
        return neighbour;
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

    /// Swap one pane with the pane next to it in tree order.
    ///
    /// Only the identifiers in the two leaves change; the tree's shape is untouched. That is what
    /// keeps a swap from disturbing the layout: the split ratios and the nesting describe the shape
    /// the user built, and moving a pane between two positions should not redraw it. The programs
    /// keep running too, since a pane's identity is its identifier and the pty follows it.
    ///
    /// Returns false when there is nothing to swap with, which is a tree holding fewer than two
    /// panes, or a pane that is not in the tree.
    pub fn swapWithNext(self: *Tree, id: PaneId) bool {
        return self.swapNeighbours(id, 1);
    }

    /// Swap one pane with the pane before it in tree order.
    pub fn swapWithPrevious(self: *Tree, id: PaneId) bool {
        return self.swapNeighbours(id, -1);
    }

    fn swapNeighbours(self: *Tree, id: PaneId, direction: i8) bool {
        // The order is what the focus keys already use, so "next" here is the pane the user reaches
        // by pressing the key that moves forward, which is what makes the two agree.
        var order: std.ArrayList(PaneId) = .empty;
        defer order.deinit(self.gpa);
        self.collect(&order) catch return false;
        if (order.items.len < 2) return false;

        var index: usize = 0;
        while (index < order.items.len) : (index += 1) {
            if (order.items[index] == id) break;
        } else return false;

        // A swap at either end wraps, so the keys keep working however the focus got there. Wrapping
        // is what the focus keys do too, and a pane that refused to move would read as a broken key.
        const total = order.items.len;
        const neighbour = if (direction > 0)
            (index + 1) % total
        else
            (index + total - 1) % total;

        const a = self.findLeaf(id) orelse return false;
        const b = self.findLeaf(order.items[neighbour]) orelse return false;

        // Both are leaves by construction, so the two values are the pane identifiers.
        const held = a.leaf;
        a.leaf = b.leaf;
        b.leaf = held;
        return true;
    }

    /// Move every pane one position along in tree order, last to first.
    ///
    /// Rotating rather than swapping because three panes or more cannot be rearranged by pairwise
    /// swaps without a plan; one key that shifts them all is what makes the arrangement feel like a
    /// ring. The direction matches tmux's rotate key, so the pane that was last becomes first.
    ///
    /// Returns false when there is nothing to rotate.
    pub fn rotate(self: *Tree) bool {
        var order: std.ArrayList(PaneId) = .empty;
        defer order.deinit(self.gpa);
        self.collect(&order) catch return false;
        if (order.items.len < 2) return false;

        // Every leaf is located before any is written. Finding a leaf by its identifier and then
        // overwriting that identifier would make the next lookup search for one that is no longer
        // there, so the lookups and the writes have to be separate passes.
        var leaves: std.ArrayList(*Node) = .empty;
        defer leaves.deinit(self.gpa);
        for (order.items) |id| {
            const leaf = self.findLeaf(id) orelse return false;
            leaves.append(self.gpa, leaf) catch return false;
        }

        // Each pane takes the identifier of the one before it, and the first takes the last, so the
        // arrangement shifts one place along a ring. The identifiers are written into the leaves
        // rather than the leaves being rearranged, which preserves the shape.
        for (leaves.items, 0..) |leaf, index| {
            const source = if (index == 0) order.items.len - 1 else index - 1;
            leaf.leaf = order.items[source];
        }
        return true;
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
        return self.leaves;
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
/// This is the point past which the rest of zmux stops being able to describe the session. A
/// client's layout event numbers its panes into a `u8`, and `protocol.Decoder.max_panes` bounds the
/// placements it can carry. It is not a limit on memory, which the heap could supply.
pub const max_panes = protocol.Decoder.max_panes;

/// Choose which pane focus moves to when the user points in a direction.
///
/// A candidate is any pane lying that way whose band overlaps the current one's, and the nearest of
/// those wins. "Lies that way" is decided by the two edges rather than by the centres: a tall pane
/// beside a stack of two short ones is next to both of them, and comparing centres would pick
/// whichever centre happened to be nearer rather than the pane actually alongside.
///
/// Distance is measured between the facing edges, so a candidate that starts immediately at the
/// current pane's edge is one cell away however long the two of them are. Measuring centre to centre
/// would instead make a long pane look far away and a short one look near, which is not what the eye
/// sees.
///
/// Overlap is required rather than exact alignment, because panes divided unevenly do not line up:
/// three columns of different widths each overlap the others only partly, and demanding an exact
/// match would leave most of them unreachable.
fn adjacentTo(
    placements: []const Placement,
    current: PaneId,
    from: Rect,
    direction: Direction,
) ?PaneId {
    var best: ?PaneId = null;
    var best_distance: u32 = std.math.maxInt(u32);

    for (placements) |placement| {
        if (placement.id == current) continue;
        const rect = placement.rect;

        // The band the two panes have to share, and the gap between their facing edges. A move
        // left or right shares rows and is measured in columns; a move up or down shares columns
        // and is measured in rows. The band is an overlap test, not an equality one: panes divided
        // unevenly do not line up, and demanding a match would make most of them unreachable.
        const distance: ?u32 = switch (direction) {
            .left, .right => blk: {
                const shares_rows = rect.y < from.y + from.height and from.y < rect.y + rect.height;
                if (!shares_rows) break :blk null;
                break :blk gap(from.x, from.width, rect.x, rect.width, direction.forward());
            },
            .up, .down => blk: {
                const shares_cols = rect.x < from.x + from.width and from.x < rect.x + rect.width;
                if (!shares_cols) break :blk null;
                break :blk gap(from.y, from.height, rect.y, rect.height, direction.forward());
            },
        };

        // A pane that lies behind the direction rather than ahead of it has no gap to measure.
        const d = distance orelse continue;

        // Ties are broken by the walk order, which is tree order. Two panes equidistant in the same
        // direction is a symmetric layout, and either answer is as good as the other.
        if (d < best_distance) {
            best_distance = d;
            best = placement.id;
        }
    }

    return best;
}

/// How far `other` lies beyond `current` along one axis, or null when it does not.
///
/// `forward` says which way the move goes: right and down run with increasing coordinates, left and
/// up against them. Only panes strictly ahead count, so a move never lands on a pane the user was
/// not pointing at, and the distance is measured between the facing edges -- so a candidate that
/// starts immediately at the current pane's edge is one step away however long either pane is.
fn gap(current_start: u16, current_size: u16, other_start: u16, other_size: u16, forward: bool) ?u32 {
    if (forward) {
        const current_end = @as(u32, current_start) + current_size;
        if (other_start < current_end) return null;
        return @as(u32, other_start) - current_end;
    }
    const other_end = @as(u32, other_start) + other_size;
    if (other_end > current_start) return null;
    return @as(u32, current_start) - other_end;
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

test "a full tree refuses another pane rather than overflowing a label" {
    // The defect this guards against is a server-wide crash. `sendLayout` numbers the tiled panes
    // into a `u8`, so the 256th pane incremented it past 255; under `-Doptimize=ReleaseSafe`,
    // which is how the flake builds zmux, that is a panic, and a panicking server takes every
    // session with it. The tree is the only place that can refuse, since it is what knows how many
    // panes there are.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const first = tree.allocateId();
    try tree.setRoot(first);
    try std.testing.expectEqual(@as(usize, 1), tree.count());

    // Fill to the limit. Each split adds exactly one leaf, so the count is the check that the
    // tracked field and the tree agree while it is being built.
    var filled: usize = 1;
    while (filled < max_panes) : (filled += 1) {
        try tree.split(first, .horizontal, tree.allocateId());
    }
    try std.testing.expectEqual(@as(usize, max_panes), tree.count());

    // The next one is refused, and refusing changes nothing: a tree left one pane short would be a
    // worse outcome than the refusal.
    try std.testing.expectError(
        Error.TooManyPanes,
        tree.split(first, .horizontal, tree.allocateId()),
    );
    try std.testing.expectEqual(@as(usize, max_panes), tree.count());

    // Closing a pane makes room again, so the limit is a ceiling and not a one-way door.
    _ = try tree.close(first);
    try std.testing.expectEqual(@as(usize, max_panes - 1), tree.count());
    try tree.split(tree.focused.?, .horizontal, tree.allocateId());
    try std.testing.expectEqual(@as(usize, max_panes), tree.count());

    // And detaching frees a slot too, which is the other way a pane leaves the tree.
    _ = try tree.detach(tree.focused.?, 80, 24);
    try std.testing.expectEqual(@as(usize, max_panes - 1), tree.count());
}

test "focus moves toward the pane the direction points at" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    // The split focused `b`, which is the right half.
    try std.testing.expectEqual(@as(?PaneId, b), tree.focused);

    // `h` reaches the left half, and there is nothing further left to reach.
    try std.testing.expectEqual(@as(?PaneId, a), try tree.focusDirection(.left, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.left, 80, 24));

    // `l` comes back, and the right edge is the end of the row.
    try std.testing.expectEqual(@as(?PaneId, b), try tree.focusDirection(.right, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.right, 80, 24));
}

test "a direction with no pane in it leaves focus alone" {
    // Two panes side by side have nothing above or below them, so the vertical keys do nothing.
    // This is the case that made the old tree-order walk look arbitrary: it moved for every key.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const left = tree.allocateId();
    try tree.setRoot(left);
    const right = tree.allocateId();
    try tree.split(left, .horizontal, right);

    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.up, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, right), tree.focused);
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.down, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, right), tree.focused);
}

test "focus in a 2x2 grid reaches the pane on each side" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const top_left = tree.allocateId();
    try tree.setRoot(top_left);
    const top_right = tree.allocateId();
    try tree.split(top_left, .horizontal, top_right);
    const bottom_left = tree.allocateId();
    try tree.split(top_left, .vertical, bottom_left);
    const bottom_right = tree.allocateId();
    try tree.split(top_right, .vertical, bottom_right);

    // Start in the top-left corner.
    tree.focused = top_left;

    try std.testing.expectEqual(@as(?PaneId, top_right), try tree.focusDirection(.right, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, bottom_right), try tree.focusDirection(.down, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, bottom_left), try tree.focusDirection(.left, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, top_left), try tree.focusDirection(.up, 80, 24));
}

test "focus leaves the row for the pane that spans it" {
    // One wide pane on the left, two stacked on the right. From the left pane, `l` has two
    // candidates and has to pick the one alongside; the tall pane beside a stack is next to both
    // of the stacked ones, and a centre-to-centre rule would pick whichever centre is nearer.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const left = tree.allocateId();
    try tree.setRoot(left);
    const right_top = tree.allocateId();
    try tree.split(left, .horizontal, right_top);
    const right_bottom = tree.allocateId();
    try tree.split(right_top, .vertical, right_bottom);

    tree.focused = left;

    // Both stacked panes start at the same column, so either is correct; what matters is that a
    // move right stays in the right-hand column and does not pick a pane by its centre.
    const reached = (try tree.focusDirection(.right, 80, 24)).?;
    try std.testing.expect(reached == right_top or reached == right_bottom);

    // From a stacked pane, moving left crosses the whole width to the wide pane.
    tree.focused = right_bottom;
    try std.testing.expectEqual(@as(?PaneId, left), try tree.focusDirection(.left, 80, 24));

    // And from the lower stacked pane, moving up reaches its sibling in the same column. The
    // previous move left focus on the wide pane, so it is set again rather than assumed.
    tree.focused = right_bottom;
    try std.testing.expectEqual(@as(?PaneId, right_top), try tree.focusDirection(.up, 80, 24));
}

test "focus follows uneven splits rather than exact alignment" {
    // Three panes: the left one is wide, and the right one is split into two rows. The wide pane's
    // rows overlap both of the small ones only partly, and never exactly, so a rule demanding a
    // matching band would leave it unreachable from either.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const left = tree.allocateId();
    try tree.setRoot(left);
    const right_top = tree.allocateId();
    try tree.split(left, .horizontal, right_top);
    const right_bottom = tree.allocateId();
    try tree.split(right_top, .vertical, right_bottom);

    // An odd number of rows cannot be halved exactly, so the two right-hand panes do not share
    // their parent's band with the left one on equal terms.
    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 79, 25);
    const left_rect = placements.items[0].rect;
    const top_rect = placements.items[1].rect;

    // The premise: neither right-hand pane shares the left pane's full band.
    try std.testing.expect(top_rect.height != left_rect.height);
    try std.testing.expect(top_rect.height < left_rect.height);

    tree.focused = left;
    try std.testing.expectEqual(@as(?PaneId, right_top), try tree.focusDirection(.right, 79, 25));

    tree.focused = right_bottom;
    try std.testing.expectEqual(@as(?PaneId, left), try tree.focusDirection(.left, 79, 25));
}

test "focus picks the nearest pane when several lie the same way" {
    // Three columns: from the leftmost, moving right must land on the middle one and not the far
    // one, which is the difference between measuring to the facing edge and measuring to the centre.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    const c = tree.allocateId();
    try tree.split(b, .horizontal, c);

    tree.focused = a;
    try std.testing.expectEqual(@as(?PaneId, b), try tree.focusDirection(.right, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, c), try tree.focusDirection(.right, 80, 24));
}

test "focus does not wrap around the layout" {
    // Wrapping would contradict the key: `l` in the rightmost pane would send the eye left.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .vertical, b);

    tree.focused = a;
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.up, 80, 24));

    tree.focused = b;
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.down, 80, 24));
}

test "focus on an empty tree has nothing to move to" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.left, 80, 24));

    const only = tree.allocateId();
    try tree.setRoot(only);
    try std.testing.expectEqual(@as(?PaneId, null), try tree.focusDirection(.right, 80, 24));
    try std.testing.expectEqual(@as(?PaneId, only), tree.focused);
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

test "detaching a pane hands its space to the pane above it" {
    // Two panes stacked. Parking the lower one must give its rows to the upper one, so the
    // layout fills the window rather than leaving a hole where the pane used to be.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const top = tree.allocateId();
    try tree.setRoot(top);
    const bottom = tree.allocateId();
    try tree.split(top, .vertical, bottom);

    const absorber = try tree.detach(bottom, 80, 24);
    try std.testing.expectEqual(@as(?PaneId, top), absorber);
    try std.testing.expectEqual(@as(usize, 1), tree.count());

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);
    // The survivor now has the whole window.
    try std.testing.expect(placements.items[0].rect.eql(.{
        .x = 0,
        .y = 0,
        .width = 80,
        .height = 24,
    }));
}

test "detaching prefers a vertical neighbour over a horizontal one" {
    // Four panes in a 2x2 grid. Parking the top-left must give its space to the pane below it
    // rather than the one beside it, so the pane grows by gaining rows.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const top_left = tree.allocateId();
    try tree.setRoot(top_left);
    const top_right = tree.allocateId();
    try tree.split(top_left, .horizontal, top_right);
    const bottom_left = tree.allocateId();
    try tree.split(top_left, .vertical, bottom_left);
    const bottom_right = tree.allocateId();
    try tree.split(top_right, .vertical, bottom_right);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);
    try std.testing.expectEqual(@as(usize, 4), placements.items.len);

    const absorber = try tree.detach(top_left, 80, 24);
    try std.testing.expectEqual(@as(?PaneId, bottom_left), absorber);
}

test "detaching falls back to a horizontal neighbour when there is no vertical one" {
    // Two panes side by side. There is no pane above or below either of them, so the
    // remaining one takes the space sideways.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const left = tree.allocateId();
    try tree.setRoot(left);
    const right = tree.allocateId();
    try tree.split(left, .horizontal, right);

    const absorber = try tree.detach(right, 80, 24);
    try std.testing.expectEqual(@as(?PaneId, left), absorber);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);
    try std.testing.expectEqual(@as(u16, 80), placements.items[0].rect.width);
}

test "detaching the last pane empties the tree" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);

    try std.testing.expectEqual(@as(?PaneId, null), try tree.detach(only, 80, 24));
    try std.testing.expect(tree.isEmpty());
}

test "detaching an unknown pane is an error and changes nothing" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);

    try std.testing.expectError(Error.NoSuchPane, tree.detach(9999, 80, 24));
    try std.testing.expectEqual(@as(usize, 2), tree.count());
}

test "detaching preserves the geometry of the panes that stay" {
    // Three panes: one wide on the left, two stacked on the right. Parking the top-right must
    // leave the left pane exactly where it was and give the freed rows to the pane below it.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const left = tree.allocateId();
    try tree.setRoot(left);
    const right_top = tree.allocateId();
    try tree.split(left, .horizontal, right_top);
    const right_bottom = tree.allocateId();
    try tree.split(right_top, .vertical, right_bottom);

    var before: std.ArrayList(Placement) = .empty;
    defer before.deinit(gpa);
    try tree.layout(&before, 80, 24);
    const left_before = before.items[0].rect;

    _ = try tree.detach(right_top, 80, 24);

    var after: std.ArrayList(Placement) = .empty;
    defer after.deinit(gpa);
    try tree.layout(&after, 80, 24);

    try std.testing.expectEqual(@as(usize, 2), after.items.len);
    try std.testing.expect(after.items[0].rect.eql(left_before));
    // The bottom-right pane now spans the full height of its column.
    try std.testing.expectEqual(@as(u16, 24), after.items[1].rect.height);
}

test "splitting a wide pane divides it into columns" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);
    const other = tree.allocateId();

    // 80x24 is wider than it is tall.
    const axis = try tree.splitLongest(only, other, 80, 24);
    try std.testing.expectEqual(Axis.horizontal, axis);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 80, 24);
    // Side by side, so they differ in x and share a height.
    try std.testing.expectEqual(@as(u16, 24), placements.items[0].rect.height);
    try std.testing.expectEqual(@as(u16, 40), placements.items[1].rect.x);
}

test "splitting a tall pane divides it into rows" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);
    const other = tree.allocateId();

    // 20x60 is taller than it is wide.
    const axis = try tree.splitLongest(only, other, 20, 60);
    try std.testing.expectEqual(Axis.vertical, axis);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 20, 60);
    // Stacked, so they differ in y and share a width.
    try std.testing.expectEqual(@as(u16, 20), placements.items[0].rect.width);
    try std.testing.expectEqual(@as(u16, 30), placements.items[1].rect.y);
}

test "splitting a square pane divides it into columns" {
    // A tie goes to columns, because rows are the scarcer resource in a terminal.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);
    const other = tree.allocateId();

    const axis = try tree.splitLongest(only, other, 24, 24);
    try std.testing.expectEqual(Axis.horizontal, axis);
}

test "splitting the longest side of a pane that is not the whole window" {
    // The choice must follow the pane's own rectangle, not the window's shape. Here the window
    // is wide but the pane to split is a tall slice of it, so it divides into rows.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const wide = tree.allocateId();
    try tree.setRoot(wide);
    const tall = tree.allocateId();
    // Split the window into a narrow right-hand column...
    try tree.split(wide, .horizontal, tall);

    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(gpa);
    try tree.layout(&placements, 120, 30);

    // `tall` is 60x30, which is wider than tall, so it still divides into columns. Narrow it
    // further by giving the split an uneven ratio.
    try tree.setRatio(tall, 0.85);
    try tree.layout(&placements, 120, 30);
    const narrow = placements.items[1].rect;
    try std.testing.expect(narrow.width < narrow.height);

    const other = tree.allocateId();
    const axis = try tree.splitLongest(tall, other, 120, 30);
    try std.testing.expectEqual(Axis.vertical, axis);
}

test "a pane's interior is inset by the frame on every side" {
    // The rectangle the pty is sized to and the rectangle the client paints into have to be the
    // same one. An off-by-one here is a program wrapping one column away from where the border is,
    // or a last row that the border has eaten.
    const rect = Rect{ .x = 10, .y = 5, .width = 20, .height = 10 };
    const inner = rect.interior();
    try std.testing.expectEqual(@as(u16, 11), inner.x);
    try std.testing.expectEqual(@as(u16, 6), inner.y);
    try std.testing.expectEqual(@as(u16, 18), inner.width);
    try std.testing.expectEqual(@as(u16, 8), inner.height);

    // The interior is strictly inside the pane, and the border is the ring around it.
    try std.testing.expect(inner.x > rect.x and inner.y > rect.y);
    try std.testing.expect(inner.x + inner.width < rect.x + rect.width);
    try std.testing.expect(inner.y + inner.height < rect.y + rect.height);
}

test "a pane too small for a frame keeps all of its cells" {
    // A one- or two-cell pane has no room for a border and content both. Insisting on the border
    // would leave a zero-sized terminal, which libghostty-vt rejects, so the pane is left whole and
    // simply has no frame.
    for ([_]Rect{
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 2, .height = 10 },
        .{ .x = 0, .y = 0, .width = 10, .height = 2 },
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    }) |tiny| {
        try std.testing.expect(tiny.interior().eql(tiny));
    }

    // Three by three is the smallest that fits a frame and one cell inside it.
    const smallest = Rect{ .x = 0, .y = 0, .width = 3, .height = 3 };
    try std.testing.expectEqual(@as(u16, 1), smallest.interior().width);
    try std.testing.expectEqual(@as(u16, 1), smallest.interior().height);
}

test "swapping moves a pane past its neighbour without disturbing the shape" {
    // The identifiers move between the leaves; the tree's shape does not. That is what keeps a swap
    // from redrawing the layout: the split ratios still describe the arrangement the user built.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    // Three panes side by side, so there is an order to move along.
    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    const c = tree.allocateId();
    try tree.split(b, .horizontal, c);

    var order: std.ArrayList(PaneId) = .empty;
    defer order.deinit(gpa);
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ a, b, c }, order.items);

    // b moves past c.
    try std.testing.expect(tree.swapWithNext(b));
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ a, c, b }, order.items);

    // And back again with the other key.
    try std.testing.expect(tree.swapWithPrevious(b));
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ a, b, c }, order.items);

    // The shape is unchanged: three leaves in a tree of three, so two branches.
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expect(tree.contains(a) and tree.contains(b) and tree.contains(c));

    // A swap at the end wraps rather than doing nothing, matching what the focus keys do.
    try std.testing.expect(tree.swapWithNext(c));
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ c, b, a }, order.items);
}

test "swapping has nothing to do in a tree of one" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);

    // One pane has no neighbour, so the key does nothing rather than reporting a failure it cannot
    // act on.
    try std.testing.expect(!tree.swapWithNext(only));
    try std.testing.expect(!tree.swapWithPrevious(only));

    // A pane that is not in the tree cannot be swapped either.
    try std.testing.expect(!tree.swapWithNext(tree.allocateId()));

    var order: std.ArrayList(PaneId) = .empty;
    defer order.deinit(gpa);
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{only}, order.items);
}

test "rotating shifts every pane one place, last to first" {
    // Rotating is not a sequence of swaps: with three panes or more, pairwise swaps cannot produce
    // the shift without a plan. One pass over the leaves does it, and the direction matches tmux's
    // rotate key so a user's habit carries over.
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const a = tree.allocateId();
    try tree.setRoot(a);
    const b = tree.allocateId();
    try tree.split(a, .horizontal, b);
    const c = tree.allocateId();
    try tree.split(b, .horizontal, c);

    var order: std.ArrayList(PaneId) = .empty;
    defer order.deinit(gpa);
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ a, b, c }, order.items);

    // Each pane takes the place of the one before it, and the last takes the first place.
    try std.testing.expect(tree.rotate());
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ c, a, b }, order.items);

    // A full turn of the ring returns the original arrangement.
    try std.testing.expect(tree.rotate());
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ b, c, a }, order.items);
    try std.testing.expect(tree.rotate());
    try tree.collect(&order);
    try std.testing.expectEqualSlices(PaneId, &.{ a, b, c }, order.items);

    // Rotating never changes how many panes there are.
    try std.testing.expectEqual(@as(usize, 3), tree.count());
}

test "rotating has nothing to do in a tree of one" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    const only = tree.allocateId();
    try tree.setRoot(only);
    try std.testing.expect(!tree.rotate());
    try std.testing.expect(tree.rotate() == false);
}
