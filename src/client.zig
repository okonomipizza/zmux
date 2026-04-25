const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("c.zig").c;
const Stream = @import("Stream.zig").Stream;
const protocol = @import("protocol.zig");

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

/// Setup signalfd for SIGWINCH to detect terminal resize
fn setupSignalFd() !posix.fd_t {
    var mask: linux.sigset_t = .{0};
    linux.sigaddset(&mask, linux.SIG.WINCH);

    // Block SIGWINCH so it's delivered via signalfd
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);

    const fd = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    if (@as(isize, @bitCast(fd)) < 0) {
        return error.SignalFdFailed;
    }
    return @intCast(fd);
}

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
    @memcpy(addr.path[0..socket_path.len], socket_path);
    try posix.connect(sock_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    try enableRawMode(&original_termios);
    defer disableRawMode(&original_termios);

    // Setup signalfd for SIGWINCH (terminal resize)
    const signal_fd = try setupSignalFd();
    defer posix.close(signal_fd);

    // Clear screen on start and enable mouse reporting (SGR mode)
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Clear screen + enable mouse tracking (1000) + SGR extended mode (1006)
    // 1000 = track button press/release (including wheel)
    try stdout.writeAll("\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006h");
    try stdout.flush();

    const epoll_fd = try posix.epoll_create1(0);
    defer posix.close(epoll_fd);

    var stdin_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = stdin_fd },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, stdin_fd, &stdin_event);

    var sock_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = sock_fd },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, sock_fd, &sock_event);

    var signal_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = signal_fd },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, signal_fd, &signal_event);

    var events: [10]linux.epoll_event = undefined;

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
        const n_events = posix.epoll_wait(epoll_fd, &events, -1);

        for (events[0..n_events]) |ev| {
            const fd = ev.data.fd;

            if (fd == signal_fd) {
                // Handle SIGWINCH - terminal resize
                var siginfo: linux.signalfd_siginfo = undefined;
                _ = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch continue;

                // Get new terminal size
                const new_size = getTermSize();
                if (new_size.cols != term_size.cols or new_size.rows != term_size.rows) {
                    term_size = new_size;

                    // Send resize request to server
                    var resize_buf: [256]u8 = undefined;
                    const resize_req = protocol.Request{ .resize = .{
                        .cols = new_size.cols,
                        .rows = new_size.rows,
                    } };
                    const resize_data = try resize_req.encode(&resize_buf);
                    try stream.write(resize_data, sock_fd);
                }
            } else if (fd == stdin_fd) {
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
                        const was_repeatable = (mode == .prefix_repeatable);
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
                        } else if (!was_repeatable or !stay_in_prefix) {
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
            } else if (fd == sock_fd) {
                // Read available data from socket into buffer
                stream.receiveData(sock_fd) catch |err| {
                    if (err == error.Closed) break :outer;
                    return err;
                };

                // Process all complete messages in the buffer
                while (stream.nextMessage()) |output| {
                    try stdout.writeAll(output);
                    try stdout.flush();
                }
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

/// Check if input looks like the start of an SGR mouse sequence
/// Used to drop incomplete/partial mouse sequences
fn isSgrMousePrefix(input: []const u8) bool {
    if (input.len == 0) return false;
    if (input[0] != 0x1b) return false;
    if (input.len == 1) return true; // Just ESC, could be start of mouse seq
    if (input[1] != '[') return false;
    if (input.len == 2) return true; // ESC [
    if (input[2] != '<') return false;
    // Starts with \x1b[< - definitely a mouse sequence (or similar CSI)
    return true;
}

/// Check if input looks like the middle/end of a mouse sequence
/// Pattern: digits and semicolons ending with 'M' or 'm'
/// e.g., "4;32;42M" or "32;42M64;33;42M"
fn looksLikeMouseSequenceFragment(input: []const u8) bool {
    if (input.len == 0) return false;

    // Must contain 'M' or 'm' (mouse sequence terminator)
    var has_terminator = false;
    var has_semicolon = false;
    var has_digit = false;

    for (input) |ch| {
        if (ch == 'M' or ch == 'm') {
            has_terminator = true;
        } else if (ch == ';') {
            has_semicolon = true;
        } else if (ch >= '0' and ch <= '9') {
            has_digit = true;
        } else if (ch == 0x1b or ch == '[' or ch == '<') {
            // These are valid mouse sequence chars, continue
        } else {
            // Contains other characters - probably not a mouse fragment
            return false;
        }
    }

    // Looks like a mouse fragment if it has terminator with digits and semicolons
    return has_terminator and has_semicolon and has_digit;
}

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
