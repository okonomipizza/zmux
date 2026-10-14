//! Configuration, read from a JSON file under the XDG config directory.
//!
//! The file is a flat map of dotted names to strings. Flat rather than nested because every value is
//! either a single character or a colour, and nesting would need a structure and a parser to match
//! it for no gain in what a user can say. A missing file, an unreadable one, or a name this build does
//! not know all fall back to the defaults below, so a configuration is never a reason for zmux not
//! to start.
//!
//! The defaults are written out in full the first time zmux runs, so that the file a user opens
//! shows every knob there is rather than an empty pair of braces they have to look up.

const std = @import("std");
const linux = std.os.linux;

/// The prefix commands zmux recognises. One byte each, because they are keys.
pub const Keybinds = struct {
    split_horizontal: u8 = '\\',
    split_vertical: u8 = '-',
    close: u8 = 'q',
    float_toggle: u8 = 'f',
    float_focused: u8 = 'F',
    dock: u8 = 'd',
    focus_previous: u8 = 'h',
    focus_previous_alt: u8 = 'k',
    focus_next: u8 = 'l',
    focus_next_alt: u8 = 'j',
    move_next: u8 = '>',
    move_previous: u8 = '<',
    rotate: u8 = 'o',
    sessions: u8 = 'w',
    scroll: u8 = 'x',
};

/// Where the border and the status line get their colours.
pub const Colours = struct {
    /// The frame around the pane being typed into.
    border_active_fg: Rgb = .{ .r = 0x7c, .g = 0xa8, .b = 0x6c },
    /// The frame around every other pane, or null for the terminal's own foreground.
    ///
    /// Null by default so that a pane without focus is drawn the way the terminal was configured,
    /// which is one fewer colour to disagree with the user's theme.
    border_inactive_fg: ?Rgb = null,
    /// The status line's background and text.
    ///
    /// A desaturated blue-grey rather than black, because pure black makes the border's green read as
    /// the usual green-on-black rather than as part of the same palette, and it leaves the whole
    /// scheme looking like two schemes.
    status_bg: Rgb = .{ .r = 0x2e, .g = 0x34, .b = 0x40 },
    status_fg: Rgb = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 },
};

pub const Config = struct {
    keybinds: Keybinds = .{},
    colours: Colours = .{},
};

/// A colour, as the terminal should draw it.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// The three components, for the callers that write an escape sequence.
    ///
    /// A method rather than a cast: a struct of three bytes is not a three-byte array in Zig, and the
    /// escape that consumes it wants the array.
    pub fn toArray(self: Rgb) [3]u8 {
        return .{ self.r, self.g, self.b };
    }
};
/// The one failure of this module that a caller may want to tell apart from the others.
///
/// A malformed file and an unwritable one are not errors here: both fall back to the defaults, which
/// is the same thing a user who has not configured anything gets. Only a path that does not fit the
/// caller's buffer has to be reported, because there is nothing sensible to do instead.
pub const Error = error{
    PathTooLong,
    /// The configuration file does not exist, which is the ordinary first-run state.
    ///
    /// Distinct from the other read failures because it is the only one nobody needs to be told
    /// about. The raw `open` reports `ENOENT` and a permission denial the same way, so the errno is
    /// decoded at the point where it is still available.
    FileAbsent,
};

