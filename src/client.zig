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

pub fn client(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    _ = allocator;

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

    // Clear screen on start
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\x1b[2J\x1b[H");
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
                        // Check for prefix key (Ctrl-b = 0x02)
                        if (user_input.len == 1 and user_input[0] == 0x02) {
                            mode = .prefix;
                            // Notify server that prefix mode is active
                            const prefix_req = protocol.Request{ .set_prefix_mode = .{ .enabled = true } };
                            const prefix_data = try prefix_req.encode(&req_buf);
                            try stream.write(prefix_data, sock_fd);
                            continue;
                        }

                        // Forward input to server
                        const input_req = protocol.Request{ .input = .{ .input = user_input } };
                        const req_data = try input_req.encode(&req_buf);
                        try stream.write(req_data, sock_fd);
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
                            'q' => break :outer,

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

                        switch (user_input[0]) {
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

                        // Check for Ctrl-u (0x15) and Ctrl-d (0x04)
                        if (user_input.len == 1) {
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

                                // Yank
                                'y' => {
                                    maybe_req = .{ .yank = {} };
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

    // Clear screen on exit
    try stdout.writeAll("\x1b[2J\x1b[H");
    try stdout.flush();
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    _ = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    return .{ .cols = ws.col, .rows = ws.row };
}
