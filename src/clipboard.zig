//! The clipboard, reached through the terminal rather than through a program.
//!
//! OSC 52 is the escape a terminal uses to ask its emulator to put text on the system clipboard.
//! zmux writes it to its own terminal, so the copy is handed to whatever emulator zmux is running
//! inside. That is what makes a copy work over SSH: the bytes travel back down the connection the
//! screen already comes up, and no program has to exist on the far side.
//!
//! The alternative, running `wl-copy` or `xclip`, is kept as a fallback because not every terminal
//! implements OSC 52 or allows it through. The fallback is worse in two ways worth naming: it needs
//! a program installed, and it cannot reach the user's clipboard across a connection. It is tried
//! second for those reasons, not because it is more reliable locally.

const std = @import("std");
const linux = std.os.linux;

/// The largest payload worth sending.
///
/// Terminals cap what they will accept, and several silently drop anything longer, so a copy past
/// this is reported as too large rather than sent and hoped for. tmux uses a similar bound for the
/// same reason. A selection larger than this is a whole scrollback, which is not what a copy key is
/// usually for.
pub const max_payload = 74_994;

pub const Error = error{
    /// The selection is larger than a terminal will accept.
    TooLarge,
    /// The escape could not be built, which means an allocation failed.
    OutOfMemory,
};

/// The programs tried when the terminal will not take an OSC 52 escape.
///
/// In order of what each environment most likely has, and each with the arguments it needs to write
/// the clipboard rather than the primary selection: `xclip` and `xsel` both default to the primary
/// selection, which is not what a paste reads in most programs. `wl-copy` and `pbcopy` have no such
/// choice to make.
///
/// They are all driven with the text on standard input, which is the shape they share, so one code
/// path runs them.
pub const fallback_commands = [_][]const []const u8{
    &.{"wl-copy"},
    &.{ "xclip", "-selection", "clipboard" },
    &.{ "xsel", "--clipboard", "--input" },
    &.{"pbcopy"},
};

/// Build the OSC 52 escape that puts `text` on the clipboard.
///
/// The escape is `ESC ] 52 ; c ; <base64> BEL`. The `c` names the clipboard as opposed to the
/// primary selection, which is what a paste reads. BEL terminates it rather than ST, because BEL is
/// what terminals have accepted longest; ST is the more correct terminator and is silently ignored
/// by some emulators.
///
/// The text is base64 because the escape runs to a terminator, and raw text containing a BEL or an
/// escape would end it early and corrupt the stream the terminal is reading.
pub fn encode(gpa: std.mem.Allocator, text: []const u8) Error![]u8 {
    if (text.len > max_payload) return Error.TooLarge;

    // Four base64 characters per three bytes, rounded up.
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    const prefix = "\x1b]52;c;";
    const suffix = "\x07";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    try out.resize(gpa, prefix.len + encoded_len);
    _ = std.base64.standard.Encoder.encode(out.items[prefix.len..], text);
    try out.appendSlice(gpa, suffix);
    return out.toOwnedSlice(gpa);
}

/// Whether an escape carries a clipboard payload, for tests and for the caller that reports what
/// happened. Not used to parse: zmux writes these and never reads them.
pub fn isClipboardEscape(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x1b]52;c;");
}

/// Feed `text` to the first fallback program that exists and accepts it.
///
/// Returns the program that took it, or null when none did. The name is returned rather than a
/// boolean so the caller can say which one worked, which is the only way a user can tell why a copy
/// behaved differently on two machines.
///
/// The child's standard output and error are pointed at `/dev/null` rather than inherited. zmux has
/// the terminal in raw mode and the alternate screen active, so a program that printed a warning
/// would write it into the middle of a drawn frame and leave it there until the next full repaint.
pub fn runFallback(text: []const u8) ?[]const u8 {
    for (fallback_commands) |command| {
        if (tryCommand(command, text)) return command[0];
    }
    return null;
}