/// Every setting, with the name it has in the file.
///
/// One table rather than something derived, because this is also what the file that is written on
/// first use is generated from. A setting that exists in the structure but not here would be
/// invisible to a user, and one that is here and not there would not compile.
pub const entries = [_]Entry{
    .{ .name = "keybind.split_horizontal", .key = '\\' },
    .{ .name = "keybind.split_vertical", .key = '-' },
    .{ .name = "keybind.close", .key = 'q' },
    .{ .name = "keybind.float_toggle", .key = 'f' },
    .{ .name = "keybind.float_focused", .key = 'F' },
    .{ .name = "keybind.dock", .key = 'd' },
    .{ .name = "keybind.focus_previous", .key = 'h' },
    .{ .name = "keybind.focus_previous_alt", .key = 'k' },
    .{ .name = "keybind.focus_next", .key = 'l' },
    .{ .name = "keybind.focus_next_alt", .key = 'j' },
    .{ .name = "keybind.move_next", .key = '>' },
    .{ .name = "keybind.move_previous", .key = '<' },
    .{ .name = "keybind.rotate", .key = 'o' },
    .{ .name = "keybind.sessions", .key = 'w' },
    .{ .name = "keybind.scroll", .key = 'x' },
    .{ .name = "border.active.fg", .colour = .{ .r = 0x7c, .g = 0xa8, .b = 0x6c } },
    .{ .name = "border.inactive.fg", .colour = null },
    .{ .name = "status.bg", .colour = .{ .r = 0x2e, .g = 0x34, .b = 0x40 } },
    .{ .name = "status.fg", .colour = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 } },
};

/// One row of the table above: a name, and its default as a key or a colour.
///
/// A union rather than a pointer into the structures, so that the table can be written out without
/// anything having to reflect over them, and so that the defaults appear in exactly one place.
pub const Entry = struct {
    name: []const u8,
    /// The default, as the text that would appear in the file. Null means no colour, which is
    /// written as null rather than as a made-up one.
    key: ?u8 = null,
    colour: ?Rgb = null,

    pub fn format(self: Entry, buffer: []u8) ![]const u8 {
        if (self.key) |key| {
            // A key that is a quote or a backslash has to be escaped, or the string it sits in ends
            // early. That is not a cosmetic problem: `"a": "\"` is not JSON, so the whole file fails
            // to parse and every setting in it reverts to its default -- the user's colours and
            // their other bindings along with the one bad line. Backslash is a prefix command here,
            // so this is not hypothetical.
            return switch (key) {
                '"' => "\"\\\"\"",
                '\\' => "\"\\\\\"",
                else => std.fmt.bufPrint(buffer, "\"{c}\"", .{key}),
            };
        }
        if (self.colour) |colour| {
            return std.fmt.bufPrint(buffer, "\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
                colour.r, colour.g, colour.b,
            });
        }
        return "\"null\"";
    }
};

/// Why the configuration is not entirely the user's own.
///
/// The fallback to defaults is deliberate and stays: a file that cannot be understood must not stop
/// zmux from starting, and anything it does say is still applied. What was wrong was doing it
/// silently. A JSON error makes *every* setting revert at once, so a user who mistyped one line lost
/// their colours and their other bindings with no indication of which line it was or that anything
/// had happened. A file that is absent is not worth a word; one that exists and was not used is.
pub const Problem = union(enum) {
    /// There is no configuration file, which is the ordinary first-run state.
    absent,
    /// The file is there but its contents could not be decoded as JSON.
    malformed,
    /// The file could not be read at all: permissions, or a path that did not fit.
    unreadable,
};

/// A configuration, and what had to be assumed to get it.
pub const Loaded = struct {
    config: Config,
    problem: Problem = .absent,
};

/// Read the configuration, falling back to the defaults wherever it says nothing.
///
/// A file that cannot be read is not an error: the defaults are what a user who has not configured
/// anything gets, and starting without a configuration is better than refusing to start. The reason
/// is returned rather than discarded so that the caller can say what happened.
pub fn load(gpa: std.mem.Allocator, environ: std.process.Environ) Loaded {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(environ, &path_buffer) catch {
        return .{ .config = .{}, .problem = .unreadable };
    };
    const text = readFile(gpa, path) catch |err| {
        // A file that is not there is the normal case and says nothing: on a machine where zmux has
        // never been configured there is simply no file. Anything else -- a permission problem, a
        // path that did not fit, a file far too large to be a configuration -- is a configuration the
        // user wrote that zmux is not honouring, and that is worth a word.
        const problem: Problem = if (err == error.FileAbsent) .absent else .unreadable;
        return .{ .config = .{}, .problem = problem };
    };
    defer gpa.free(text);
    // Parsed once, with both answers taken from the same attempt. Asking a second time to find out
    // whether the first one worked would decode the whole document twice on every attach.
    var config = Config{};
    const problem = parseInto(&config, gpa, text);
    return .{ .config = config, .problem = problem };
}

