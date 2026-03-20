const std = @import("std");
const Workspace = @import("Workspace.zig");
const c = @import("c.zig").c;

pub const WorkspaceManager = @This();

workspaces: std.ArrayList(Workspace),
active_workspace: usize,
// full term size
cols: u16,
rows: u16,
termios: c.termios,

pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, termios: c.termios) !WorkspaceManager {
    var workspaces: std.ArrayList(Workspace) = .empty;
    errdefer workspaces.deinit(alloc);

    const initial_ws: Workspace = try Workspace.init(alloc, cols, rows, termios);
    try workspaces.append(alloc, initial_ws);

    return .{
        .workspaces = workspaces,
        .active_workspace = 0,
        .cols = cols,
        .rows = rows,
        .termios = termios,
    };
}

pub fn deinit(self: *WorkspaceManager, alloc: std.mem.Allocator) void {
    for (self.workspaces.items) |*ws| {
        ws.deinit(alloc);
    }
    self.workspaces.deinit(alloc);
}

pub fn getActiveWorkspace(self: *WorkspaceManager) ?*Workspace {
    if (self.workspaces.items.len == 0) return null;
    return &self.workspaces.items[self.active_workspace];
}

pub fn switchWorkspace(self: *WorkspaceManager, idx: usize) void {
    if (idx > self.workspaces.items.len) return;

    self.active_workspace = idx;
}

pub fn nextWorkspace(self: *WorkspaceManager) ?*Workspace {
    self.active_workspace = (self.active_workspace + 1) % self.workspaces.items.len;
    return self.getActiveWorkspace();
}

pub fn prevWorkspace(self: *WorkspaceManager) ?*Workspace {
    const len = self.workspaces.items.len;
    self.active_workspace = (self.active_workspace + len - 1) % len;
    return self.getActiveWorkspace();
}

pub fn appendWorkspace(self: *WorkspaceManager, alloc: std.mem.Allocator) !void {
    const new_ws: Workspace = try Workspace.init(alloc, self.cols, self.rows, self.termios);
    try self.workspaces.append(alloc, new_ws);
}

/// Moves the active pane to the workspace at target_idx.
/// Switches to that workspace after moving.
/// If the source workspace becomes empty, it is automatically removed.
pub fn movePaneToWorkspace(
    self: *WorkspaceManager,
    alloc: std.mem.Allocator,
    target_idx: usize,
) !void {
    if (target_idx >= self.workspaces.items.len) return;
    if (target_idx == self.active_workspace) return;

    const src_ws = &self.workspaces.items[self.active_workspace];
    const dst_ws = &self.workspaces.items[target_idx];

    const maybe_pane = try src_ws.detachPane(alloc);

    if (maybe_pane) |pane| {
        try dst_ws.attachPane(alloc, pane);
        self.switchWorkspace(target_idx);
    } else {
        const pane = src_ws.extractLastPane();
        const src_root = src_ws.root;

        try dst_ws.attachPane(alloc, pane);

        alloc.destroy(src_root);

        const removed_idx = self.active_workspace;
        _ = self.workspaces.orderedRemove(removed_idx);

        const adjusted = if (target_idx > removed_idx) target_idx - 1 else target_idx;
        self.switchWorkspace(adjusted);
    }
}
