const std = @import("std");
const vt = @import("vt.zig");

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var args_iter = try init.args.iterateAllocator(gpa);
    defer args_iter.deinit();

    // Skip argv[0].
    _ = args_iter.skip();

    const command = args_iter.next() orelse {
        try usage(out);
        try out.flush();
        return;
    };
    if (std.mem.eql(u8, command, "dump")) {
        // Phase 0 verification path: read VT bytes from stdin, parse them with
        // libghostty-vt, and print the resulting screen as text. This exercises
        // the parser, the render state and the cell accessors before any pty
        // or server code exists.
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        const input = try stdin_reader.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(input);

        try dumpScreen(gpa, out, input, .{ .cols = 80, .rows = 24 });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try out.print("zmux {s}\n", .{version});
        try out.flush();
        return;
    }

    try err.print("zmux: unknown command '{s}'\n", .{command});
    try err.flush();
    try usage(out);
    try out.flush();
    std.process.exit(2);
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\zmux - a simple terminal multiplexer
        \\
        \\Usage:
        \\  zmux dump       Parse VT data from stdin and print the resulting screen
        \\  zmux --version  Print the version
        \\
    );
}

/// Feed `input` through a fresh terminal and render its screen as text.
fn dumpScreen(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    input: []const u8,
    options: vt.Terminal.Options,
) !void {
    var terminal = try vt.Terminal.init(options);
    defer terminal.deinit();

    terminal.write(input);

    var render = try terminal.createRenderState();
    defer render.deinit();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    const Renderer = struct {
        gpa: std.mem.Allocator,
        out: *std.Io.Writer,
        line: *std.ArrayList(u8),

        fn visit(self: *@This(), row: *vt.RowIterator) bool {
            self.line.clearRetainingCapacity();
            _ = row.forEachCell(self, collect) catch return false;

            // Trim trailing blanks so the output does not carry the full width
            // of padding on every line.
            const text = std.mem.trimEnd(u8, self.line.items, " ");
            self.out.print("{s}\n", .{text}) catch return false;
            return true;
        }

        fn collect(self: *@This(), cell: *vt.CellIterator) void {
            var codepoints: [8]u32 = undefined;
            var utf8: [32]u8 = undefined;
            const bytes = cell.graphemesUtf8(&codepoints, &utf8);
            if (bytes.len == 0) {
                self.line.append(self.gpa, ' ') catch {};
                return;
            }
            self.line.appendSlice(self.gpa, bytes) catch {};
        }
    };

    var renderer = Renderer{ .gpa = gpa, .out = out, .line = &line };
    try render.forEachRow(&renderer, Renderer.visit);
}

test {
    _ = vt;
}

test "version is exposed" {
    try std.testing.expect(version.len > 0);
}