/// Apply a configuration file's contents over the defaults, reporting whether it decoded at all.
///
/// `parse` is deliberately lenient per setting, so most outcomes are not worth reporting: a file that
/// decodes but names nothing this build knows is fine, and so is a partial one. Only a document that
/// does not parse at all costs the user every setting they wrote, and that is the case the caller
/// warns about.
fn parseInto(config: *Config, gpa: std.mem.Allocator, text: []const u8) Problem {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return .malformed;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return .absent,
    };

    var it = object.iterator();
    while (it.next()) |pair| {
        const value = switch (pair.value_ptr.*) {
            .string => |string| string,
            else => continue,
        };
        apply(config, pair.key_ptr.*, value);
    }

    return .absent;
}

/// Read a whole file, or report why not.
///
/// The raw syscalls are used rather than a `std.fs` helper because Zig 0.16 moved file operations to
/// `std.Io.Dir`, which wants an `Io` this module has no other use for. `socket.zig` removes a file
/// the same way and for the same reason.
fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});

    const opened = linux.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    switch (linux.errno(opened)) {
        .SUCCESS => {},
        .NOENT => return Error.FileAbsent,
        else => return error.OpenFailed,
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const read = linux.read(fd, &chunk, chunk.len);
        const err = linux.errno(read);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.ReadFailed;
        if (read == 0) break;
        // A configuration is a page of text; anything larger is not one, and reading without a bound
        // would be a way for a file to exhaust the process.
        if (text.items.len + read > 1 << 20) return error.TooLarge;
        try text.appendSlice(gpa, chunk[0..read]);
    }
    return text.toOwnedSlice(gpa);
}

/// Apply a configuration file's contents over the defaults.
///
/// Anything the file does not mention keeps its default, which is what makes a partial file usable.
/// Anything that cannot be understood is skipped for the same reason: one mistyped line should not
/// cost the user the rest of their settings.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) Config {
    var config = Config{};
    _ = parseInto(&config, gpa, text);
    return config;
}

/// Set one named setting, if the name is one this build knows.
fn apply(config: *Config, name: []const u8, value: []const u8) void {
    // Keys first: they are one character, and a name that matched a colour would have to be a
    // mistyped one, since no name is both.
    inline for (@typeInfo(Keybinds).@"struct".fields) |field| {
        const full = "keybind." ++ field.name;
        if (std.mem.eql(u8, name, full)) {
            if (value.len == 1) {
                @field(config.keybinds, field.name) = value[0];
            }
            return;
        }
    }

    if (std.mem.eql(u8, name, "border.active.fg")) {
        if (parseColour(value)) |colour| config.colours.border_active_fg = colour;
        return;
    }
    if (std.mem.eql(u8, name, "border.inactive.fg")) {
        // A null or an empty string means "no colour of its own", which is not the same as a black
        // one: the pane then keeps whatever the terminal was configured with.
        if (std.mem.eql(u8, value, "null") or value.len == 0) {
            config.colours.border_inactive_fg = null;
        } else if (parseColour(value)) |colour| {
            config.colours.border_inactive_fg = colour;
        }
        return;
    }
    if (std.mem.eql(u8, name, "status.bg")) {
        if (parseColour(value)) |colour| config.colours.status_bg = colour;
        return;
    }
    if (std.mem.eql(u8, name, "status.fg")) {
        if (parseColour(value)) |colour| config.colours.status_fg = colour;
        return;
    }
}

/// Parse `#rrggbb`, with or without the hash.
///
/// Only the six-digit form: a three-digit shorthand would make `#abc` ambiguous against a name, and
/// there are no colour names to be ambiguous with.
pub fn parseColour(text: []const u8) ?Rgb {
    const digits = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (digits.len != 6) return null;

    var bytes: [3]u8 = undefined;
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        bytes[index] = std.fmt.parseInt(u8, digits[index * 2 .. index * 2 + 2], 16) catch return null;
    }
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2] };
}

