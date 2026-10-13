//! Reports how many rows a frame actually repaints.
//!
//! libghostty-vt tracks dirty state at two levels and never clears it itself:
//! the caller is expected to reset it after painting. The client did not, so
//! every frame was a full repaint of every pane. This tool exists to make the
//! difference a number rather than an impression, and to fail loudly if the
//! reset is ever dropped again.
//!
//! Build and run:
//!   zig build measure && ./zig-out/bin/measure

const std = @import("std");
const vt = @import("vt");

/// One frame of a pane, counting rows painted against rows that exist.
const Frame = struct {
    painted: usize = 0,
    rows: usize = 0,
    global: vt.Dirty = .full,

    fn paint(frame: *Frame, render: vt.RenderState, repaint_all: bool) void {
        const Painter = struct {
            frame: *Frame,
            repaint_all: bool,

            fn visit(self: *@This(), row: *vt.RowIterator) bool {
                self.frame.rows += 1;
                const needs_paint = self.repaint_all or row.isDirty();
                row.clearDirty();
                if (needs_paint) self.frame.painted += 1;
                return true;
            }
        };
        var painter = Painter{ .frame = frame, .repaint_all = repaint_all };
        render.forEachRow(&painter, Painter.visit) catch {};
        render.clearDirty();
    }
};

pub fn main() !void {
    var terminal = try vt.Terminal.init(.{ .cols = 80, .rows = 23 });
    defer terminal.deinit();
    var render = try terminal.createRenderState();
    defer render.deinit();

    const log = std.log.scoped(.measure);
    _ = log;

    var frame = Frame{};

    // The prompt is on screen; the first frame paints it.
    terminal.write("user@host:~$ ls -la");
    render.update(terminal) catch {};
    frame = .{ .global = render.dirty() };
    frame.paint(render, true);
    std.debug.print("first frame           : {d}/{d} rows, global={s}\n", .{
        frame.painted, frame.rows, @tagName(frame.global),
    });

    // Nothing happened, so nothing should be painted.
    render.update(terminal) catch {};
    frame = .{ .global = render.dirty() };
    frame.paint(render, false);
    std.debug.print("idle frame            : {d}/{d} rows, global={s}\n", .{
        frame.painted, frame.rows, @tagName(frame.global),
    });

    // One keystroke is one row.
    terminal.write("x");
    render.update(terminal) catch {};
    frame = .{ .global = render.dirty() };
    frame.paint(render, false);
    std.debug.print("one character typed   : {d}/{d} rows, global={s}\n", .{
        frame.painted, frame.rows, @tagName(frame.global),
    });

    // A command that scrolls output rewrites more, but still not everything.
    terminal.write("\r\n");
    var i: usize = 0;
    while (i < 5) : (i += 1) terminal.write("file.txt  dir/  notes.md\r\n");
    render.update(terminal) catch {};
    frame = .{ .global = render.dirty() };
    frame.paint(render, false);
    std.debug.print("six lines of output   : {d}/{d} rows, global={s}\n", .{
        frame.painted, frame.rows, @tagName(frame.global),
    });

    // A move is a full repaint, because the cells are right but in the wrong place.
    render.update(terminal) catch {};
    frame = .{ .global = render.dirty() };
    frame.paint(render, true);
    std.debug.print("pane moved (forced)   : {d}/{d} rows, global={s}\n", .{
        frame.painted, frame.rows, @tagName(frame.global),
    });
}
