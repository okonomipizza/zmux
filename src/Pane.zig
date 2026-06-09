const std = @import("std");
const Pty = @import("Pty.zig");
const Terminal = @import("ghostty-vt").Terminal;
const TerminalStream = @import("ghostty-vt").TerminalStream;

const c = @import("c.zig").c;

pub const Pane = @This();

pty: Pty,
// Manage terminal buffer with lib-ghostty
terminal: Terminal,
vt_stream: TerminalStream,
// x and y represent the cordinates of the top-left corner of the pane (0-indexed)
x: u16,
y: u16,
// cols * rows represents the dimentions of the pane
cols: u16,
rows: u16,
// Only a pane in the screen can be active
is_active: bool,
// Dirty flag: set when pane receives PTY output, cleared after render
is_dirty: bool,

pub fn init(
    alloc: std.mem.Allocator,
    termios: c.termios,
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
) !Pane {
    return .{
        .pty = try Pty.init(cols, rows, termios),
        .terminal = try Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 100_000, // 100k lines of scrollback
        }),
        .vt_stream = undefined,
        .x = x,
        .y = y,
        .cols = cols,
        .rows = rows,
        .is_active = false,
        .is_dirty = true, // Start dirty to ensure initial render
    };
}

pub fn deinit(self: *Pane, alloc: std.mem.Allocator) void {
    self.pty.deinit();
    self.vt_stream.deinit();
    self.terminal.deinit(alloc);
}

/// Initialize the VT stream and wire up effect callbacks so terminal
/// queries like DA1 (CSI c) get a response written back to the PTY.
/// Must be called after the Pane is at its final heap address — the
/// callbacks recover the Pane via @fieldParentPtr on Handler.terminal.
pub fn initStream(self: *Pane) void {
    self.vt_stream = self.terminal.vtStream();
    self.vt_stream.handler.effects.write_pty = writePty;
    self.vt_stream.handler.effects.device_attributes = deviceAttributes;
}

const Handler = TerminalStream.Handler;

const Attributes = blk: {
    const da_field = @FieldType(Handler.Effects, "device_attributes");
    const FnPtr = @typeInfo(da_field).optional.child;
    break :blk @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
};

fn writePty(handler: *Handler, data: [:0]const u8) void {
    const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
    pane.pty.write(data) catch {};
}

fn deviceAttributes(_: *Handler) Attributes {
    return .{};
}

pub fn feed(self: *Pane, data: []const u8) void {
    self.vt_stream.nextSlice(data);
    self.is_dirty = true;
}

pub fn resize(
    self: *Pane,
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
) !void {
    self.cols = cols;
    self.rows = rows;
    try self.terminal.resize(alloc, cols, rows);
    try self.pty.resize(cols, rows);
}