/// The path of the configuration file, under the XDG config directory.
///
/// `$XDG_CONFIG_HOME` is preferred; the specification says to fall back to `$HOME/.config` when it is
/// unset or empty. A machine with neither is given no path at all, and the caller uses the defaults.
pub fn configPath(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |dir| {
        if (dir.len > 0) return buildPath(buffer, &.{ dir, "zmux", "config.json" });
    }
    if (environ.getPosix("HOME")) |home| {
        if (home.len > 0) return buildPath(buffer, &.{ home, ".config", "zmux", "config.json" });
    }
    return Error.PathTooLong;
}

fn buildPath(buffer: []u8, parts: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (parts, 0..) |part, index| {
        if (index != 0) writer.writeByte('/') catch return Error.PathTooLong;
        writer.writeAll(part) catch return Error.PathTooLong;
    }
    return writer.buffered();
}

/// Write the configuration file with every setting at its default.
///
/// Written the first time zmux runs, so that the file a user opens shows every knob rather than an
/// empty object they have to look up. An existing file is left alone: it is the user's, and
/// overwriting it would discard what they set.
///
/// Returns whether a file was written, which is what the caller uses to decide whether to say so.
pub fn writeDefaultsIfAbsent(gpa: std.mem.Allocator, environ: std.process.Environ) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(environ, &path_buffer) catch return false;

    // The directory, and every directory above it that is missing. `mkdir` creates one level only, so
    // creating `~/.config/zmux` would silently fail when `~/.config` is not there, and the open below
    // would fail with it: the configuration would never be written and nothing would say so. Each
    // prefix is tried in turn, and a failure is ignored because the likeliest reason for one is that
    // it is already there.
    if (std.fs.path.dirname(path)) |dir| {
        var prefix: usize = 1;
        while (prefix <= dir.len) : (prefix += 1) {
            if (prefix != dir.len and dir[prefix] != '/') continue;
            var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const dir_z = std.fmt.bufPrintZ(&dir_buffer, "{s}", .{dir[0..prefix]}) catch return false;
            _ = linux.mkdir(dir_z.ptr, 0o755);
        }
    }

    // `O_EXCL` is what makes this "if absent": an existing file fails the open rather than being
    // truncated, which is the difference between seeding a configuration and destroying one.
    var path_z_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buffer, "{s}", .{path}) catch return false;

    const opened = linux.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
    }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return false;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);

    return writeDefaults(gpa, fd);
}

/// The text of the default configuration, written to an open descriptor.
fn writeDefaults(gpa: std.mem.Allocator, fd: i32) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    out.appendSlice(gpa, "{\n") catch return false;
    out.appendSlice(gpa, "  \"//\": \"zmux configuration. Every setting is listed here at its default.\",\n") catch return false;
    out.appendSlice(gpa, "  \"//1\": \"Delete a line to keep the default, or change its value. A\",\n") catch return false;
    out.appendSlice(gpa, "  \"//2\": \"setting that is absent falls back to the default as well.\",\n") catch return false;
    out.appendSlice(gpa, "  \"//3\": \"Colours are #rrggbb. A key is a single character.\",\n") catch return false;

    for (entries, 0..) |entry, index| {
        var value_buffer: [32]u8 = undefined;
        const value = entry.format(&value_buffer) catch return false;
        var line: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "  \"{s}\": {s}", .{ entry.name, value }) catch return false;
        out.appendSlice(gpa, text) catch return false;
        if (index + 1 < entries.len) out.append(gpa, ',') catch return false;
        out.append(gpa, '\n') catch return false;
    }

    out.appendSlice(gpa, "}\n") catch return false;

    var written: usize = 0;
    while (written < out.items.len) {
        const n = linux.write(fd, out.items[written..].ptr, out.items.len - written);
        const err = linux.errno(n);
        if (err == .INTR) continue;
        if (err != .SUCCESS or n == 0) return false;
        written += n;
    }
    return true;
}

