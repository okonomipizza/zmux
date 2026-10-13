const std = @import("std");
const clap = @import("clap");
const vt = @import("vt.zig");
const session_mod = @import("session.zig");
const terminal_mod = @import("terminal.zig");
const protocol = @import("protocol.zig");
const runtime = @import("runtime.zig");
const server_mod = @import("server.zig");
const client_mod = @import("client.zig");
const socket = @import("socket.zig");

pub const version = "0.1.0";

/// The subcommands zmux accepts.
const Command = enum {
    ls,
    attach,
    detach,
    kill,
    kill_all,
    dump,
    run,

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

/// Argument shapes for the subcommands that take a session name.
///
/// The positional is spelled `<SESSION>` so that `session_parsers` below can
/// match it: clap looks a value parser up by the parameter's value name.
///
/// This list must not also declare a `--name <SESSION>` option. clap numbers
/// positionals by declaration order across *all* parameters, so an option whose
/// value name matches the positional's shifts the positional's slot, and the
/// argument then parses as an unset option value instead of as the name. `run`,
/// which genuinely needs both, has its own list below for that reason.
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

/// `run` takes the command to start, or uses `$SHELL` when given none.
const run_params = clap.parseParamsComptime(
    \\-h, --help      Display this help and exit.
    \\-d, --detached  Start the session without attaching to it.
    \\-n, --name <NAME>  Name the session instead of using a generated one.
    \\<PROGRAM>...
    \\
);

const run_parsers = .{
    .NAME = clap.parsers.string,
    .PROGRAM = clap.parsers.string,
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
        .ls => try runQuery(gpa, init.environ, out, err, .list),
        .attach => try runAttach(gpa, init.environ, err, &args_iter, &diag),
        .detach => try runDetach(gpa, init.environ, err),
        .kill => try runKill(gpa, init.environ, err, &args_iter, &diag),
        .kill_all => try runQuery(gpa, init.environ, out, err, .kill_all),
        .dump => try runDump(gpa, io, out),
        .run => try runProgram(gpa, init.environ, out, err, &args_iter, &diag),
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
        \\  kill <session>  Terminate a session
        \\  kill-all        Terminate every session
        \\  run [program]   Start a session running a program and attach to it
        \\  dump            Parse VT data from stdin and print the resulting screen
        \\
        \\Options:
        \\  -h, --help      Display this help and exit
        \\  -V, --version   Print the version and exit
        \\
        \\Run options:
        \\  -d, --detached  Start the session without attaching to it
        \\  -n, --name <name>  Name the session instead of generating one
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

/// Where the socket lives, resolved from the environment.
const Paths = struct {
    dir: []const u8,
    socket_path: []const u8,

    fn resolve(environ: std.process.Environ) !Paths {
        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
        // Both buffers must outlive the returned slices, so the paths are
        // copied into static storage once they have been built.
        const dir = try runtime.runtimeDir(environ, &dir_buffer);
        const path = try runtime.socketPath(environ, &socket_buffer);
        dir_cache = dir_buffer;
        socket_cache = socket_buffer;
        return .{ .dir = dir_cache[0..dir.len], .socket_path = socket_cache[0..path.len] };
    }
};

/// Static storage for the resolved paths.
///
/// `Paths.resolve` builds both paths in local buffers and then returns slices of
/// them, which would dangle. Keeping them here rather than allocating is
/// deliberate: the paths are needed for the whole life of the process, so there
/// is nothing to free.
var dir_cache: [std.fs.max_path_bytes]u8 = undefined;
var socket_cache: [std.fs.max_path_bytes]u8 = undefined;

/// Make sure a server is listening, starting one if not.
///
/// The server is forked rather than exec'd so that it inherits the same
/// executable, and it is put in its own session so that closing the terminal
/// that started it does not take the sessions down with it.
fn ensureServer(gpa: std.mem.Allocator, env: std.process.Environ, err: *std.Io.Writer) !void {
    const paths = try Paths.resolve(env);

    _ = runtime.ensureRuntimeDir(paths.dir) catch {
        try err.print("zmux: cannot create {s}\n", .{paths.dir});
        try err.flush();
        std.process.exit(1);
    };

    if (runtime.serverIsRunning(paths.socket_path)) return;

    // The socket file outlives the process that made it, so a leftover from a
    // server that was killed is removed here. `serverIsRunning` has already
    // established that nothing is listening on it.
    socket.removeFile(paths.socket_path);

    // `std.posix.fork` does not exist in Zig 0.16; the raw syscall does. Its
    // result is a `usize` whose sign carries the error, so it is checked before
    // being narrowed to a pid.
    const raw = std.os.linux.fork();
    if (std.os.linux.errno(raw) != .SUCCESS) {
        try err.writeAll("zmux: cannot start the server process\n");
        try err.flush();
        std.process.exit(1);
    }
    const child: std.os.linux.pid_t = @intCast(@as(isize, @bitCast(raw)));

    if (child == 0) {
        // Child: become the server. Detaching from the controlling terminal is
        // what lets the sessions outlive the shell that started them.
        _ = std.os.linux.setsid();
        serve(gpa, env) catch |server_error| {
            std.debug.print("zmux: server failed to start: {s}\n", .{@errorName(server_error)});
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    // The parent waits for the socket to appear rather than sleeping a fixed
    // time, so a fast start does not pay for a slow guess.
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        if (runtime.serverIsRunning(paths.socket_path)) return;
        sleepMillis(1);
    }

    try err.writeAll("zmux: the server did not start\n");
    try err.flush();
    std.process.exit(1);
}

/// Run the server in this process. Never returns except on failure.
fn serve(gpa: std.mem.Allocator, env: std.process.Environ) !void {
    const paths = try Paths.resolve(env);
    const server = try server_mod.Server.init(gpa, paths.socket_path, env);
    defer server.deinit();
    try server.run();
}

fn sleepMillis(milliseconds: u64) void {
    const request = std.os.linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&request, null);
}

/// The wall clock in milliseconds.
///
/// `std.time.milliTimestamp` does not exist in Zig 0.16: `std.time` is down to
/// unit constants, and the clock reads moved to `std.Io`. The raw syscall avoids
/// threading an `Io` through just to build a session name.
fn milliTimestamp() i64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.REALTIME, &now)) != .SUCCESS) return 0;
    return @as(i64, now.sec) * std.time.ms_per_s + @divTrunc(@as(i64, now.nsec), std.time.ns_per_ms);
}

