//! Measures what a keystroke costs, and checks that the cursor appears.
//!
//! A client repaints after every keystroke, so the bytes it writes are what a
//! user perceives as flicker: repainting every cell of every pane is a lot of
//! traffic for a terminal to absorb while someone is typing. The pane's own
//! terminal reports which rows actually changed, and this measures whether the
//! client is using that or rewriting the screen.
//!
//! zmux is started exactly as a terminal emulator would start it, against a
//! runtime directory of its own, so this exercises the real client rather than
//! a model of it. The pty handling is the same code the product uses.
//!
//! Build and run:
//!   zig build drive && ./zig-out/bin/drive -- ./zig-out/bin/zmux attach measure
//!
//! The tiled figure is the baseline; the floated figure is the interesting one,
//! because a float sits over the tiled panes and a client that repaints
//! everything spends the frame on the panes it covers as well.

const std = @import("std");
const linux = std.os.linux;
const pty_mod = @import("pty");

/// How long to wait for the client to start and the shell to print a prompt.
const settle_ms = 2500;
/// How long to collect output after each keystroke.
const per_key_ms = 400;
/// How long to collect output while nothing is happening.
const idle_ms = 1200;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    // Everything after the separator is the command, so a release build can be
    // measured as easily as a debug one.
    var command: std.ArrayList([*:0]const u8) = .empty;
    defer command.deinit(gpa);
    var buffers: [64][std.fs.max_path_bytes]u8 = undefined;
    var buffer_count: usize = 0;
    var seen_separator = false;
    while (args.next()) |argument| {
        if (!seen_separator) {
            if (std.mem.eql(u8, argument, "--")) seen_separator = true;
            continue;
        }
        if (buffer_count >= buffers.len) break;
        const terminated = try std.fmt.bufPrintZ(&buffers[buffer_count], "{s}", .{argument});
        command.append(gpa, terminated.ptr) catch break;
        buffer_count += 1;
    }
    if (command.items.len == 0) {
        std.debug.print("usage: drive -- <program> [args...]\n", .{});
        return error.NoProgram;
    }
    var argv: [65]?[*:0]const u8 = undefined;
    for (command.items, 0..) |argument, index| argv[index] = argument;
    argv[command.items.len] = null;

    // A runtime directory of its own, so a server the user is already running is
    // not disturbed and the measurement does not join someone else's session.
    const envp = [_:null]?[*:0]const u8{
        "PATH=/run/current-system/sw/bin:/bin:/usr/bin",
        "TERM=xterm-256color",
        "SHELL=/run/current-system/sw/bin/fish",
        "XDG_RUNTIME_DIR=/tmp/zmux-drive",
        "HOME=/tmp/zmux-drive",
    };

    var pty = try pty_mod.Pty.spawn(@ptrCast(&argv), &envp, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();
    pty.setNonBlocking();

    var buffer: [64 * 1024]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(gpa);

    // Let the client start and the shell print its prompt.
    sleepMillis(settle_ms);
    collect(&pty, &buffer, &collected, gpa);

    // The cursor is hidden when the session starts and only the client can show
    // it again, so a prompt with no visible cursor means the user is typing blind.
    // Reported before the timing runs disturb the screen.
    const cursor = findCursor(collected.items);
    std.debug.print("cursor at the prompt     : {s}\n", .{
        if (cursor.shown) "shown" else "NOT SHOWN",
    });
    if (cursor.shown) {
        std.debug.print("cursor position          : row {d}, column {d}\n", .{
            cursor.row, cursor.column,
        });
    }

    // An idle period. Output here is repainting that nothing asked for.
    collected.clearRetainingCapacity();
    sleepMillis(idle_ms);
    collect(&pty, &buffer, &collected, gpa);
    const idle_bytes = collected.items.len;

    const keys = "abcdefghijklmnop";

    // Type into a tiled pane.
    var tiled: [keys.len]usize = undefined;
    for (keys, 0..) |key, index| {
        tiled[index] = keystroke(&pty, &buffer, &collected, gpa, key);
    }

    // The same measurement with the pane floated. Opening the float is not
    // counted; the bytes it costs belong to the frame that drew it.
    _ = pty.write("\x01f") catch {};
    sleepMillis(1000);
    collected.clearRetainingCapacity();
    collect(&pty, &buffer, &collected, gpa);
    const floated_cursor = findCursor(collected.items);

    var floated: [keys.len]usize = undefined;
    for (keys, 0..) |key, index| {
        floated[index] = keystroke(&pty, &buffer, &collected, gpa, key);
    }

    // Leave cleanly, so no server is left behind for the next run.
    _ = pty.write("\x01q") catch {};
    sleepMillis(600);
    collect(&pty, &buffer, &collected, gpa);
    if (pty.reap()) |status| {
        if (!status.signaled and status.code != 0) {
            std.debug.print("[drive] client exited with code {d}\n", .{status.code});
        }
    }

    std.debug.print("idle output              : {d} bytes\n", .{idle_bytes});
    report("tiled", &tiled);
    report("floated", &floated);

    // The properties a regression would break, stated as a verdict rather than
    // left for the reader to eyeball.
    const tiled_mean = mean(&tiled);
    if (!cursor.shown) {
        std.debug.print("verdict: FAIL, the cursor was never shown\n", .{});
    } else if (!floated_cursor.shown) {
        std.debug.print("verdict: FAIL, the cursor vanished when the pane floated\n", .{});
    } else if (idle_bytes > 64) {
        std.debug.print("verdict: FAIL, an idle frame wrote {d} bytes\n", .{idle_bytes});
    } else if (tiled_mean > 2_000) {
        std.debug.print(
            "verdict: FAIL, a keystroke cost {d} bytes, which is a full repaint\n",
            .{tiled_mean},
        );
    } else {
        std.debug.print("verdict: OK\n", .{});
    }
}