test "a missing file leaves every default in place" {
    var config = Config{};
    apply(&config, "keybind.close", "x");
    try std.testing.expectEqual(@as(u8, 'x'), config.keybinds.close);
    // Untouched settings keep their defaults. The default is read from the structure rather than
    // written here, so that changing one does not leave this asserting the old value: what is being
    // tested is that a setting nobody named is untouched, not what any particular default is.
    const defaults = Config{};
    try std.testing.expectEqual(defaults.keybinds.split_horizontal, config.keybinds.split_horizontal);
    try std.testing.expect(config.colours.border_active_fg.eql(.{ .r = 0x7c, .g = 0xa8, .b = 0x6c }));
}

test "an empty object is every default" {
    const config = parse(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(u8, 'q'), config.keybinds.close);
    try std.testing.expect(config.colours.status_bg.eql(.{ .r = 0x2e, .g = 0x34, .b = 0x40 }));
}

test "a partial file changes only what it names" {
    const config = parse(std.testing.allocator,
        \\{ "keybind.close": "Q", "status.fg": "#ffffff" }
    );
    try std.testing.expectEqual(@as(u8, 'Q'), config.keybinds.close);
    try std.testing.expect(config.colours.status_fg.eql(.{ .r = 0xff, .g = 0xff, .b = 0xff }));
    // Everything else is still the default, read from the structure rather than restated here.
    const defaults = Config{};
    try std.testing.expectEqual(defaults.keybinds.split_horizontal, config.keybinds.split_horizontal);
    try std.testing.expect(config.colours.status_bg.eql(.{ .r = 0x2e, .g = 0x34, .b = 0x40 }));
}

test "a malformed file is the defaults rather than a failure" {
    // A configuration that cannot be parsed must not be a reason for zmux not to start.
    const config = parse(std.testing.allocator, "{ this is not json");
    try std.testing.expectEqual(@as(u8, 'q'), config.keybinds.close);
}

test "only a document that does not parse at all is reported as malformed" {
    // The warning exists for the case where the user loses *every* setting at once, which is what a
    // JSON error costs. The lenient outcomes must stay quiet, or the warning becomes noise that a
    // user learns to ignore: a file that parses but names nothing this build knows still applies
    // everything it can, and a partial file is a supported way to write one.
    const gpa = std.testing.allocator;

    // The verdict and the settings come from one parse, so a case is described by calling both and
    // checking they agree. `verdict` is what the caller would warn about.
    const verdict = struct {
        fn of(text: []const u8) Problem {
            var config = Config{};
            return parseInto(&config, gpa, text);
        }
    }.of;

    try std.testing.expectEqual(Problem.malformed, verdict("{ this is not json"));
    try std.testing.expectEqual(Problem.malformed, verdict(""));

    try std.testing.expectEqual(Problem.absent, verdict("{}"));
    try std.testing.expectEqual(Problem.absent, verdict("{\"nonsense.key\": \"x\"}"));
    try std.testing.expectEqual(Problem.absent, verdict("{\"keybind.close\": \"Q\"}"));

    // A document that is valid JSON but not an object is applied as nothing, which the per-setting
    // leniency already covers. It parses, so it is not the all-settings-lost case.
    try std.testing.expectEqual(Problem.absent, verdict("[1, 2, 3]"));

    // The two must agree: anything reported as malformed really does lose every setting, and
    // anything reported as fine really does keep the one it names.
    const broken = "{\"keybind.close\": \"Q\"";
    try std.testing.expectEqual(Problem.malformed, verdict(broken));
    try std.testing.expectEqual(@as(u8, 'q'), parse(gpa, broken).keybinds.close);

    const good = "{\"keybind.close\": \"Q\"}";
    try std.testing.expectEqual(Problem.absent, verdict(good));
    try std.testing.expectEqual(@as(u8, 'Q'), parse(gpa, good).keybinds.close);
}

