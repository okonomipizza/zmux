const std = @import("std");

pub const SessionName = []const u8;

/// Direction for pane operations
pub const Direction = enum(u8) {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
};

/// Split direction for pane splitting
pub const SplitDirection = enum(u8) {
    vertical = 0,
    horizontal = 1,
};

pub const Request = union(enum) {
    attach: Attach,
    detach: Detach,
    input: Input,
    resize: Resize,
    split_pane: SplitPane,
    focus_pane: FocusPane,
    close_pane: void,
    new_workspace: void,
    switch_workspace: SwitchWorkspace,
    toggle_floating: void,
    set_prefix_mode: SetPrefixMode,
    // New request types for scroll/copy mode and pane operations
    scroll_mode_start: void,
    scroll_mode_input: ScrollModeInput,
    scroll_mode_exit: void,
    copy_mode_start: void,
    copy_mode_input: CopyModeInput,
    copy_mode_exit: void,
    yank: void,
    paste: void,
    swap_pane: SwapPane,
    resize_pane: ResizePane,
    move_pane_to_workspace: MovePaneToWorkspace,
    cycle_workspace: CycleWorkspace,

    pub const Method = enum(u8) {
        attach = 0,
        detach = 1,
        input = 2,
        resize = 3,
        split_pane = 4,
        focus_pane = 5,
        close_pane = 6,
        new_workspace = 7,
        switch_workspace = 8,
        toggle_floating = 9,
        set_prefix_mode = 10,
        scroll_mode_start = 11,
        scroll_mode_input = 12,
        scroll_mode_exit = 13,
        copy_mode_start = 14,
        copy_mode_input = 15,
        copy_mode_exit = 16,
        yank = 17,
        paste = 18,
        swap_pane = 19,
        resize_pane = 20,
        move_pane_to_workspace = 21,
        cycle_workspace = 22,
    };

    const Attach = struct {
        session_name: []const u8,
        cols: u16,
        rows: u16,
    };

    const Detach = struct {
        session_name: []const u8,
    };

    const Input = struct {
        input: []const u8,
    };

    const Resize = struct {
        cols: u16,
        rows: u16,
    };

    const SplitPane = struct {
        direction: SplitDirection,
    };

    const FocusPane = struct {
        direction: Direction,
    };

    const SwitchWorkspace = struct {
        index: usize,
    };

    const SetPrefixMode = struct {
        enabled: bool,
    };

    const ScrollModeInput = struct {
        key: ScrollKey,

        pub const ScrollKey = enum(u8) {
            scroll_up = 0,
            scroll_down = 1,
            half_page_up = 2,
            half_page_down = 3,
        };
    };

    const CopyModeInput = struct {
        key: CopyKey,

        pub const CopyKey = enum(u8) {
            move_left = 0,
            move_right = 1,
            move_up = 2,
            move_down = 3,
            next_word = 4,
            prev_word = 5,
            begin_of_line = 6,
            end_of_line = 7,
            top_of_screen = 8,
            bottom_of_screen = 9,
            half_page_up = 10,
            half_page_down = 11,
            start_selection = 12,
        };
    };

    const SwapPane = struct {
        direction: Direction,
    };

    const ResizePane = struct {
        grow: bool, // true = grow ('>'), false = shrink ('<')
    };

    const MovePaneToWorkspace = struct {
        index: usize,
    };

    const CycleWorkspace = struct {
        next: bool, // true = next (i), false = prev (u)
    };

    pub fn decode(src: []const u8) !Request {
        if (src.len < 1) return error.TooShort;
        const method = std.enums.fromInt(Method, src[0]) orelse return error.InvalidMethod;

        switch (method) {
            .attach => {
                if (src.len < 5) return error.TooShort;
                const cols = std.mem.readInt(u16, src[1..3], .little);
                const rows = std.mem.readInt(u16, src[3..5], .little);
                return .{ .attach = .{
                    .session_name = src[5..],
                    .cols = cols,
                    .rows = rows,
                } };
            },
            .detach => return .{ .detach = .{ .session_name = src[1..] } },
            .input => return .{ .input = .{ .input = src[1..] } },
            .resize => {
                if (src.len < 5) return error.TooShort;
                const cols = std.mem.readInt(u16, src[1..3], .little);
                const rows = std.mem.readInt(u16, src[3..5], .little);
                return .{ .resize = .{ .cols = cols, .rows = rows } };
            },
            .split_pane => {
                if (src.len < 2) return error.TooShort;
                const dir = std.enums.fromInt(SplitDirection, src[1]) orelse return error.InvalidDirection;
                return .{ .split_pane = .{ .direction = dir } };
            },
            .focus_pane => {
                if (src.len < 2) return error.TooShort;
                const dir = std.enums.fromInt(Direction, src[1]) orelse return error.InvalidDirection;
                return .{ .focus_pane = .{ .direction = dir } };
            },
            .close_pane => return .{ .close_pane = {} },
            .new_workspace => return .{ .new_workspace = {} },
            .switch_workspace => {
                if (src.len < 2) return error.TooShort;
                return .{ .switch_workspace = .{ .index = src[1] } };
            },
            .toggle_floating => return .{ .toggle_floating = {} },
            .set_prefix_mode => {
                if (src.len < 2) return error.TooShort;
                return .{ .set_prefix_mode = .{ .enabled = src[1] == 0 } };
            },
            .scroll_mode_start => return .{ .scroll_mode_start = {} },
            .scroll_mode_input => {
                if (src.len < 2) return error.TooShort;
                const key = std.enums.fromInt(ScrollModeInput.ScrollKey, src[1]) orelse return error.InvalidKey;
                return .{ .scroll_mode_input = .{ .key = key } };
            },
            .scroll_mode_exit => return .{ .scroll_mode_exit = {} },
            .copy_mode_start => return .{ .copy_mode_start = {} },
            .copy_mode_input => {
                if (src.len < 2) return error.TooShort;
                const key = std.enums.fromInt(CopyModeInput.CopyKey, src[1]) orelse return error.InvalidKey;
                return .{ .copy_mode_input = .{ .key = key } };
            },
            .copy_mode_exit => return .{ .copy_mode_exit = {} },
            .yank => return .{ .yank = {} },
            .paste => return .{ .paste = {} },
            .swap_pane => {
                if (src.len < 2) return error.TooShort;
                const dir = std.enums.fromInt(Direction, src[1]) orelse return error.InvalidDirection;
                return .{ .swap_pane = .{ .direction = dir } };
            },
            .resize_pane => {
                if (src.len < 2) return error.TooShort;
                return .{ .resize_pane = .{ .grow = src[1] != 0 } };
            },
            .move_pane_to_workspace => {
                if (src.len < 2) return error.TooShort;
                return .{ .move_pane_to_workspace = .{ .index = src[1] } };
            },
            .cycle_workspace => {
                if (src.len < 2) return error.TooShort;
                return .{ .cycle_workspace = .{ .next = src[1] != 0 } };
            },
        }
    }

    /// Encode a Request into a buffer for sending over the wire.
    /// Format: [method_byte][payload...]
    /// Returns the slice of the buffer that was written to.
    pub fn encode(self: Request, buf: []u8) ![]u8 {
        switch (self) {
            .attach => |a| {
                const needed = 5 + a.session_name.len;
                if (buf.len < needed) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.attach);
                std.mem.writeInt(u16, buf[1..3], a.cols, .little);
                std.mem.writeInt(u16, buf[3..5], a.rows, .little);
                @memcpy(buf[5..][0..a.session_name.len], a.session_name);
                return buf[0..needed];
            },
            .detach => |d| {
                if (buf.len < 1 + d.session_name.len) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.detach);
                @memcpy(buf[1..][0..d.session_name.len], d.session_name);
                return buf[0 .. 1 + d.session_name.len];
            },
            .input => |i| {
                if (buf.len < 1 + i.input.len) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.input);
                @memcpy(buf[1..][0..i.input.len], i.input);
                return buf[0 .. 1 + i.input.len];
            },
            .resize => |r| {
                if (buf.len < 5) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.resize);
                std.mem.writeInt(u16, buf[1..3], r.cols, .little);
                std.mem.writeInt(u16, buf[3..5], r.rows, .little);
                return buf[0..5];
            },
            .split_pane => |s| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.split_pane);
                buf[1] = @intFromEnum(s.direction);
                return buf[0..2];
            },
            .focus_pane => |f| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.focus_pane);
                buf[1] = @intFromEnum(f.direction);
                return buf[0..2];
            },
            .close_pane => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.close_pane);
                return buf[0..1];
            },
            .new_workspace => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.new_workspace);
                return buf[0..1];
            },
            .switch_workspace => |s| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.switch_workspace);
                buf[1] = @intCast(s.index);
                return buf[0..2];
            },
            .toggle_floating => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.toggle_floating);
                return buf[0..1];
            },
            .set_prefix_mode => |b| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.set_prefix_mode);
                buf[1] = if (b.enabled) 0 else 1;
                return buf[0..2];
            },
            .scroll_mode_start => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.scroll_mode_start);
                return buf[0..1];
            },
            .scroll_mode_input => |s| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.scroll_mode_input);
                buf[1] = @intFromEnum(s.key);
                return buf[0..2];
            },
            .scroll_mode_exit => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.scroll_mode_exit);
                return buf[0..1];
            },
            .copy_mode_start => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.copy_mode_start);
                return buf[0..1];
            },
            .copy_mode_input => |cm| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.copy_mode_input);
                buf[1] = @intFromEnum(cm.key);
                return buf[0..2];
            },
            .copy_mode_exit => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.copy_mode_exit);
                return buf[0..1];
            },
            .yank => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.yank);
                return buf[0..1];
            },
            .paste => {
                if (buf.len < 1) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.paste);
                return buf[0..1];
            },
            .swap_pane => |s| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.swap_pane);
                buf[1] = @intFromEnum(s.direction);
                return buf[0..2];
            },
            .resize_pane => |r| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.resize_pane);
                buf[1] = if (r.grow) 1 else 0;
                return buf[0..2];
            },
            .move_pane_to_workspace => |m| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.move_pane_to_workspace);
                buf[1] = @intCast(m.index);
                return buf[0..2];
            },
            .cycle_workspace => |c| {
                if (buf.len < 2) return error.BufferTooSmall;
                buf[0] = @intFromEnum(Method.cycle_workspace);
                buf[1] = if (c.next) 1 else 0;
                return buf[0..2];
            },
        }
    }
};