/// Run a request that prints a result, without drawing anything.
fn runQuery(
    gpa: std.mem.Allocator,
    env: std.process.Environ,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    request: protocol.Request,
) !void {
    try ensureServer(gpa, env, err);

    const paths = try Paths.resolve(env);
    const client = client_mod.Client.init(gpa, paths.socket_path, .query, out, err) catch {
        try err.writeAll("zmux: cannot reach the server\n");
        try err.flush();
        std.process.exit(1);
    };
    defer client.deinit();

    try client.sendRequest(request);
    client.runQuery() catch |query_error| switch (query_error) {
        else => {
            try err.print("zmux: {s}\n", .{@errorName(query_error)});
            try err.flush();
            std.process.exit(1);
        },
    };

    // A rejected request is reported by the server, and the shell has to be able
    // to see that, or a script cannot tell a failure from an empty result.
    if (client.failed) {
        try out.flush();
        try err.flush();
        std.process.exit(1);
    }
}

/// Copy a parsed positional into stable storage.
///
/// `Args.Iterator.next` returns a slice into the iterator's own buffer, and that
/// buffer is reused by the following call. clap keeps the slice, so a positional
/// read out of a `clap.ResultEx` is only valid until the iterator advances again
/// — which happens as soon as any further argument is parsed. Copying it first is
/// what stops the name from silently becoming a stale argument from an earlier
/// invocation, which is a failure that looks like the server denying a session
/// that plainly exists.
fn copyName(buffer: []u8, name: []const u8) []const u8 {
    const length = @min(buffer.len, name.len);
    @memcpy(buffer[0..length], name[0..length]);
    return buffer[0..length];
}

