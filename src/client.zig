const std = @import("std");
const posix = std.posix;
const c = @import("c.zig").c;
const Stream = @import("Stream.zig").Stream;
const protocol = @import("protocol.zig");
const Loop = @import("loop.zig").Loop;

const TAG_STDIN: usize = 1;
const TAG_SOCK: usize = 2;
const TAG_SIGNAL: usize = 3;

/// termios configuration for zmux client
/// Sets the terminal to non-canonical mode,
/// allowing input to be read character by character instead of line by line
fn enableRawMode(original_termios: *c.termios) !void {
    // Get original termios configuration
    if (c.tcgetattr(c.STDIN_FILENO, original_termios) < 0)
        return error.TcgetattrFailed;

    var raw = original_termios.*;

    // non-canonical + echo off + Invalidate signal
    raw.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ISIG | c.IEXTEN);
    // Disable CR→LF conversion and other input processing
    raw.c_iflag &= ~@as(c_uint, c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP);
    // Enable multi-byte character support
    raw.c_cflag |= @as(c_uint, c.CS8);
    // Return as soon as 1 character is available, no timeout
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) < 0)
        return error.TcsetattrFailed;
}

/// Restore the terminal attributes modified by zmux to their original state
fn disableRawMode(original_termios: *c.termios) void {
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, original_termios);
}

/// Client input modes
const InputMode = enum {
    normal,
    prefix,
    prefix_repeatable, // For repeatable commands (h/j/k/l focus, i/u cycle, </> resize)
    scroll,
    copy,
    move_pane, // Waiting for workspace number after 'm'
};