test "an absent file is told apart from one that could not be read" {
    // This distinction is the whole reason the warning is worth having. On a machine where zmux has
    // never been configured there is no file, and saying so every time would be noise; a file that is
    // there and was not read is a configuration the user wrote and zmux is ignoring.
    //
    // A file that exists is created here rather than with a `std.fs` helper, because Zig 0.16 moved
    // those to `std.Io.Dir`, which wants an `Io`. The raw syscalls are what this module uses
    // throughout, for the same reason.
    const gpa = std.testing.allocator;

    var name_buffer: [64]u8 = undefined;
    const file_name = try std.fmt.bufPrintZ(&name_buffer, "/tmp/zmux-config-test-{d}.json", .{
        linux.getpid(),
    });

    // Nothing has been created at this name, so it is absent.
    _ = linux.unlink(file_name.ptr);
    try std.testing.expectError(Error.FileAbsent, readFile(gpa, file_name));

    // Create it with contents, and the same call now reads them. That shows the error above was
    // about absence rather than about the read path being broken.
    const contents = "{\"keybind.close\": \"Q\"}";
    const created = linux.open(file_name.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(created));
    const fd: i32 = @intCast(created);
    defer {
        _ = linux.close(fd);
        _ = linux.unlink(file_name.ptr);
    }
    // The length comes from the literal rather than being written out, so that editing the text
    // cannot leave the two disagreeing: a short write would make the read below fail for a reason
    // that has nothing to do with what this test is about.
    try std.testing.expectEqual(contents.len, linux.write(fd, contents.ptr, contents.len));

    const text = try readFile(gpa, file_name);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(contents, text);
}

test "a setting with a value of the wrong shape is skipped, and the rest applies" {
    const config = parse(std.testing.allocator,
        \\{ "keybind.close": "too long", "keybind.rotate": "r", "status.bg": "not-a-colour" }
    );
    // A key that is not a single character is refused.
    try std.testing.expectEqual(@as(u8, 'q'), config.keybinds.close);
    // A colour that does not parse leaves the default rather than becoming black.
    try std.testing.expect(config.colours.status_bg.eql(.{ .r = 0x2e, .g = 0x34, .b = 0x40 }));
    // And the well-formed settings around them still apply.
    try std.testing.expectEqual(@as(u8, 'r'), config.keybinds.rotate);
}

test "colours parse with and without the hash, and nothing else does" {
    try std.testing.expect(parseColour("#7ca86c").?.eql(.{ .r = 0x7c, .g = 0xa8, .b = 0x6c }));
    try std.testing.expect(parseColour("7ca86c").?.eql(.{ .r = 0x7c, .g = 0xa8, .b = 0x6c }));
    // Case does not matter for hex digits.
    try std.testing.expect(parseColour("#7CA86C").?.eql(.{ .r = 0x7c, .g = 0xa8, .b = 0x6c }));

    // The three-digit shorthand is refused rather than guessed at.
    try std.testing.expectEqual(@as(?Rgb, null), parseColour("#abc"));
    try std.testing.expectEqual(@as(?Rgb, null), parseColour("#12345"));
    try std.testing.expectEqual(@as(?Rgb, null), parseColour("#1234567"));
    try std.testing.expectEqual(@as(?Rgb, null), parseColour(""));
    try std.testing.expectEqual(@as(?Rgb, null), parseColour("#gggggg"));
}

