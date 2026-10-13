const std = @import("std");
const clap = @import("clap");
const vt = @import("vt.zig");

pub const version = "0.1.0";

/// The subcommands zmux accepts.
///
/// The server side of `ls`, `attach`, `detach`, `kill` and `kill-all` is not
/// implemented yet; those arms report that rather than pretending to act.
const Command = enum {
    ls,
    attach,
    detach,
    kill,
    kill_all,
    dump,

    /// The name as typed on the command line.
    ///
    /// `std.meta.stringToEnum` matches tag names verbatim, so `kill_all` would
    /// only be reachable as `kill_all`. zmux spells it `kill-all`.
    fn cliName(self: Command) []const u8 {
        return switch (self) {
            .kill_all => "kill-all",
            inline else => |tag| @tagName(tag),
        };
    }
};

/// Parse a subcommand name, accepting dashes where the enum uses underscores.
fn parseCommand(text: []const u8) clap.parsers.EnumError!Command {
    inline for (std.enums.values(Command)) |command| {
        if (std.mem.eql(u8, text, command.cliName())) return command;
    }
    return error.NameNotPartOfEnum;
}

const main_parsers = .{
    .command = parseCommand,
};

const main_params = clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-V, --version  Print the version and exit.
    \\<command>
    \\
);

const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

/// Argument shapes for the subcommands that need arguments.
///
/// The positional is spelled `<SESSION>` so that `session_parsers` below can
/// match it: clap looks a value parser up by the parameter's value name.
const attach_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<SESSION>
    \\
);

const kill_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<SESSION>
    \\
);

const session_parsers = .{
    .SESSION = clap.parsers.string,
};

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

    var diag = clap.Diagnostic{};
    var result = clap.parseEx(clap.Help, &main_params, main_parsers, &args_iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        // Stop after the subcommand so `args_iter` stays positioned at the
        // arguments belonging to it.
        .terminating_positional = 0,
    }) catch |parse_error| {
        try diag.report(err, parse_error);
        try err.flush();
        std.process.exit(2);
    };
    defer result.deinit();

    if (result.args.version != 0) {
        try out.print("zmux {s}\n", .{version});
        try out.flush();
        return;
    }

    // With no subcommand, print help. That is friendlier than an error for a
    // bare `zmux`, and matches what the help text advertises.
    const command = result.positionals[0] orelse {
        try printHelp(out);
        try out.flush();
        return;
    };
    if (result.args.help != 0) {
        try printHelp(out);
        try out.flush();
        return;
    }

    switch (command) {
        .ls => try reportUnimplemented(err, .ls),
        .attach => try runAttach(gpa, err, &args_iter, &diag),
        .detach => try reportUnimplemented(err, .detach),
        .kill => try runKill(gpa, err, &args_iter, &diag),
        .kill_all => try reportUnimplemented(err, .kill_all),
        .dump => try runDump(gpa, io, out),
    }

    try out.flush();
    try err.flush();
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\zmux - a simple terminal multiplexer
        \\
        \\Usage: zmux <command> [options]
        \\
        \\Commands:
        \\  ls              List sessions
        \\  attach <name>   Attach to a session, opening the TUI
        \\  detach          Detach the current client from its session
        \\  kill <name>     Terminate a session
        \\  kill-all        Terminate every session
        \\  dump            Parse VT data from stdin and print the resulting screen
        \\
        \\Options:
        \\  -h, --help      Display this help and exit
        \\  -V, --version   Print the version and exit
        \\
    );
}

test "the help text lists every command" {
    // The help text is hand-written, so a new command would silently go
    // undocumented. Check each name appears in it.
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try printHelp(&writer);
    const text = writer.buffered();

    for (std.enums.values(Command)) |command| {
        if (std.mem.indexOf(u8, text, command.cliName()) == null) {
            std.debug.print("help text omits '{s}'\n", .{command.cliName()});
            return error.HelpTextIncomplete;
        }
    }
}

/// Report a subcommand that exists in the interface but has no server behind
/// it yet. Saying so plainly is better than exiting silently.
fn reportUnimplemented(err: *std.Io.Writer, command: Command) !void {
    try err.print(
        "zmux: {s} is not implemented yet; the server arrives in a later phase\n",
        .{command.cliName()},
    );
    try err.flush();
    std.process.exit(1);
}

fn runAttach(
    gpa: std.mem.Allocator,
    err: *std.Io.Writer,
    args_iter: *std.process.Args.Iterator,
    diag: *clap.Diagnostic,
) !void {
    var result = clap.parseEx(clap.Help, &attach_params, session_parsers, args_iter, .{
        .diagnostic = diag,
        .allocator = gpa,
    }) catch |parse_error| {
        try diag.report(err, parse_error);
        try err.flush();
        std.process.exit(2);
    };
    defer result.deinit();

    const session = result.positionals[0] orelse {
        try err.writeAll("zmux: attach requires a session name\n");
        try err.flush();
        std.process.exit(2);
    };
    _ = session;

    try reportUnimplemented(err, .attach);
}

fn runKill(
    gpa: std.mem.Allocator,
    err: *std.Io.Writer,
    args_iter: *std.process.Args.Iterator,
    diag: *clap.Diagnostic,
) !void {
    var result = clap.parseEx(clap.Help, &kill_params, session_parsers, args_iter, .{
        .diagnostic = diag,
        .allocator = gpa,
    }) catch |parse_error| {
        try diag.report(err, parse_error);
        try err.flush();
        std.process.exit(2);
    };
    defer result.deinit();

    const session = result.positionals[0] orelse {
        try err.writeAll("zmux: kill requires a session name\n");
        try err.flush();
        std.process.exit(2);
    };
    _ = session;

    try reportUnimplemented(err, .kill);
}

fn runDump(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    // Verification path: read VT bytes from stdin, parse them with
    // libghostty-vt, and print the resulting screen as text.
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(input);

    try dumpScreen(gpa, out, input, .{ .cols = 80, .rows = 24 });
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

test "every command parses from its command line spelling" {
    for (std.enums.values(Command)) |command| {
        try std.testing.expectEqual(command, try parseCommand(command.cliName()));
    }
}

test "kill-all parses despite the underscore in the enum tag" {
    try std.testing.expectEqual(Command.kill_all, try parseCommand("kill-all"));
}

test "unknown commands are rejected" {
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand("bogus"));
    // The underscore spelling is not the interface, so it must not work.
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand("kill_all"));
}