/// Run one program with `text` on its standard input, and say whether it exited successfully.
///
/// No allocation happens between the fork and the exec, because the child of a fork in a
/// multi-threaded process may only call async-signal-safe functions. The argument vector is built by
/// the caller for that reason, and paths are the bare program names: `execve` is given `execvp`'s
/// searching behaviour by walking `PATH` first, since the child cannot do it after the fork.
fn tryCommand(command: []const []const u8, text: []const u8) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = resolve(command[0], &path_buffer) orelse return false;

    // A pipe carries the text, so the child never touches the terminal. Both ends are made before
    // the fork, since neither process can create one safely afterwards.
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = false })) != .SUCCESS) return false;

    // The argv the child needs: the program, any fixed arguments, then a null. `xclip` and `xsel`
    // need to be told which selection to write, which is why the table holds argument lists rather
    // than bare names.
    var argv: [8]?[*:0]const u8 = undefined;
    var argc: usize = 0;
    var argument_buffers: [8][64]u8 = undefined;
    for (command) |argument| {
        if (argc + 1 >= argv.len) break;
        const terminated = std.fmt.bufPrintZ(&argument_buffers[argc], "{s}", .{argument}) catch break;
        argv[argc] = terminated.ptr;
        argc += 1;
    }
    if (argc != command.len) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return false;
    }
    argv[argc] = null;

    const raw = linux.fork();
    if (linux.errno(raw) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return false;
    }
    const pid: linux.pid_t = @intCast(@as(isize, @bitCast(raw)));

    if (pid == 0) {
        // Child. Only async-signal-safe calls from here to the exec.
        _ = linux.close(fds[1]);
        _ = linux.dup2(fds[0], 0);
        if (fds[0] > 2) _ = linux.close(fds[0]);
        // Discarded rather than inherited; see the note on `runFallback`.
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(devnull) == .SUCCESS) {
            const fd: i32 = @intCast(devnull);
            _ = linux.dup2(fd, 1);
            _ = linux.dup2(fd, 2);
            if (fd > 2) _ = linux.close(fd);
        }
        _ = linux.execve(executable.ptr, @ptrCast(&argv), std.c.environ);
        linux.exit(127);
    }

    // Parent. The read end belongs to the child now, and holding it open would keep the child from
    // ever seeing end-of-input.
    _ = linux.close(fds[0]);
    writeAll(fds[1], text);
    _ = linux.close(fds[1]);

    // Waited for rather than left to run: a copy that has not finished when the caller returns
    // could still be reading the buffer, and a zombie per copy would accumulate.
    var status: u32 = 0;
    while (true) {
        const waited = linux.waitpid(pid, &status, 0);
        if (linux.errno(waited) == .INTR) continue;
        if (linux.errno(waited) != .SUCCESS) return false;
        break;
    }
    // A program that exited non-zero refused the text, so the next one is tried.
    const code: u32 = (status >> 8) & 0xFF;
    return code == 0;
}

/// The search path for the fallback programs.
///
/// Read through libc rather than the standard library, because Zig 0.16 removed the global
/// environment from `std.posix` and the product has no `Io` to thread through for one lookup. This
/// is the only thing in the module that wants an environment, and it wants a path rather than state
/// zmux keeps.
fn searchPath() []const u8 {
    const value = std.c.getenv("PATH") orelse return "/usr/local/bin:/usr/bin:/bin";
    return std.mem.span(value);
}

/// Find a program by name on `PATH`, writing the full path into `buffer`.
///
/// Duplicated in spirit from what `execvp` would do, because the child cannot search after the fork
/// and the parent may not allocate before it. An absolute or relative name is taken as it is.
fn resolve(name: []const u8, buffer: []u8) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return std.fmt.bufPrintZ(buffer, "{s}", .{name}) catch null;
    }
    var it = std.mem.splitScalar(u8, searchPath(), ':');
    while (it.next()) |directory| {
        if (directory.len == 0) continue;
        const full = std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ directory, name }) catch continue;
        // Checked by asking whether it can be executed rather than by reading its mode bits. A
        // directory entry can be executable and still not be a program.
        if (isExecutable(full.ptr)) return full;
    }
    return null;
}

fn isExecutable(path: [*:0]const u8) bool {
    const result = linux.access(path, linux.X_OK);
    return linux.errno(result) == .SUCCESS;
}

fn writeAll(fd: i32, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const err = linux.errno(written);
        if (err == .INTR) continue;
        if (err != .SUCCESS or written == 0) return;
        offset += written;
    }
}

test "the escape wraps the text in base64 with a BEL terminator" {
    const gpa = std.testing.allocator;
    const escape = try encode(gpa, "hello");
    defer gpa.free(escape);

    // "hello" in base64 is "aGVsbG8=", and the whole thing is one escape the terminal can read.
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", escape);
    try std.testing.expect(isClipboardEscape(escape));
}

test "a byte that would end the escape early is carried safely" {
    const gpa = std.testing.allocator;
    // A BEL would terminate the escape and an ESC would start a new one, so text holding either has
    // to survive the trip. Base64 is what makes that true, and this is the case that proves it.
    const text = "bell\x07 and escape\x1b[0m";
    const escape = try encode(gpa, text);
    defer gpa.free(escape);

    // The only BEL in the escape is the terminator, and no ESC appears after the introducer.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escape, "\x07"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escape, "\x1b"));

    // And the payload decodes back to exactly what went in.
    const payload = escape["\x1b]52;c;".len .. escape.len - 1];
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, payload);
    try std.testing.expectEqualStrings(text, decoded);
}