/// Attach to an existing session.
fn runAttach(
    gpa: std.mem.Allocator,
    env: std.process.Environ,
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

    // Copied before anything else touches the iterator; see `copyName`.
    var name_buffer: [protocol.name_max]u8 = undefined;
    const name = copyName(&name_buffer, result.positionals[0] orelse {
        try err.writeAll("zmux: attach requires a session name\n");
        try err.flush();
        std.process.exit(2);
    });
    const session_name = protocol.Name.init(name) catch {
        try err.writeAll("zmux: invalid session name\n");
        try err.flush();
        std.process.exit(2);
    };

    try ensureServer(gpa, env, err);

    // The client's size is read from the terminal being attached, because that
    // is the size the session's pty should take.
    const local = terminal_mod.Terminal.enter() catch {
        try err.writeAll("zmux: attach needs a terminal on stdin\n");
        try err.flush();
        std.process.exit(1);
    };
    var local_terminal = local;
    defer local_terminal.leave();
    const probed = local_terminal.size() catch terminal_mod.vtSize{ .rows = 24, .cols = 80 };
    const size = terminal_mod.vtSize{
        .rows = if (probed.rows == 0) 24 else probed.rows,
        .cols = if (probed.cols == 0) 80 else probed.cols,
    };

    const paths = try Paths.resolve(env);
    const client = client_mod.Client.init(gpa, paths.socket_path, .interactive, err, err) catch {
        try err.writeAll("zmux: cannot reach the server\n");
        try err.flush();
        std.process.exit(1);
    };
    defer client.deinit();

    try client.sendRequest(.{ .attach = .{
        .name = session_name,
        .rows = size.rows,
        .cols = size.cols,
    } });

    // The terminal was entered to measure it; the client takes it over.
    local_terminal.leave();
    client.runInteractive(size.rows, size.cols) catch |attach_error| switch (attach_error) {
        else => {
            try err.print("zmux: {s}\n", .{@errorName(attach_error)});
            try err.flush();
        },
    };
}

/// Detach the current client. Only meaningful from inside an attached client,
/// which zmux does not yet support, so this reports that.
fn runDetach(gpa: std.mem.Allocator, env: std.process.Environ, err: *std.Io.Writer) !void {
    _ = gpa;
    _ = env;
    try err.writeAll("zmux: detach is sent by an attached client; press ctrl-a to detach\n");
    try err.flush();
    std.process.exit(1);
}

fn runKill(
    gpa: std.mem.Allocator,
    env: std.process.Environ,
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

    // Copied for the same reason as in `runAttach`.
    var name_buffer: [protocol.name_max]u8 = undefined;
    const name = copyName(&name_buffer, result.positionals[0] orelse {
        try err.writeAll("zmux: kill requires a session name\n");
        try err.flush();
        std.process.exit(2);
    });
    const session_name = protocol.Name.init(name) catch {
        try err.writeAll("zmux: invalid session name\n");
        try err.flush();
        std.process.exit(2);
    };

    try ensureServer(gpa, env, err);

    const paths = try Paths.resolve(env);
    const client = client_mod.Client.init(gpa, paths.socket_path, .query, err, err) catch {
        try err.writeAll("zmux: cannot reach the server\n");
        try err.flush();
        std.process.exit(1);
    };
    defer client.deinit();

    try client.sendRequest(.{ .kill = .{ .name = session_name } });
    try client.runQuery();
    if (client.failed) {
        try err.flush();
        std.process.exit(1);
    }
}

