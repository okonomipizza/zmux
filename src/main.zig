const std = @import("std");
const c = @import("c.zig").c;
const posix = std.posix;

const Server = @import("Server.zig");
const client = @import("client.zig").client;

/// zmux app version
const version = "1.1.0";

/// Base directory for zmux sockets
/// The session runs as a daemon in forked threads, with communication between
/// server and client threads occurring via unix domain socket.
const SOCKET_DIR = "/tmp/zmux";

/// Maximum length of a unix-socket path that fits in sockaddr.un. The kernel
/// requires a trailing NUL so we reserve one byte. Derived at comptime from
/// std's sockaddr definition, which already varies across platforms (~108 on
/// Linux, ~104 on macOS).
pub const MAX_SOCKET_PATH_LEN: usize = blk: {
    const path_field = @FieldType(posix.sockaddr.un, "path");
    break :blk @typeInfo(path_field).array.len - 1;
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    const command = args.next() orelse {
        // Default: attach to "default" session or create it
        return attachOrCreate(alloc, "default");
    };

    // Check for flags
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        return printHelp();
    }

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "version")) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buf);
        try writer.interface.writeAll("zmux " ++ version ++ "\n");
        try writer.interface.flush();
        return;
    }

    // Commands
    if (std.mem.eql(u8, command, "new")) {
        // zmux new [session-name]
        const session_name = args.next() orelse "default";
        return newSession(alloc, session_name);
    } else if (std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "-a")) {
        // zmux attach [session-name]
        const session_name = args.next() orelse "default";
        return attachSession(alloc, session_name);
    } else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ls")) {
        // zmux list
        return listSessions(alloc);
    } else if (std.mem.eql(u8, command, "kill")) {
        // zmux kill <session-name>
        const session_name = args.next() orelse {
            var buf: [256]u8 = undefined;
            var writer = std.fs.File.stderr().writer(&buf);
            try writer.interface.writeAll("Usage: zmux kill <session-name>\n");
            try writer.interface.flush();
            return;
        };
        return killSession(session_name);
    } else {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buf);
        try writer.interface.writeAll("Unknown command.\nTo check usage instructions, run 'zmux -h'\n");
        try writer.interface.flush();
        return;
    }
}

fn printHelp() void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    writer.interface.writeAll(
        \\zmux - terminal multiplexer
        \\
        \\Usage: zmux [command] [options]
        \\
        \\Commands:
        \\  new [name]        Create a new session (default: "default")
        \\  attach, -a [name] Attach to an existing session
        \\  list, ls          List all sessions
        \\  kill <name>       Kill a session
        \\  help, -h          Show this help
        \\  version, -v       Show version
        \\
        \\If no command is given, zmux will attach to "default" session
        \\or create it if it doesn't exist.
        \\
        \\Examples:
        \\  zmux              Attach to or create "default" session
        \\  zmux new work     Create a new session named "work"
        \\  zmux attach work  Attach to "work" session
        \\  zmux ls           List all sessions
        \\  zmux kill work    Kill "work" session
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn getSocketPath(alloc: std.mem.Allocator, session_name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.sock", .{ SOCKET_DIR, session_name });
    if (path.len > MAX_SOCKET_PATH_LEN) {
        alloc.free(path);
        return error.SocketPathTooLong;
    }
    return path;
}

fn sessionExists(socket_path: []const u8) bool {
    // Try to connect to the socket to check if session is alive
    const sock_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock_fd);

    var addr = posix.sockaddr.un{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    if (socket_path.len > addr.path.len) return false;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    posix.connect(sock_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return false;
    return true;
}

fn attachOrCreate(alloc: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try getSocketPath(alloc, session_name);
    defer alloc.free(socket_path);

    if (sessionExists(socket_path)) {
        // Session exists, attach to it
        try client(socket_path);
    } else {
        // Session doesn't exist, create it
        try startServerAndAttach(alloc, socket_path);
    }
}

fn newSession(alloc: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try getSocketPath(alloc, session_name);
    defer alloc.free(socket_path);

    if (sessionExists(socket_path)) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        try writer.interface.print("Session '{s}' already exists. Use 'zmux attach {s}' to connect.\n", .{ session_name, session_name });
        try writer.interface.flush();
        return;
    }

    try startServerAndAttach(alloc, socket_path);
}

fn attachSession(alloc: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try getSocketPath(alloc, session_name);
    defer alloc.free(socket_path);

    if (!sessionExists(socket_path)) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        try writer.interface.print("Session '{s}' not found. Use 'zmux new {s}' to create.\n", .{ session_name, session_name });
        try writer.interface.flush();
        return;
    }

    try client(socket_path);
}