test "the written file parses, and says what it was generated from" {
    // Two things are checked, and the second is the one that was missing. That the object built from
    // the table parses at all, and that it does not merely parse to the defaults.
    //
    // Comparing the result against the defaults is not enough on its own: a file that fails to parse
    // *becomes* the defaults, so that comparison passes when the file is unreadable. Which is how an
    // unescaped backslash went unnoticed -- the key was written as `"\`, the file stopped being JSON,
    // and a test comparing against the defaults agreed with it.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (entries, 0..) |entry, index| {
        var value_buffer: [64]u8 = undefined;
        const value = try entry.format(&value_buffer);
        try text.print(std.testing.allocator, "\"{s}\": {s}", .{ entry.name, value });
        if (index + 1 < entries.len) try text.appendSlice(std.testing.allocator, ",");
    }

    // The file itself, without the comments the real writer adds, so this is exactly what a user
    // would be editing.
    const object = try std.fmt.allocPrint(std.testing.allocator, "{{{s}}}", .{text.items});
    defer std.testing.allocator.free(object);

    // It parses to something that is not the fallback. `parse` returns the defaults both for a valid
    // file of defaults and for a broken one, so the two are told apart by a file that must differ.
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, object, .{}) catch {
        std.debug.print("the generated configuration is not valid JSON:\n{s}\n", .{object});
        return error.GeneratedFileIsMalformed;
    };
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(entries.len, parsed.value.object.count());

    // And every value in it is the one the table holds, read back through `apply` rather than by
    // comparing the whole structure, so a name the writer wrote wrongly shows up as a setting that
    // did not change.
    const config = parse(std.testing.allocator, object);
    for (entries) |entry| {
        if (entry.key) |key| {
            const got = keybindField(&config.keybinds, entry.name) orelse {
                std.debug.print("{s} did not survive the round trip\n", .{entry.name});
                return error.SettingLost;
            };
            if (got != key) {
                std.debug.print("{s} was written as '{c}' and read back as '{c}'\n", .{
                    entry.name, key, got,
                });
                return error.SettingLost;
            }
            continue;
        }
        // The colour entries. The one whose default is null is written as the string "null", which
        // `apply` reads as "no colour". So for that one it is the absence that has to survive, and a
        // colour coming back instead would mean the frame was being drawn in one the user never asked
        // for.
        if (colourField(&config.colours, entry.name)) |got| {
            if (entry.colour) |expected| {
                if (!got.eql(expected)) {
                    std.debug.print("{s} did not survive the round trip\n", .{entry.name});
                    return error.SettingLost;
                }
            } else {
                std.debug.print("{s} has no default but came back as a colour\n", .{entry.name});
                return error.SettingLost;
            }
        } else if (entry.colour != null) {
            std.debug.print("{s} did not survive the round trip\n", .{entry.name});
            return error.SettingLost;
        }
    }
}

test "a key that needs escaping is written escaped" {
    // A backslash or a quote in a key has to be escaped, or the string it sits in ends early. The
    // consequence is not cosmetic: `"k": "\"` is not JSON, so the whole file fails to parse and every
    // setting reverts to its default. Backslash is a prefix command, so this is not hypothetical.
    var buffer: [64]u8 = undefined;

    const backslash = try (Entry{ .name = "k", .key = '\\' }).format(&buffer);
    try std.testing.expectEqualStrings("\"\\\\\"", backslash);

    var quote_buffer: [64]u8 = undefined;
    const quote = try (Entry{ .name = "k", .key = '"' }).format(&quote_buffer);
    try std.testing.expectEqualStrings("\"\\\"\"", quote);

    // And a key that needs no escaping is unchanged.
    var plain_buffer: [64]u8 = undefined;
    const plain = try (Entry{ .name = "k", .key = 'q' }).format(&plain_buffer);
    try std.testing.expectEqualStrings("\"q\"", plain);

    // The escaped forms are valid JSON, which is the point of escaping them.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"k\": \"\\\\\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\\", parsed.value.object.get("k").?.string);
}