/// Start a session, optionally attaching to it.
fn runProgram(
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    args_iter: *std.process.Args.Iterator,
    diag: *clap.Diagnostic,
) !void {
    var result = clap.parseEx(clap.Help, &run_params, run_parsers, args_iter, .{
        .diagnostic = diag,
        .allocator = gpa,
    }) catch |parse_error| {
        try diag.report(err, parse_error);
        try err.flush();
        std.process.exit(2);
    };
    defer result.deinit();

    const detached = result.args.detached != 0;

    // The session name is either given or generated from the clock, which is
    // enough to be unique among the sessions one user is likely to have.
    var name_buffer: [protocol.name_max]u8 = undefined;
    const name = if (result.args.name) |given|
        given
    else
        std.fmt.bufPrint(&name_buffer, "{d}", .{milliTimestamp() & 0xffffff}) catch "session";

    const session_name = protocol.Name.init(name) catch {
        try err.writeAll("zmux: invalid session name\n");
        try err.flush();
        std.process.exit(2);
    };

    // A generated name is reported, because otherwise there is no way to
    // attach to the session later.
    if (result.args.name == null) {
        try err.print("zmux: session {s}\n", .{name});
        try err.flush();
    }

    try ensureServer(gpa, environ, err);

    // The program travels as one NUL-separated blob, matching what `execve`
    // wants on the other side. `positionals` is a tuple with one field per
    // positional parameter, so the variadic `<PROGRAM>...` is its single element.
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(gpa);
    const given_program = result.positionals[0];
    if (given_program.len > 0) {
        try protocol.joinProgram(&program, gpa, given_program);
    }

    // The size comes from this terminal when attaching, and from a default when
    // there is none, because a detached session still needs a screen to draw
    // into. The terminal is entered only to measure it and is restored
    // immediately; the client enters it again for the session itself.
    var size = terminal_mod.vtSize{ .rows = 24, .cols = 80 };
    var have_terminal = false;
    if (!detached) {
        if (terminal_mod.Terminal.enter() catch null) |local| {
            var probe = local;
            have_terminal = true;
            defer probe.leave();
            if (probe.size() catch null) |probed| {
                if (probed.rows != 0 and probed.cols != 0) size = probed;
            }
        }
    }

    const paths = try Paths.resolve(environ);
    const mode: client_mod.Mode = if (detached) .query else .interactive;
    const client = client_mod.Client.init(gpa, paths.socket_path, mode, out, err) catch {
        try err.writeAll("zmux: cannot reach the server\n");
        try err.flush();
        std.process.exit(1);
    };
    defer client.deinit();

    try client.sendRequest(.{ .create = .{
        .name = session_name,
        .rows = size.rows,
        .cols = size.cols,
        .program = program.items,
    } });

    if (detached) {
        try client.runQuery();
        return;
    }

    if (!have_terminal) {
        try err.writeAll("zmux: run needs a terminal on stdin; use -d to start detached\n");
        try err.flush();
        std.process.exit(1);
    }

    client.runInteractive(size.rows, size.cols) catch |run_error| switch (run_error) {
        else => {
            try err.print("zmux: {s}\n", .{@errorName(run_error)});
            try err.flush();
        },
    };
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
    _ = protocol;
    _ = runtime;
    _ = server_mod;
    _ = client_mod;
    _ = socket;
}

test "a copied name outlives the iterator's buffer" {
    // `copyName` exists because clap stores a slice into the argument
    // iterator's reusable buffer. This pins the property that matters: the
    // copy still reads back the original text after the source has been
    // overwritten, which is exactly what a stale positional does not do.
    var buffer: [protocol.name_max]u8 = undefined;
    var source: [protocol.name_max]u8 = undefined;

    @memcpy(source[0..5], "alpha");
    const copied = copyName(&buffer, source[0..5]);

    // Simulate the iterator handing its buffer to the next argument.
    @memcpy(source[0..4], "long");
    try std.testing.expectEqualStrings("alpha", copied);
}

test "an overlong name is truncated rather than overrun" {
    var buffer: [protocol.name_max]u8 = undefined;
    const long = "a" ** (protocol.name_max + 20);
    const copied = copyName(&buffer, long);
    try std.testing.expectEqual(@as(usize, protocol.name_max), copied.len);
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
