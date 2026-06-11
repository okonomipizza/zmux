const std = @import("std");
const Pty = @import("Pty.zig");
const ghostty = @import("ghostty-vt");
const Terminal = ghostty.Terminal;
const TerminalStream = ghostty.TerminalStream;

const c = @import("c.zig").c;

pub const Pane = @This();

/// VT stream specialized with our handler so OSC 52 (clipboard) can be
/// intercepted; everything else is delegated to the ghostty handler.
pub const VtStream = ghostty.Stream(StreamHandler);

/// Cap on buffered OSC 52 passthrough data. Matches the copy-mode limit
/// in Server.zig and stays well below the client's 256 KiB frame buffer,
/// which would disconnect on an oversized frame.
const max_pending_clipboard = 64 * 1024;

pty: Pty,
// Manage terminal buffer with lib-ghostty
terminal: Terminal,
vt_stream: VtStream,
// OSC 52 sequences re-encoded for passthrough; drained by the server
// after each feed() and broadcast to attached clients.
pending_clipboard: std.ArrayList(u8),
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
        .pending_clipboard = .empty,
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
    self.pending_clipboard.deinit(alloc);
    self.terminal.deinit(alloc);
}

/// Initialize the VT stream and wire up effect callbacks so terminal
/// queries like DA1 (CSI c) get a response written back to the PTY.
/// Must be called after the Pane is at its final heap address — the
/// callbacks recover the Pane via @fieldParentPtr on Handler.terminal.
pub fn initStream(self: *Pane) void {
    self.vt_stream = .initAlloc(self.terminal.gpa(), .{
        .inner = self.terminal.vtHandler(),
    });
    self.vt_stream.handler.inner.effects.write_pty = writePty;
    self.vt_stream.handler.inner.effects.device_attributes = deviceAttributes;
}

const Handler = TerminalStream.Handler;

/// Wraps ghostty's terminal stream handler to intercept OSC 52
/// (clipboard) actions, which the built-in handler ignores. All other
/// actions are forwarded unchanged.
pub const StreamHandler = struct {
    inner: Handler,

    pub fn deinit(self: *StreamHandler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *StreamHandler,
        comptime action: ghostty.StreamAction.Tag,
        value: ghostty.StreamAction.Value(action),
    ) void {
        switch (action) {
            .clipboard_contents => {
                const pane: *Pane = @fieldParentPtr("terminal", self.inner.terminal);
                appendOsc52Passthrough(
                    &pane.pending_clipboard,
                    pane.terminal.gpa(),
                    value.kind,
                    value.data,
                ) catch {};
            },
            else => self.inner.vt(action, value),
        }
    }
};

/// Re-encode an OSC 52 set-clipboard request and append it to `out` for
/// passthrough to the user's real terminal. The sequence is rebuilt from
/// scratch rather than echoing received bytes, and anything outside the
/// spec is dropped:
/// - read requests ("?") are never forwarded (clipboard exfiltration)
/// - kind must be a valid selection character (c, p, s, 0-7)
/// - data must be non-empty and use only base64 characters
/// - the pending buffer is capped at max_pending_clipboard
fn appendOsc52Passthrough(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    kind: u8,
    data: []const u8,
) !void {
    switch (kind) {
        'c', 'p', 's', '0'...'7' => {},
        else => return,
    }
    if (data.len == 0) return;
    for (data) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=' => {},
        else => return,
    };

    const prefix = "\x1b]52;?;".len; // kind + separators, same length for any kind
    const suffix = "\x1b\\".len;
    const seq_len = prefix + data.len + suffix;
    if (out.items.len + seq_len > max_pending_clipboard) return;

    try out.ensureUnusedCapacity(alloc, seq_len);
    out.appendSliceAssumeCapacity("\x1b]52;");
    out.appendAssumeCapacity(kind);
    out.appendAssumeCapacity(';');
    out.appendSliceAssumeCapacity(data);
    out.appendSliceAssumeCapacity("\x1b\\");
}

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

test "appendOsc52Passthrough forwards a valid set request" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendOsc52Passthrough(&out, alloc, 'c', "aGVsbG8=");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", out.items);
}

test "appendOsc52Passthrough accumulates multiple sequences" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendOsc52Passthrough(&out, alloc, 'c', "YQ==");
    try appendOsc52Passthrough(&out, alloc, 'p', "Yg==");
    try std.testing.expectEqualStrings("\x1b]52;c;YQ==\x1b\\\x1b]52;p;Yg==\x1b\\", out.items);
}

test "appendOsc52Passthrough drops read requests" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendOsc52Passthrough(&out, alloc, 'c', "?");
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "appendOsc52Passthrough drops invalid kind and payload" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Invalid selection kind
    try appendOsc52Passthrough(&out, alloc, 'x', "aGVsbG8=");
    // Empty payload
    try appendOsc52Passthrough(&out, alloc, 'c', "");
    // Bytes outside the base64 alphabet must never reach the host terminal
    try appendOsc52Passthrough(&out, alloc, 'c', "aGVs\x1b]0;bG8=");
    try appendOsc52Passthrough(&out, alloc, 'c', "aGVs;bG8=");
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "appendOsc52Passthrough enforces the pending buffer cap" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const big = try alloc.alloc(u8, max_pending_clipboard);
    defer alloc.free(big);
    @memset(big, 'A');

    try appendOsc52Passthrough(&out, alloc, 'c', big);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // A payload that fits is still accepted afterwards
    try appendOsc52Passthrough(&out, alloc, 'c', "aGVsbG8=");
    try std.testing.expect(out.items.len > 0);
}
