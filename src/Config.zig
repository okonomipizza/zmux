const std = @import("std");
const jsonc = @import("jsonc");

pub const Config = @This();

active_border_color: Color = .green,
inactive_border_color: Color = .bright_black,
copy_cursor_fg: Color = .black,
copy_cursor_bg: Color = .yellow,
status_bg: Color = .bright_black,
status_fg: Color = .white,
active_workspace_bg: Color = .green,
active_workspace_fg: Color = .black,
mode_label_bg: Color = .yellow,
mode_label_fg: Color = .black,

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn toFgAnsiSeq(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }

    pub fn toBgAnsiSeq(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[40m",
            .red => "\x1b[41m",
            .green => "\x1b[42m",
            .yellow => "\x1b[43m",
            .blue => "\x1b[44m",
            .magenta => "\x1b[45m",
            .cyan => "\x1b[46m",
            .white => "\x1b[47m",
            .bright_black => "\x1b[100m",
            .bright_red => "\x1b[101m",
            .bright_green => "\x1b[102m",
            .bright_yellow => "\x1b[103m",
            .bright_blue => "\x1b[104m",
            .bright_magenta => "\x1b[105m",
            .bright_cyan => "\x1b[106m",
            .bright_white => "\x1b[107m",
        };
    }

    /// Kept for backward compatibility with border rendering
    pub fn toAnsiSeq(self: Color) []const u8 {
        return self.toFgAnsiSeq();
    }

    pub fn fromString(s: []const u8) ?Color {
        const map = std.StaticStringMap(Color).initComptime(.{
            .{ "black", .black },
            .{ "red", .red },
            .{ "green", .green },
            .{ "yellow", .yellow },
            .{ "blue", .blue },
            .{ "magenta", .magenta },
            .{ "cyan", .cyan },
            .{ "white", .white },
            .{ "bright_black", .bright_black },
            .{ "bright_red", .bright_red },
            .{ "bright_green", .bright_green },
            .{ "bright_yellow", .bright_yellow },
            .{ "bright_blue", .bright_blue },
            .{ "bright_magenta", .bright_magenta },
            .{ "bright_cyan", .bright_cyan },
            .{ "bright_white", .bright_white },
        });
        return map.get(s);
    }
};

pub fn init() Config {
    return .{};
}

pub fn load(allocator: std.mem.Allocator) Config {
    const home = std.posix.getenv("HOME") orelse return .{};
    const path = std.fmt.allocPrint(allocator, "{s}/.config/zmux/zmux.jsonc", .{home}) catch return .{};
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return .{};
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return .{};
    defer allocator.free(content);

    return parseContent(allocator, content);
}

fn parseContent(allocator: std.mem.Allocator, content: []const u8) Config {
    var jc = jsonc.Jsonc.init(content);
    defer jc.deinit();

    const parsed = jc.parse(std.json.Value, allocator, .{}) catch return .{};
    defer parsed.deinit();

    var config = Config{};

    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.type == Color) {
            if (jsonc.Jsonc.getValueByPath(parsed.value, &.{field.name}) catch null) |val| {
                if (val == .string) {
                    if (Color.fromString(val.string)) |color| {
                        @field(config, field.name) = color;
                    }
                }
            }
        }
    }

    return config;
}

test "parseContent with valid color" {
    const content =
        \\{
        \\  // active border color
        \\  "active_border_color": "cyan"
        \\}
    ;
    const config = parseContent(std.testing.allocator, content);
    try std.testing.expectEqual(Color.cyan, config.active_border_color);
}

test "parseContent with invalid color falls back to default" {
    const content =
        \\{
        \\  "active_border_color": "rainbow"
        \\}
    ;
    const config = parseContent(std.testing.allocator, content);
    try std.testing.expectEqual(Color.green, config.active_border_color);
}

test "parseContent with missing key falls back to default" {
    const content =
        \\{
        \\  "other_key": "value"
        \\}
    ;
    const config = parseContent(std.testing.allocator, content);
    try std.testing.expectEqual(Color.green, config.active_border_color);
}

test "parseContent with multiple color settings" {
    const content =
        \\{
        \\  "active_border_color": "cyan",
        \\  "inactive_border_color": "white",
        \\  "status_bg": "blue",
        \\  "mode_label_bg": "red"
        \\}
    ;
    const config = parseContent(std.testing.allocator, content);
    try std.testing.expectEqual(Color.cyan, config.active_border_color);
    try std.testing.expectEqual(Color.white, config.inactive_border_color);
    try std.testing.expectEqual(Color.blue, config.status_bg);
    try std.testing.expectEqual(Color.red, config.mode_label_bg);
    // Defaults for unspecified
    try std.testing.expectEqual(Color.black, config.copy_cursor_fg);
    try std.testing.expectEqual(Color.yellow, config.copy_cursor_bg);
}

test "Color.toFgAnsiSeq" {
    try std.testing.expectEqualStrings("\x1b[31m", Color.red.toFgAnsiSeq());
    try std.testing.expectEqualStrings("\x1b[92m", Color.bright_green.toFgAnsiSeq());
}

test "Color.toBgAnsiSeq" {
    try std.testing.expectEqualStrings("\x1b[41m", Color.red.toBgAnsiSeq());
    try std.testing.expectEqualStrings("\x1b[102m", Color.bright_green.toBgAnsiSeq());
}