fn startServerAndAttach(alloc: std.mem.Allocator, socket_path: []const u8) !void {
    // Create socket directory if it doesn't exist
    std.fs.cwd().makePath(SOCKET_DIR) catch {};

    // Get termios BEFORE forking (while we still have a valid terminal).
    // If stdin isn't a TTY (e.g. redirected), tcgetattr fails and we
    // refuse to start rather than handing undefined termios to the child.
    var original_termios: c.termios = undefined;
    if (c.tcgetattr(c.STDIN_FILENO, &original_termios) != 0) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        try writer.interface.writeAll("zmux: stdin is not a terminal\n");
        try writer.interface.flush();
        return error.NotATerminal;
    }

    // Ready-pipe: child writes 1 byte after listen() succeeds. Parent blocks
    // on read() until that arrives (success) or the child dies and the kernel
    // closes the write end (EOF = failure).
    const ready_pipe = try posix.pipe();

    const pid = try posix.fork();

    if (pid == 0) {
        posix.close(ready_pipe[0]);

        // Child: become session leader and run server
        _ = posix.setsid() catch {};

        // Detach stdio: dup2 a single /dev/null fd onto 0/1/2 so the
        // assignment is explicit instead of relying on "open returns the
        // lowest free fd" after a sequence of close()/open() calls.
        const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
        posix.dup2(devnull, 0) catch {};
        posix.dup2(devnull, 1) catch {};
        posix.dup2(devnull, 2) catch {};
        if (devnull > 2) posix.close(devnull);

        Server.server(alloc, socket_path, original_termios, ready_pipe[1]) catch {};
        posix.exit(0);
    } else {
        posix.close(ready_pipe[1]);
        defer posix.close(ready_pipe[0]);

        var b: [1]u8 = undefined;
        const n = posix.read(ready_pipe[0], &b) catch 0;
        if (n == 0) {
            var buf: [256]u8 = undefined;
            var writer = std.fs.File.stderr().writer(&buf);
            try writer.interface.writeAll("Failed to start session\n");
            try writer.interface.flush();
            return;
        }

        try client(socket_path);
    }
}

fn listSessions(alloc: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;

    var dir = std.fs.cwd().openDir(SOCKET_DIR, .{ .iterate = true }) catch {
        try stdout.writeAll("No sessions found.\n");
        try stdout.flush();
        return;
    };
    defer dir.close();

    var found = false;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .unix_domain_socket or
            (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sock")))
        {
            // Check if session is actually alive
            const socket_path = try getSocketPath(alloc, entry.name[0 .. entry.name.len - 5]); // Remove .sock
            defer alloc.free(socket_path);

            if (sessionExists(socket_path)) {
                if (!found) {
                    try stdout.writeAll("Active sessions:\n");
                    found = true;
                }
                // Print session name without .sock extension
                const name = entry.name[0 .. entry.name.len - 5];
                try stdout.print("  {s}\n", .{name});
            } else {
                // Clean up stale socket
                dir.deleteFile(entry.name) catch {};
            }
        }
    }

    if (!found) {
        try stdout.writeAll("No active sessions.\n");
    }
    try stdout.flush();
}

fn killSession(session_name: []const u8) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var path_buf: [MAX_SOCKET_PATH_LEN]u8 = undefined;
    const socket_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sock", .{ SOCKET_DIR, session_name }) catch {
        try stderr.writeAll("Session name too long\n");
        try stderr.flush();
        return;
    };

    // Check if session exists
    const stat = std.fs.cwd().statFile(socket_path) catch {
        try stderr.print("Session '{s}' not found.\n", .{session_name});
        try stderr.flush();
        return;
    };
    _ = stat;

    // Remove the socket file - this will cause the server to exit
    // when it tries to accept new connections
    std.fs.cwd().deleteFile(socket_path) catch |err| {
        try stderr.print("Failed to kill session: {}\n", .{err});
        try stderr.flush();
        return;
    };

    try stdout.print("Session '{s}' killed.\n", .{session_name});
    try stdout.flush();
}