test "empty text still produces a usable escape" {
    const gpa = std.testing.allocator;
    // Copying nothing is not worth sending, but the encoder must not produce a malformed escape if
    // it is asked: an empty payload clears the clipboard, which is a defined thing to do.
    const escape = try encode(gpa, "");
    defer gpa.free(escape);
    try std.testing.expectEqualStrings("\x1b]52;c;\x07", escape);
}

test "a selection past what a terminal accepts is refused" {
    const gpa = std.testing.allocator;
    const huge = try gpa.alloc(u8, max_payload + 1);
    defer gpa.free(huge);
    @memset(huge, 'x');

    // Refused rather than sent and dropped: a terminal that silently discards an oversized escape
    // would leave the user believing they had copied something.
    try std.testing.expectError(Error.TooLarge, encode(gpa, huge));

    // And the limit itself is accepted, so the bound is inclusive rather than off by one.
    const at_limit = try gpa.alloc(u8, max_payload);
    defer gpa.free(at_limit);
    @memset(at_limit, 'y');
    const escape = try encode(gpa, at_limit);
    defer gpa.free(escape);
}

test "the fallback runs a program and feeds it the text" {
    // A stand-in for wl-copy: the real ones are not installed everywhere, and what is being tested
    // is the pipe, the wait and the exit status, not any particular clipboard program.
    const dir = "/tmp/zmux-clipboard-test";
    _ = std.os.linux.mkdir(dir, 0o700);

    const script = dir ++ "/fake-clip";
    const body = "#!/bin/sh\ncat > " ++ dir ++ "/captured\n";
    writeFile(script, body, 0o755);
    writeFile(dir ++ "/captured", "", 0o644);

    // The program is found through PATH, which is what the real fallback relies on.
    const previous = searchPath();
    var buffer: [std.fs.max_path_bytes * 2]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buffer, "{s}:{s}", .{ dir, previous }) catch return;
    setPath(path);

    const taken = tryCommand(&.{"fake-clip"}, "copied text");
    try std.testing.expect(taken);

    var captured_buffer: [256]u8 = undefined;
    const captured = readFile(dir ++ "/captured", &captured_buffer);
    // The text arrived whole and unmodified, which is what a program reading standard input does.
    try std.testing.expectEqualStrings("copied text", captured);
}

test "a program that exits non-zero is reported as refusing the text" {
    const dir = "/tmp/zmux-clipboard-test";
    _ = std.os.linux.mkdir(dir, 0o700);

    const script = dir ++ "/fake-refuse";
    writeFile(script, "#!/bin/sh\nexit 3\n", 0o755);

    const previous = searchPath();
    var buffer: [std.fs.max_path_bytes * 2]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buffer, "{s}:{s}", .{ dir, previous }) catch return;
    setPath(path);

    // A non-zero exit is how xclip reports having no X display, so it has to mean "try the next
    // one" rather than "copied".
    try std.testing.expect(!tryCommand(&.{"fake-refuse"}, "text"));
}

test "a program that does not exist is skipped without forking" {
    const taken = tryCommand(&.{"zmux-no-such-clipboard-program"}, "text");
    try std.testing.expect(!taken);
}

fn writeFile(path: []const u8, contents: []const u8, mode: u32) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const terminated = std.fmt.bufPrintZ(&buffer, "{s}", .{path}) catch return;
    const opened = linux.open(terminated.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, mode);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    writeAll(fd, contents);
}

/// Read a small file into a caller-owned buffer, returning the part that was filled.
///
/// Borrowing rather than allocating, so that a test which fails its assertion cannot also fail the
/// leak check and leave it unclear which of the two happened.
fn readFile(path: []const u8, buffer: []u8) []const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const terminated = std.fmt.bufPrintZ(&path_buffer, "{s}", .{path}) catch return "";
    const opened = linux.open(terminated.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return "";
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);

    const read = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(read) != .SUCCESS) return "";
    return buffer[0..read];
}

/// libc's `setenv`, which the standard library does not declare in 0.16.
///
/// The product only reads `PATH`. This exists so a test can point it at a stand-in program without
/// needing the real clipboard tools installed.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setPath(value: [:0]const u8) void {
    _ = setenv("PATH", value.ptr, 1);
}
