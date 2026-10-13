//! A test driver that runs `zmux run <program>` inside a pty and feeds it
//! keystrokes on a schedule, so an interactive program can be exercised
//! without a human at the keyboard.
//!
//! The pty handling is the same code the product uses, so this also serves as
//! an end-to-end check of `src/pty.zig`.
//!
//! Build and run:
//!   zig run tools/drive.zig -- ./zig-out/bin/zmux run /usr/bin/vi /tmp/out.txt

const std = @import("std");
const linux = std.os.linux;
const pty_mod = @import("pty");

const Step = struct {
    /// Milliseconds to wait before sending this step.
    delay_ms: u64,
    keys: []const u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    // Everything after the command separator is the program to drive.
    var command: std.ArrayList([*:0]const u8) = .empty;
    defer command.deinit(gpa);

    // Each argument needs its own null-terminated buffer.
    var buffers: [64][std.fs.max_path_bytes]u8 = undefined;
    var buffer_count: usize = 0;

    var seen_separator = false;
    while (args.next()) |argument| {
        if (!seen_separator and std.mem.eql(u8, argument, "--")) {
            seen_separator = true;
            continue;
        }
        if (!seen_separator) continue;
        if (buffer_count >= buffers.len) break;
        const terminated = try std.fmt.bufPrintZ(&buffers[buffer_count], "{s}", .{argument});
        try command.append(gpa, terminated.ptr);
        buffer_count += 1;
    }

    if (command.items.len == 0) {
        std.debug.print("usage: drive -- <program> [args...]\n", .{});
        return error.NoProgram;
    }

    // A null-terminated vector for execve.
    var argv: [65]?[*:0]const u8 = undefined;
    for (command.items, 0..) |argument, index| argv[index] = argument;
    argv[command.items.len] = null;

    // The keystroke script. Escape gets its own step with a delay so insert
    // mode is left before the ex command that follows.
    const script = [_]Step{
        .{ .delay_ms = 2000, .keys = "ihello from zmux" },
        .{ .delay_ms = 800, .keys = "\x1b" },
        .{ .delay_ms = 800, .keys = ":w /tmp/zmux-vim-test.txt\r" },
        .{ .delay_ms = 1500, .keys = ":q!\r" },
        .{ .delay_ms = 800, .keys = "" },
    };

    const envp = [_:null]?[*:0]const u8{ "PATH=/bin:/usr/bin", "TERM=xterm-256color" };

    var pty = try pty_mod.Pty.spawn(@ptrCast(&argv), &envp, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();
    pty.setNonBlocking();

    var buffer: [64 * 1024]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(gpa);

    for (script) |step| {
        sleepMillis(step.delay_ms);
        if (step.keys.len > 0) {
            var offset: usize = 0;
            while (offset < step.keys.len) {
                const written = pty.write(step.keys[offset..]) catch break;
                if (written == 0) break;
                offset += written;
            }
        }
        drain(&pty, &buffer, &collected, gpa);
    }

    // Let the program exit, then collect whatever is left.
    sleepMillis(800);
    drain(&pty, &buffer, &collected, gpa);

    const status = pty.reap();
    if (status) |s| {
        std.debug.print("\n[drive] child exited: code={d} signaled={}\n", .{ s.code, s.signaled });
    } else {
        std.debug.print("\n[drive] child still running after the script\n", .{});
    }

    // Report the screen with escape sequences made visible, so the result can
    // be checked without a terminal interpreting them.
    const visible = try visibleEscapes(gpa, collected.items);
    defer gpa.free(visible);
    writeAll(1, visible);
}

/// Write to a raw descriptor, retrying short writes.
fn writeAll(fd: i32, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (linux.errno(written) != .SUCCESS or written == 0) return;
        offset += written;
    }
}

fn drain(
    pty: *pty_mod.Pty,
    buffer: []u8,
    collected: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) void {
    while (true) {
        const read = pty.read(buffer) catch |err| switch (err) {
            // The slave closed, so the child is gone.
            pty_mod.Error.Closed => return,
            else => return,
        };
        if (read == 0) return;
        collected.appendSlice(gpa, buffer[0..read]) catch return;
    }
}

/// Replace control bytes with a readable form so the output can be inspected
/// in a terminal that is not interpreting them.
fn visibleEscapes(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (input) |byte| {
        switch (byte) {
            0x1b => try out.appendSlice(gpa, "<ESC>"),
            '\n' => try out.append(gpa, '\n'),
            '\r' => try out.appendSlice(gpa, "<CR>"),
            0x7F => try out.appendSlice(gpa, "<DEL>"),
            else => {
                if (byte < 0x20) {
                    try out.appendSlice(gpa, "<CTRL>");
                } else {
                    try out.append(gpa, byte);
                }
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

fn sleepMillis(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}
