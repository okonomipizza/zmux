const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = @import("c.zig").c;

/// User-private directory for session sockets.
/// Prefers $XDG_RUNTIME_DIR/zmux (Linux/desktop), falls back to ~/.local/share/zmux.
pub fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_RUNTIME_DIR")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0 and xdg[0] == '/') {
            return std.fmt.allocPrint(alloc, "{s}/zmux", .{xdg});
        }
    } else |_| {}

    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(alloc, "{s}/.local/share/zmux", .{home});
}

pub fn socketDirStack(buf: []u8) ![]const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        if (xdg.len > 0 and xdg[0] == '/') {
            return std.fmt.bufPrint(buf, "{s}/zmux", .{xdg});
        }
    }
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.bufPrint(buf, "{s}/.local/share/zmux", .{home});
}

pub fn socketPath(alloc: std.mem.Allocator, session_name: []const u8) ![]u8 {
    const dir = try socketDir(alloc);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}.sock", .{ dir, session_name });
}

/// Create the socket directory with owner-only permissions.
pub fn ensureSocketDir(dir: []const u8) !void {
    try std.fs.cwd().makePath(dir);
    var opened = try std.fs.cwd().openDir(dir, .{});
    defer opened.close();
    try opened.chmod(0o700);
}

/// Restrict a bound Unix socket to the owner (read/write only).
pub fn restrictSocketMode(fd: posix.fd_t) !void {
    try posix.fchmod(fd, 0o600);
}

/// Return the UID of the peer connected to a Unix domain socket.
pub fn peerUid(fd: posix.socket_t) !posix.uid_t {
    return switch (builtin.os.tag) {
        .linux => peerUidLinux(fd),
        .macos => peerUidMacos(fd),
        else => @compileError("platform not supported"),
    };
}

const UCred = extern struct {
    pid: c.pid_t,
    uid: c.uid_t,
    gid: c.gid_t,
};

fn peerUidLinux(fd: posix.socket_t) !posix.uid_t {
    const linux = std.os.linux;
    var cred: UCred = undefined;
    var len: posix.socklen_t = @sizeOf(UCred);
    try posix.getsockopt(
        fd,
        posix.SOL.SOCKET,
        linux.SO.PEERCRED,
        std.mem.asBytes(&cred),
        &len,
    );
    return cred.uid;
}

fn peerUidMacos(fd: posix.socket_t) !posix.uid_t {
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    if (getpeereid(@intCast(fd), &uid, &gid) != 0) return error.GetPeerUidFailed;
    return uid;
}

extern fn getpeereid(socket: c_int, euid: *c.uid_t, egid: *c.gid_t) c_int;
