const std = @import("std");

pub fn main() !void {
    std.debug.print("zmux 0.1.0\n", .{});
}

test "smoke" {
    try std.testing.expect(true);
}
