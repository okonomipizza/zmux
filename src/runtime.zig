//! Where zmux keeps its socket, and how a server is started on demand.
//!
//! The socket lives in `$XDG_RUNTIME_DIR/zmux/`, which on a modern system is a
//! per-user directory with mode 0700 owned by the user. That matters: a unix
//! socket carries no authentication of its own, so whoever can open the path can
//! drive the sessions, and the directory permissions are the entire access
//! control. `$TMPDIR` is deliberately not the first choice, because on a shared
//! machine it is world-writable and a predictable name there would let another
//! user connect first.
//!
//! The server is started on demand, so a client that finds no socket does not
//! fail; it starts one and waits for the socket to appear.

const std = @import("std");
const linux = std.os.linux;
const socket = @import("socket.zig");

pub const Error = error{
    /// No usable runtime directory exists.
    NoRuntimeDir,
    /// The socket path does not fit in a `sockaddr_un`.
    PathTooLong,
    /// The server could not be started or did not come up.
    ServerUnavailable,
};

/// The directory holding the socket and the server's log.
///
/// `$XDG_RUNTIME_DIR` is preferred, then `$TMPDIR`, then `/tmp`. The last two are
/// only fallbacks for a machine that does not set a runtime directory, and in
/// that case the per-user subdirectory is what keeps other users out.
pub fn runtimeDir(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return buildPath(buffer, &.{ dir, "zmux" });
    }
    if (environ.getPosix("TMPDIR")) |dir| {
        if (dir.len > 0) return buildPath(buffer, &.{ dir, "zmux" });
    }
    return buildPath(buffer, &.{ "/tmp", "zmux" });
}

/// The socket path, inside the runtime directory.
pub fn socketPath(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try runtimeDir(environ, &dir_buffer);
    return buildPath(buffer, &.{ dir, "default.sock" });
}

fn buildPath(buffer: []u8, parts: []const []const u8) ![]const u8 {
    // `std.io.fixedBufferStream` does not exist in Zig 0.16; the writer is
    // obtained from `std.Io.Writer.fixed` and the bytes written so far are read
    // back with `buffered`.
    var writer = std.Io.Writer.fixed(buffer);
    for (parts, 0..) |part, index| {
        if (index != 0) writer.writeByte('/') catch return Error.PathTooLong;
        writer.writeAll(part) catch return Error.PathTooLong;
    }
    const path = writer.buffered();
    if (path.len >= socket.max_path) return Error.PathTooLong;
    return path;
}

/// Create the runtime directory if it is missing.
///
/// Returns true when this call created it, which is how the caller learns
/// whether it is the first zmux process on the machine.
pub fn ensureRuntimeDir(path: []const u8) !bool {
    // The directory is created with 0700 explicitly rather than relying on the
    // umask, because on a fallback path like /tmp the mode is what keeps other
    // users out.
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buffer, "{s}", .{path}) catch return Error.PathTooLong;

    const result = linux.mkdir(path_z.ptr, 0o700);
    switch (linux.errno(result)) {
        .SUCCESS => return true,
        .EXIST => return false,
        else => return Error.ServerUnavailable,
    }
}

/// Whether a server is listening at `path`, by trying to connect.
///
/// A stale socket file left by a killed server accepts no connections, and
/// checking by connecting is what distinguishes it from a live one without
/// needing a lock file or a pidfile.
pub fn serverIsRunning(path: []const u8) bool {
    var connection = socket.Connection.connect(path) catch return false;
    connection.deinit();
    return true;
}

/// Build a synthetic environment for a test.
///
/// `Environ` has no constructor taking strings, and the real one is a slice of
/// the process's own environment, so the block is assembled here the same way
/// `createPosixBlock` does: one allocated, sentinel-terminated string per entry.
fn testEnviron(gpa: std.mem.Allocator, entries: []const []const u8) !std.process.Environ {
    const envp = try gpa.allocSentinel(?[*:0]u8, entries.len, null);
    for (entries, 0..) |entry, index| {
        envp[index] = (try gpa.dupeZ(u8, entry)).ptr;
    }
    return .{ .block = .{ .slice = @ptrCast(envp) } };
}

fn freeTestEnviron(gpa: std.mem.Allocator, environ: std.process.Environ) void {
    const envp: [*:null]?[*:0]const u8 = @constCast(environ.block.slice.ptr);
    var index: usize = 0;
    while (envp[index]) |entry| : (index += 1) gpa.free(std.mem.span(entry));
    gpa.free(environ.block.slice);
}

test "the socket path is preferred under the runtime directory" {
    const gpa = std.testing.allocator;
    const environ = try testEnviron(gpa, &.{
        "XDG_RUNTIME_DIR=/run/user/1000",
        "TMPDIR=/tmp",
    });
    defer freeTestEnviron(gpa, environ);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try socketPath(environ, &buffer);
    try std.testing.expectEqualStrings("/run/user/1000/zmux/default.sock", path);

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try runtimeDir(environ, &dir_buffer);
    try std.testing.expectEqualStrings("/run/user/1000/zmux", dir);
}

test "the temporary directory is the fallback" {
    const gpa = std.testing.allocator;
    const environ = try testEnviron(gpa, &.{"TMPDIR=/var/tmp"});
    defer freeTestEnviron(gpa, environ);

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try runtimeDir(environ, &dir_buffer);
    try std.testing.expectEqualStrings("/var/tmp/zmux", dir);
}

test "an overlong socket path is rejected before it is truncated" {
    const gpa = std.testing.allocator;
    const environ = try testEnviron(gpa, &.{"XDG_RUNTIME_DIR=" ++ ("a" ** 200)});
    defer freeTestEnviron(gpa, environ);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(Error.PathTooLong, socketPath(environ, &buffer));
}