pub fn client(socket_path: []const u8) !void {
    // Original termios settings, restored on zmux exit
    var original_termios: c.termios = undefined;
    const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

    // Get terminal size
    var term_size = getTermSize();

    const sock_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock_fd);

    var addr = posix.sockaddr.un{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    try posix.connect(sock_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    try enableRawMode(&original_termios);
    defer disableRawMode(&original_termios);

    // Clear screen on start and enable mouse reporting (SGR mode)
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Clear screen + enable mouse tracking (1000) + SGR extended mode (1006)
    // 1000 = track button press/release (including wheel)
    try stdout.writeAll("\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006h");
    try stdout.flush();

    var loop = try Loop.init();
    defer loop.deinit();
    try loop.addFd(stdin_fd, TAG_STDIN, false);
    try loop.addFd(sock_fd, TAG_SOCK, true);
    try loop.addSignal(posix.SIG.WINCH, TAG_SIGNAL);

    var stream = Stream(256 * 1024).init(); // 256KB for rendered screen output

    // Send attach request to server with terminal size
    var attach_buf: [256]u8 = undefined;
    const attach_req = protocol.Request{ .attach = .{
        .session_name = "default",
        .cols = term_size.cols,
        .rows = term_size.rows,
    } };
    const attach_data = try attach_req.encode(&attach_buf);
    try stream.write(attach_data, sock_fd);

    // Wait for attach_ok response before entering main loop
    while (true) {
        stream.receiveData(sock_fd) catch |err| {
            if (err == error.Closed) return;
            return err;
        };

        if (stream.nextMessage()) |msg| {
            // Parse as Response to verify it's attach_ok
            const response = protocol.Response.decode(msg) catch {
                // Invalid response, treat as fatal error
                return error.InvalidAttachResponse;
            };
            switch (response) {
                .attach_ok => break, // Success, proceed to main loop
                .err => return error.AttachRejected,
                .message => {}, // Ignore, wait for attach_ok
            }
        }
    }

    // Process any render output that came with the attach_ok
    while (stream.nextMessage()) |output| {
        try stdout.writeAll(output);
        try stdout.flush();
    }

    // Input mode state
    var mode: InputMode = .normal;

    outer: while (true) {
        var iter = loop.wait(-1);
        while (iter.next()) |event| {
            switch (event) {
                .disconnect => break :outer,
                .signal => {
                    const new_size = getTermSize();
                    if (new_size.cols != term_size.cols or new_size.rows != term_size.rows) {
                        term_size = new_size;
                        var resize_buf: [256]u8 = undefined;
                        const resize_req = protocol.Request{ .resize = .{
                            .cols = new_size.cols,
                            .rows = new_size.rows,
                        } };
                        const resize_data = try resize_req.encode(&resize_buf);
                        try stream.write(resize_data, sock_fd);
                    }
                },
                .readable => |tag| switch (tag) {
                    TAG_SOCK => {
                        stream.receiveData(sock_fd) catch |err| {
                            if (err == error.Closed) break :outer;
                            return err;
                        };
                        while (stream.nextMessage()) |output| {
                            try stdout.writeAll(output);
                            try stdout.flush();
                        }
                    },
                    TAG_STDIN => {
                        var buf: [64]u8 = undefined;
                        const n = try posix.read(stdin_fd, &buf);
                        if (n == 0) break :outer;

                        const user_input = buf[0..n];
                        var req_buf: [256]u8 = undefined;

                        switch (mode) {
                            .normal => {
                                // Process input, handling mouse events in a loop
                                var remaining = user_input;

                                while (remaining.len > 0) {
                                    // Check for mouse escape sequence (SGR format: \x1b[<...)
                                    if (parseSgrMouse(remaining)) |mouse| {
                                        // In normal mode, only handle wheel for scrolling
                                        // All other mouse events are forwarded to the application
                                        var handled = false;

                                        if (!mouse.event.is_release) {
                                            switch (mouse.event.button) {
                                                MouseEvent.WHEEL_UP => {
                                                    const req = protocol.Request{ .scroll_mode_input = .{ .key = .scroll_up } };
                                                    const req_data = try req.encode(&req_buf);
                                                    try stream.write(req_data, sock_fd);
                                                    handled = true;
                                                },
                                                MouseEvent.WHEEL_DOWN => {
                                                    const req = protocol.Request{ .scroll_mode_input = .{ .key = .scroll_down } };
                                                    const req_data = try req.encode(&req_buf);
                                                    try stream.write(req_data, sock_fd);
                                                    handled = true;
                                                },
                                                else => {},
                                            }
                                        }

                                        if (!handled) {
                                            // Forward mouse event to application
                                            const input_req = protocol.Request{ .input = .{ .input = remaining[0..mouse.len] } };
                                            const req_data = try input_req.encode(&req_buf);
                                            try stream.write(req_data, sock_fd);
                                        }

                                        // Consume parsed bytes and continue processing
                                        remaining = remaining[mouse.len..];
                                        continue;
                                    }

                                    // If input looks like an incomplete mouse sequence, forward it to the app
                                    // The app can handle escape sequences with its own timeout logic
                                    // (This allows ESC key to work properly)

                                    // Check for prefix key (Ctrl-b = 0x02)
                                    if (remaining.len == 1 and remaining[0] == 0x02) {
                                        mode = .prefix;
                                        // Notify server that prefix mode is active
                                        const prefix_req = protocol.Request{ .set_prefix_mode = .{ .enabled = true } };
                                        const prefix_data = try prefix_req.encode(&req_buf);
                                        try stream.write(prefix_data, sock_fd);
                                        break;
                                    }

                                    // Forward all other input to server
                                    const input_req = protocol.Request{ .input = .{ .input = remaining } };
                                    const req_data = try input_req.encode(&req_buf);
                                    try stream.write(req_data, sock_fd);
                                    break;
                                }
                            },
                            .prefix, .prefix_repeatable => {
                                var stay_in_prefix = false;
                                var maybe_req: ?protocol.Request = null;

                                switch (user_input[0]) {
                                    // Pane splitting (exits prefix mode)
                                    '\\' => maybe_req = .{ .split_pane = .{ .direction = .vertical } },
                                    '-' => maybe_req = .{ .split_pane = .{ .direction = .horizontal } },

                                    // Pane focus (repeatable)
                                    'h' => {
                                        maybe_req = .{ .focus_pane = .{ .direction = .left } };
                                        stay_in_prefix = true;
                                    },
                                    'j' => {
                                        maybe_req = .{ .focus_pane = .{ .direction = .down } };
                                        stay_in_prefix = true;
                                    },
                                    'k' => {
                                        maybe_req = .{ .focus_pane = .{ .direction = .up } };
                                        stay_in_prefix = true;
                                    },
                                    'l' => {
                                        maybe_req = .{ .focus_pane = .{ .direction = .right } };
                                        stay_in_prefix = true;
                                    },

                                    // Pane swap (repeatable)
                                    'H' => {
                                        maybe_req = .{ .swap_pane = .{ .direction = .left } };
                                        stay_in_prefix = true;
                                    },
                                    'J' => {
                                        maybe_req = .{ .swap_pane = .{ .direction = .down } };
                                        stay_in_prefix = true;
                                    },
                                    'K' => {
                                        maybe_req = .{ .swap_pane = .{ .direction = .up } };
                                        stay_in_prefix = true;
                                    },
                                    'L' => {
                                        maybe_req = .{ .swap_pane = .{ .direction = .right } };
                                        stay_in_prefix = true;
                                    },

                                    // Pane resize (repeatable)
                                    '>' => {
                                        maybe_req = .{ .resize_pane = .{ .grow = true } };
                                        stay_in_prefix = true;
                                    },
                                    '<' => {
                                        maybe_req = .{ .resize_pane = .{ .grow = false } };
                                        stay_in_prefix = true;
                                    },

                                    // Close pane
                                    'x' => maybe_req = .{ .close_pane = {} },

                                    // Workspace operations
                                    'n' => maybe_req = .{ .new_workspace = {} },
                                    'f' => maybe_req = .{ .toggle_floating = {} },

                                    // Workspace cycling (repeatable)
                                    'i' => {
                                        maybe_req = .{ .cycle_workspace = .{ .next = true } };
                                        stay_in_prefix = true;
                                    },
                                    'u' => {
                                        maybe_req = .{ .cycle_workspace = .{ .next = false } };
                                        stay_in_prefix = true;
                                    },

                                    // Switch to workspace by number
                                    '1'...'9' => |ws_char| maybe_req = .{ .switch_workspace = .{ .index = ws_char - '1' } },

                                    // Move pane to workspace (enter move_pane mode)
                                    'm' => {
                                        mode = .move_pane;
                                        continue;
                                    },

                                    // Scroll mode
                                    's' => {
                                        mode = .scroll;
                                        const req = protocol.Request{ .scroll_mode_start = {} };
                                        const req_data = try req.encode(&req_buf);
                                        try stream.write(req_data, sock_fd);
                                        continue;
                                    },

                                    // Copy mode
                                    'c' => {
                                        mode = .copy;
                                        const req = protocol.Request{ .copy_mode_start = {} };
                                        const req_data = try req.encode(&req_buf);
                                        try stream.write(req_data, sock_fd);
                                        continue;
                                    },

                                    // Paste
                                    'p' => maybe_req = .{ .paste = {} },

                                    // Quit
                                    'q' => {
                                        const req = protocol.Request{ .detach = {} };
                                        const req_data = try req.encode(&req_buf);
                                        try stream.write(req_data, sock_fd);

                                        break :outer;
                                    },

                                    // Unknown key also cancels prefix mode
                                    else => {},
                                }

                                // Send the request if any
                                if (maybe_req) |req| {
                                    const req_data = try req.encode(&req_buf);
                                    try stream.write(req_data, sock_fd);
                                }

                                // Update mode
                                if (stay_in_prefix) {
                                    mode = .prefix_repeatable;
                                } else {
                                    // Exit prefix mode and notify server
                                    mode = .normal;
                                    const prefix_off_req = protocol.Request{ .set_prefix_mode = .{ .enabled = false } };
                                    const prefix_off_data = try prefix_off_req.encode(&req_buf);
                                    try stream.write(prefix_off_data, sock_fd);
                                }
                            },
                            .move_pane => {
                                // Expecting a workspace number 1-9
                                switch (user_input[0]) {
                                    '1'...'9' => |ws_char| {
                                        const req = protocol.Request{ .move_pane_to_workspace = .{ .index = ws_char - '1' } };
                                        const req_data = try req.encode(&req_buf);
                                        try stream.write(req_data, sock_fd);
                                    },
                                    else => {},
                                }
                                // Exit to normal mode and turn off prefix
                                mode = .normal;
                                const prefix_off_req = protocol.Request{ .set_prefix_mode = .{ .enabled = false } };
                                const prefix_off_data = try prefix_off_req.encode(&req_buf);
                                try stream.write(prefix_off_data, sock_fd);
                            },
                            .scroll => {
                                var maybe_req: ?protocol.Request = null;

                                // Check for mouse scroll first
                                if (parseSgrMouse(user_input)) |mouse| {
                                    if (!mouse.event.is_release) {
                                        switch (mouse.event.button) {
                                            MouseEvent.WHEEL_UP => maybe_req = .{ .scroll_mode_input = .{ .key = .scroll_up } },
                                            MouseEvent.WHEEL_DOWN => maybe_req = .{ .scroll_mode_input = .{ .key = .scroll_down } },
                                            else => {},
                                        }
                                    }
                                } else switch (user_input[0]) {
                                    // Scroll navigation
                                    'j' => maybe_req = .{ .scroll_mode_input = .{ .key = .scroll_down } },
                                    'k' => maybe_req = .{ .scroll_mode_input = .{ .key = .scroll_up } },

                                    // Half page scroll (Ctrl-u, Ctrl-d)
                                    0x15 => maybe_req = .{ .scroll_mode_input = .{ .key = .half_page_up } }, // Ctrl-u
                                    0x04 => maybe_req = .{ .scroll_mode_input = .{ .key = .half_page_down } }, // Ctrl-d

                                    // Exit scroll mode
                                    '\r' => {
                                        mode = .normal;
                                        maybe_req = .{ .scroll_mode_exit = {} };
                                    },
                                    0x1b => { // Escape
                                        mode = .normal;
                                        maybe_req = .{ .scroll_mode_exit = {} };
                                    },
                                    'q' => {
                                        mode = .normal;
                                        maybe_req = .{ .scroll_mode_exit = {} };
                                    },

                                    else => {},
                                }

                                if (maybe_req) |req| {
                                    const req_data = try req.encode(&req_buf);
                                    try stream.write(req_data, sock_fd);
                                }
                            },
                            .copy => {
                                var maybe_req: ?protocol.Request = null;
                                var exit_copy = false;

                                // Check for mouse wheel events (scrolling only)
                                if (parseSgrMouse(user_input)) |mouse| {
                                    if (!mouse.event.is_release) {
                                        switch (mouse.event.button) {
                                            MouseEvent.WHEEL_UP => {
                                                maybe_req = .{ .copy_mode_input = .{ .key = .half_page_up } };
                                            },
                                            MouseEvent.WHEEL_DOWN => {
                                                maybe_req = .{ .copy_mode_input = .{ .key = .half_page_down } };
                                            },
                                            else => {},
                                        }
                                    }
                                } else if (user_input.len == 1) {
                                    switch (user_input[0]) {
                                        // Movement
                                        'h' => maybe_req = .{ .copy_mode_input = .{ .key = .move_left } },
                                        'j' => maybe_req = .{ .copy_mode_input = .{ .key = .move_down } },
                                        'k' => maybe_req = .{ .copy_mode_input = .{ .key = .move_up } },
                                        'l' => maybe_req = .{ .copy_mode_input = .{ .key = .move_right } },

                                        // Word movement
                                        'w' => maybe_req = .{ .copy_mode_input = .{ .key = .next_word } },
                                        'b' => maybe_req = .{ .copy_mode_input = .{ .key = .prev_word } },

                                        // Line movement
                                        '0' => maybe_req = .{ .copy_mode_input = .{ .key = .begin_of_line } },
                                        '$' => maybe_req = .{ .copy_mode_input = .{ .key = .end_of_line } },

                                        // Screen movement
                                        'g' => maybe_req = .{ .copy_mode_input = .{ .key = .top_of_screen } },
                                        'G' => maybe_req = .{ .copy_mode_input = .{ .key = .bottom_of_screen } },

                                        // Half page movement (Ctrl-u, Ctrl-d)
                                        0x15 => maybe_req = .{ .copy_mode_input = .{ .key = .half_page_up } }, // Ctrl-u
                                        0x04 => maybe_req = .{ .copy_mode_input = .{ .key = .half_page_down } }, // Ctrl-d

                                        // Selection
                                        'v' => maybe_req = .{ .copy_mode_input = .{ .key = .start_selection } },

                                        // Yank (y or Ctrl+C) - copy and exit
                                        'y', 0x03 => {
                                            maybe_req = .{ .clipboard_copy = {} };
                                            exit_copy = true;
                                        },

                                        // Exit copy mode
                                        'q' => {
                                            maybe_req = .{ .copy_mode_exit = {} };
                                            exit_copy = true;
                                        },
                                        0x1b => { // Escape
                                            maybe_req = .{ .copy_mode_exit = {} };
                                            exit_copy = true;
                                        },

                                        else => {},
                                    }
                                }

                                if (maybe_req) |req| {
                                    const req_data = try req.encode(&req_buf);
                                    try stream.write(req_data, sock_fd);
                                }

                                if (exit_copy) {
                                    mode = .normal;
                                }
                            },
                        }
                    },
                    else => {},
                },
            }
        }
    }

    // Disable mouse reporting and clear screen on exit
    try stdout.writeAll("\x1b[?1006l\x1b[?1000l\x1b[2J\x1b[H");
    try stdout.flush();
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Mouse event types
const MouseEvent = struct {
    button: u8,
    x: u16,
    y: u16,
    is_release: bool,

    /// Mouse button codes
    const WHEEL_UP = 64;
    const WHEEL_DOWN = 65;
};

/// Parse SGR mouse escape sequence: \x1b[<Btn;X;Y;M or \x1b[<Btn;X;Y;m
/// Returns the parsed mouse event and the number of bytes consumed, or null if not a valid mouse sequence
fn parseSgrMouse(input: []const u8) ?struct { event: MouseEvent, len: usize } {
    // Minimum: \x1b[<0;1;1M = 9 bytes
    if (input.len < 9) return null;

    // Check for SGR mouse prefix: \x1b[<
    if (input[0] != 0x1b or input[1] != '[' or input[2] != '<') return null;

    // Parse button;x;y
    var i: usize = 3;
    var numbers: [3]u16 = .{ 0, 0, 0 };
    var num_idx: usize = 0;

    while (i < input.len and num_idx < 3) {
        const ch = input[i];
        if (ch >= '0' and ch <= '9') {
            numbers[num_idx] = numbers[num_idx] * 10 + (ch - '0');
            i += 1;
        } else if (ch == ';') {
            num_idx += 1;
            i += 1;
        } else if (ch == 'M' or ch == 'm') {
            // End of sequence
            if (num_idx != 2) return null; // Need exactly 3 numbers
            return .{
                .event = .{
                    .button = @intCast(numbers[0]),
                    .x = numbers[1],
                    .y = numbers[2],
                    .is_release = (ch == 'm'),
                },
                .len = i + 1,
            };
        } else {
            return null; // Invalid character
        }
    }

    return null;
}