/// Where the last cursor placement in the output put the cursor.
const Cursor = struct {
    shown: bool = false,
    /// One-based, as the terminal addresses them.
    row: usize = 0,
    column: usize = 0,
};

/// Find the last cursor placement, and whether the cursor was left visible.
///
/// The client writes `ESC[<row>;<col>H` followed by `ESC[?25h` when it wants the
/// cursor seen, and a bare `ESC[?25l` when it does not. The last of the two wins,
/// because that is what the terminal would end up displaying.
fn findCursor(bytes: []const u8) Cursor {
    var cursor = Cursor{};
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 1) {
        if (bytes[index] != 0x1b or bytes[index + 1] != '[') continue;

        if (startsWith(bytes[index..], "\x1b[?25h")) {
            cursor.shown = true;
            continue;
        }
        if (startsWith(bytes[index..], "\x1b[?25l")) {
            cursor.shown = false;
            continue;
        }

        // A cursor move: ESC [ digits ; digits H. Anything else in this shape,
        // such as the erase-to-end-of-line sequence, fails the parse and is left
        // alone.
        var scan = index + 2;
        var row: usize = 0;
        while (scan < bytes.len and bytes[scan] >= '0' and bytes[scan] <= '9') : (scan += 1) {
            row = row * 10 + (bytes[scan] - '0');
        }
        if (scan >= bytes.len or bytes[scan] != ';') continue;
        scan += 1;
        var column: usize = 0;
        while (scan < bytes.len and bytes[scan] >= '0' and bytes[scan] <= '9') : (scan += 1) {
            column = column * 10 + (bytes[scan] - '0');
        }
        if (scan >= bytes.len or bytes[scan] != 'H') continue;
        // Only a move that is immediately followed by a show is the cursor's own
        // placement; every row of every pane moves the cursor too.
        if (!startsWith(bytes[scan + 1 ..], "\x1b[?25h")) continue;

        cursor.row = row;
        cursor.column = column;
        cursor.shown = true;
        index = scan;
    }
    return cursor;
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    if (bytes.len < prefix.len) return false;
    return std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

/// Send one key and return how many bytes came back.
fn keystroke(
    pty: *pty_mod.Pty,
    buffer: []u8,
    collected: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    key: u8,
) usize {
    _ = pty.write(&.{key}) catch return 0;
    collected.clearRetainingCapacity();
    sleepMillis(per_key_ms);
    collect(pty, buffer, collected, gpa);
    return collected.items.len;
}

fn mean(counts: []const usize) usize {
    if (counts.len == 0) return 0;
    var total: usize = 0;
    for (counts) |count| total += count;
    return total / counts.len;
}

fn report(label: []const u8, counts: []const usize) void {
    std.debug.print("{s:<24} :", .{label});
    for (counts) |count| std.debug.print(" {d}", .{count});
    std.debug.print("\n", .{});
    std.debug.print("{s:<24} : mean {d} bytes per keystroke\n", .{ label, mean(counts) });
}

fn collect(
    pty: *pty_mod.Pty,
    buffer: []u8,
    collected: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) void {
    while (true) {
        // A closed slave and an idle master both read as nothing; either way
        // there is no more output to account for.
        const read = pty.read(buffer) catch return;
        if (read == 0) return;
        collected.appendSlice(gpa, buffer[0..read]) catch return;
    }
}

fn sleepMillis(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}
