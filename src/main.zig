const std = @import("std");
const c = @import("c.zig").c;
const clap = @import("clap");

const Server = @import("Server.zig");
const client = @import("client.zig").client;

/// zmux app version
const version = "0.0.0";

const SOCKET_PATH = "/tmp/zmux/default.sock";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-v, --version  Output version information and exit.
        \\-s, --server   Start server
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = alloc,
    });
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(std.fs.File.stderr(), clap.Help, &params, .{});
    }

    if (res.args.version != 0) {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll("zmux " ++ version ++ "\n");
        return;
    }

    var original_termios: c.termios = undefined;

    if (res.args.server != 0) {
        _ = c.tcgetattr(c.STDIN_FILENO, &original_termios);
        try Server.server(alloc, SOCKET_PATH, original_termios);
        return;
    }

    try client(alloc, SOCKET_PATH);
}