test "every entry in the table is a name this build acts on" {
    // A setting that exists in the structure but not in the table would be invisible to a user: it
    // would not appear in the file written on first use, and editing it would do nothing.
    //
    // More importantly the other direction: a name in the table that `apply` does not recognise
    // would be advertised in the file and silently ignored when set. That is invisible without this
    // test, because the value falls back to the default and the round trip below still passes. It was
    // found by renaming `status.bg` to `status.background` and watching nothing fail.
    //
    // The check is by behaviour rather than by reading the table: each name is given a value that
    // differs from its default, applied, and the result compared. A name `apply` does not know leaves
    // the default standing, which is what this looks for.
    for (entries) |entry| {
        var config = Config{};

        if (entry.key) |default| {
            // A key other than the default, and one that is not a default anywhere in the table.
            const different: u8 = if (default == 'Z') 'Y' else 'Z';
            apply(&config, entry.name, &.{different});
            const got = keybindField(&config.keybinds, entry.name) orelse {
                std.debug.print("{s} is not a keybind this build acts on\n", .{entry.name});
                return error.UnknownEntry;
            };
            if (got != different) {
                std.debug.print("{s} was set to '{c}' but reads back as '{c}'\n", .{
                    entry.name, different, got,
                });
                return error.SettingIgnored;
            }
            continue;
        }

        // A colour. Setting one must produce that colour: a name `apply` does not know would leave
        // the default standing, which is what this looks for.
        const probe = "#010203";
        apply(&config, entry.name, probe);
        const got = colourField(&config.colours, entry.name) orelse {
            std.debug.print("{s} is not a colour this build acts on\n", .{entry.name});
            return error.UnknownEntry;
        };
        if (!got.eql(.{ .r = 1, .g = 2, .b = 3 })) {
            std.debug.print("{s} was set to {s} but did not change\n", .{ entry.name, probe });
            return error.SettingIgnored;
        }
    }

    // And the table has no entry that is not a setting.
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "keybind.")) continue;
        const field_name = entry.name["keybind.".len..];
        var found = false;
        inline for (@typeInfo(Keybinds).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) found = true;
        }
        if (!found) {
            std.debug.print("{s} is in the table but is not a setting\n", .{entry.name});
            return error.ExtraEntry;
        }
    }
}

/// Read back a keybind by its full name, or null when the name is not one this build knows.
///
/// The names are matched against the field names at compile time, so the comparison is between the
/// table and the structure rather than between two copies of a string.
fn keybindField(keybinds: *const Keybinds, name: []const u8) ?u8 {
    inline for (@typeInfo(Keybinds).@"struct".fields) |field| {
        if (std.mem.eql(u8, name, "keybind." ++ field.name)) {
            return @field(keybinds, field.name);
        }
    }
    return null;
}

/// Read back a colour by its full name, or null when the name is not one this build knows.
fn colourField(colours: *const Colours, name: []const u8) ?Rgb {
    if (std.mem.eql(u8, name, "border.active.fg")) return colours.border_active_fg;
    if (std.mem.eql(u8, name, "border.inactive.fg")) return colours.border_inactive_fg;
    if (std.mem.eql(u8, name, "status.bg")) return colours.status_bg;
    if (std.mem.eql(u8, name, "status.fg")) return colours.status_fg;
    return null;
}

test "only a colour that can be absent can be set back to absent" {
    // `border.inactive.fg` is an optional colour, because an unfocused pane is allowed to have no
    // colour of its own and keep whatever the terminal is doing. The other three are not: a status
    // line has to have a foreground and a background, and the focused border is the whole point of a
    // border. The types say so, and this says that `apply` respects them rather than inventing a
    // black for a colour the user asked to remove.
    var config = Config{};
    apply(&config, "border.inactive.fg", "#010203");
    try std.testing.expect(config.colours.border_inactive_fg.?.eql(.{ .r = 1, .g = 2, .b = 3 }));

    apply(&config, "border.inactive.fg", "null");
    try std.testing.expectEqual(@as(?Rgb, null), config.colours.border_inactive_fg);

    // An empty string is the same request as `null`, because a user who deleted the value in an
    // editor leaves one behind and means the same thing by it.
    apply(&config, "border.inactive.fg", "#010203");
    apply(&config, "border.inactive.fg", "");
    try std.testing.expectEqual(@as(?Rgb, null), config.colours.border_inactive_fg);

    // And a colour that cannot be absent ignores the request rather than becoming black, which would
    // be a change the user did not ask for.
    apply(&config, "status.bg", "#010203");
    apply(&config, "status.bg", "null");
    try std.testing.expect(config.colours.status_bg.eql(.{ .r = 1, .g = 2, .b = 3 }));
}