pub const Response = union(enum) {
    attach_ok: AttachOk,
    message: []const u8,
    err: []const u8,

    const ResponseType = enum(u8) {
        attach_ok = 0,
        message = 1,
        err = 2,
    };

    const AttachOk = struct {
        cols: u16,
        rows: u16,
    };

    pub fn decode(src: []const u8) !Response {
        if (src.len < 1) return error.TooShort;

        const response_type = std.enums.fromInt(ResponseType, src[0]) orelse return error.InvalidResponseType;

        switch (response_type) {
            .attach_ok => {
                if (src.len < 5) return error.TooShort;
                const cols = std.mem.readInt(u16, src[1..3], .little);
                const rows = std.mem.readInt(u16, src[3..5], .little);
                return .{ .attach_ok = .{ .cols = cols, .rows = rows } };
            },
            .message => return .{ .message = src[1..] },
            .err => return .{ .err = src[1..] },
        }
    }

    pub fn encode(self: Response, buf: []u8) ![]u8 {
        switch (self) {
            .attach_ok => |a| {
                if (buf.len < 5) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ResponseType.attach_ok);
                std.mem.writeInt(u16, buf[1..3], a.cols, .little);
                std.mem.writeInt(u16, buf[3..5], a.rows, .little);
                return buf[0..5];
            },
            .message => |m| {
                if (buf.len < 1 + m.len) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ResponseType.message);
                @memcpy(buf[1..][0..m.len], m);
                return buf[0 .. 1 + m.len];
            },
            .err => |e| {
                if (buf.len < 1 + e.len) return error.BufferTooSmall;
                buf[0] = @intFromEnum(ResponseType.err);
                @memcpy(buf[1..][0..e.len], e);
                return buf[0 .. 1 + e.len];
            },
        }
    }
};
