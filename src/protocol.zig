//! The message set the client and server exchange, and its encoding.
//!
//! Each message is one frame (see `socket.zig`). The payload's first byte is
//! the tag and the rest is the body. Everything is little-endian, matching the
//! host, because zmux only supports x86_64 for now.
//!
//! The split between the two directions is deliberate. A client sends
//! *requests*: list, create, attach, detach, kill, input, resize. The server
//! sends *events*: here is a session, here is output, the session ended. The
//! server forwards the pty's bytes unchanged and the client parses them with
//! its own libghostty-vt terminal, so the server never needs to know a client's
//! screen size and a slow client only falls behind itself.

const std = @import("std");

pub const Error = error{
    /// The tag is not one this version knows.
    UnknownTag,
    /// The body is the wrong size for its tag, or a declared length runs past
    /// the end of the message.
    BadLength,
    /// A string field held a value that is not a valid session name.
    BadValue,
};

/// Maximum bytes in a session name.
pub const name_max = 64;

/// A session name.
///
/// Names are the user's handle for a session, so they are restricted to
/// something that cannot be mistaken for an argument or a path. The limit is
/// small because the name travels in every listing entry.
pub const Name = struct {
    bytes: [name_max]u8 = [_]u8{0} ** name_max,
    len: u8 = 0,

    pub fn init(text: []const u8) Error!Name {
        if (text.len == 0 or text.len > name_max) return Error.BadValue;
        for (text) |byte| {
            const allowed = std.ascii.isAlphanumeric(byte) or
                byte == '-' or byte == '_' or byte == '.';
            if (!allowed) return Error.BadValue;
        }
        var name: Name = .{};
        @memcpy(name.bytes[0..text.len], text);
        name.len = @intCast(text.len);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

/// What the client is asking the server to do.
pub const Request = union(enum) {
    /// List the live sessions.
    list,
    /// Start a new session running the given program.
    create: struct {
        name: Name,
        rows: u16,
        cols: u16,
        /// The program and its arguments, separated by NUL. Empty means the
        /// server's own `$SHELL`.
        program: []const u8,
    },
    /// Attach to a session. The size is this client's terminal.
    attach: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
    /// Stop receiving a session's output without ending the session.
    detach: struct {
        name: Name,
    },
    /// Terminate a session and its program.
    kill: struct {
        name: Name,
    },
    /// Terminate every session.
    kill_all,
    /// Keystrokes destined for one pane of the attached session.
    ///
    /// The pane identifier is carried rather than taken from focus, because the two
    /// can differ: a keystroke already in flight when focus moves must reach the pane
    /// the user was typing into, not whichever pane is focused by the time the server
    /// reads it.
    input: struct {
        name: Name,
        pane: u64,
        data: []const u8,
    },
    /// The client's terminal changed size.
    resize: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
    /// Divide the focused pane, starting a new program in the new half.
    split: struct {
        name: Name,
        /// 0 for a side-by-side split, 1 for a stacked one. A number rather than
        /// an enum because this is a wire value.
        axis: u8,
        /// The program for the new pane, NUL-separated. Empty means `$SHELL`.
        program: []const u8,
    },
    /// Close the focused pane, ending its program.
    close: struct {
        name: Name,
    },
    /// Move focus within the session. `backwards` reverses the direction.
    focus: struct {
        name: Name,
        backwards: bool,
    },
    /// Park the focused pane, lifting it out of the layout and above it.
    ///
    /// The pane keeps its pty and its screen: parking changes which list owns it and nothing
    /// else, so the program inside never notices. The space it leaves is handed to a
    /// neighbour, which is why a parked pane does not leave a hole.
    float: struct {
        name: Name,
    },
    /// Put a floating pane back into the layout.
    ///
    /// Without a target the server enters dock-select mode, freezing the layout and labelling
    /// the tiled panes so the user can choose; `dock` with a target does the move. Splitting
    /// along the chosen pane's longer side is what keeps the two halves roughly square.
    dock: struct {
        name: Name,
        /// The tiled pane to split, or zero to begin choosing one.
        target: u64,
    },
    /// Leave dock-select mode without moving anything.
    dock_cancel: struct {
        name: Name,
    },
    /// Hide the floating panes, or show them again.
    ///
    /// One request for both directions, because the server already knows which state it is in.
    /// Sending "hide" or "show" separately would mean the client tracking a fact it does not own.
    toggle_floats: struct {
        name: Name,
    },
};

/// Where one pane sits in the session's area, in cells.
///
/// Absolute and zero-based, matching `layout.Rect`. The server computes these
/// because it owns the tree; the client only paints into them, which is what keeps
/// the two sides from disagreeing about geometry.
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    /// The part of a pane its program is given, once the frame is taken off.
    ///
    /// The frame is one cell thick on every side, so the interior starts one in and is two narrower
    /// and two shorter. It lives here, on the type both sides use, because the server sizes the pty
    /// by it and the client draws the program's cells inside it; one implementation is what keeps
    /// them from disagreeing, and disagreement is a pane whose text wraps in the wrong place.
    ///
    /// A rectangle too small to hold a frame and any content is returned untouched, so that a tiny
    /// pane gets no border rather than a zero-sized terminal that libghostty-vt rejects.
    pub fn interior(self: Rect) Rect {
        if (self.width < 3 or self.height < 3) return self;
        return .{
            .x = self.x + 1,
            .y = self.y + 1,
            .width = self.width - 2,
            .height = self.height - 2,
        };
    }
};

/// One session, as it appears in a listing.
pub const SessionInfo = struct {
    name: Name,
    rows: u16,
    cols: u16,
    /// How many clients are currently attached.
    clients: u8,
    /// The child's pid, for display only.
    pid: i32,
    /// Whether the child is still running.
    running: bool,
};

/// What the server is telling the client.
pub const Event = union(enum) {
    /// One entry in a listing.
    session: SessionInfo,
    /// The listing is complete.
    list_end,
    /// The attach succeeded; output for this session starts here.
    attached: struct {
        name: Name,
        rows: u16,
        cols: u16,
    },
    /// The detach succeeded; output for this session stops here.
    detached: struct {
        name: Name,
    },
    /// A session was created.
    created: struct {
        name: Name,
    },
    /// The session is gone. Sent to every client watching it.
    exited: struct {
        name: Name,
        /// The exit status, or 128 + signal when the program was signalled.
        status: u8,
    },
    /// Output from one pane's program, exactly as it left the pty.
    ///
    /// Tagged with the pane rather than with the session, because a session may hold
    /// several programs and each has its own screen. The client keeps one terminal
    /// per pane and feeds the bytes to the right one.
    output: struct {
        name: Name,
        pane: u64,
        data: []const u8,
    },
    /// The session's panes and their geometry, sent whenever the layout changes.
    ///
    /// This is the whole layout rather than a delta, because the client's job is to draw
    /// the current arrangement and a delta would let it drift from the server's tree with
    /// no way to notice. The list is empty when the session has no panes left.
    layout: Layout,
    /// A request was rejected, or a listing is empty.
    failure: struct {
        message: []const u8,
    },
};

/// The whole arrangement of a session's panes.
pub const Layout = struct {
    name: Name,
    /// The rectangle all the tiled panes share. Floating panes are positioned in absolute
    /// window cells instead and may overlap it.
    area_rows: u16,
    area_cols: u16,
    /// The tiled pane holding focus, or zero when there is none.
    focused: u64,
    /// The floating pane that is on top, or zero when none is raised.
    focused_float: u64,
    /// Set while the user is choosing where to put a floating pane back into the layout.
    ///
    /// In this mode the layout is frozen and every tiled pane carries a label, so the user can
    /// name one. Floating panes are not drawn: the choice is about the layout underneath them,
    /// and a float covering it would hide the labels being read.
    docking: bool,
    /// Set while the floating panes are hidden.
    ///
    /// A hidden float is still a live pane: its program runs and its screen is parsed. It is simply
    /// not drawn, and it does not hold focus, which is why `focused_float` is zero whenever this is
    /// set. The list below omits hidden floats entirely rather than flagging them, so the client
    /// needs no rule for what to do with a pane it must not paint.
    floats_hidden: bool,
    /// Tiled panes first, then floating ones. The order of this list is the z-order, with
    /// later entries drawn on top.
    panes: []const PanePlacement,
};

/// One pane's identity and position within a session.
pub const PanePlacement = struct {
    id: u64,
    /// Window cells. For a tiled pane these come from the tree; for a floating one they are
    /// wherever the float has been put.
    rect: Rect,
    /// Whether the pane's program is still running. A pane whose child has exited keeps its
    /// screen until the pane is closed.
    exited: bool,
    /// Whether this pane floats above the layout rather than being tiled by it.
    ///
    /// Carried explicitly so that the client does not have to infer it from the list order,
    /// which would break as soon as there were two floats or the ordering changed.
    floating: bool,
    /// The number drawn on this pane while a dock target is being chosen, or zero when nothing
    /// is being numbered.
    label: u8,
};

/// Wire tags.
///
/// Spelled out rather than taken from the enum ordinal, because these are the
/// protocol: reordering a union arm must not silently renumber the wire.
pub const Tag = struct {
    // Requests, 1..=15.
    pub const list: u8 = 1;
    pub const create: u8 = 2;
    pub const attach: u8 = 3;
    pub const detach: u8 = 4;
    pub const kill: u8 = 5;
    pub const kill_all: u8 = 6;
    pub const input: u8 = 7;
    pub const resize: u8 = 8;
    pub const split: u8 = 9;
    pub const close: u8 = 10;
    pub const focus: u8 = 11;
    pub const float: u8 = 12;
    pub const dock: u8 = 13;
    pub const dock_cancel: u8 = 14;
    pub const toggle_floats: u8 = 15;
    // Events, 64..=127. The gap leaves room to add either kind later without
    // renumbering.
    pub const session: u8 = 64;
    pub const list_end: u8 = 65;
    pub const attached: u8 = 66;
    pub const detached: u8 = 67;
    pub const created: u8 = 68;
    pub const exited: u8 = 69;
    pub const output: u8 = 70;
    pub const failure: u8 = 71;
    pub const layout: u8 = 72;
};

/// Appends fields to a buffer.
///
/// This builds the *payload* of a frame — the tag and its body — and leaves the
/// length prefix to `socket.encode`, which is the only place that knows about
/// framing. Encoding the prefix here as well would make the payload ambiguous
/// about whether it starts with a tag or a length, which is exactly the bug
/// this comment exists to prevent.
pub const Encoder = struct {
    buffer: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.gpa);
    }

    /// Start a message with the given tag.
    pub fn begin(self: *Encoder, tag: u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.gpa, tag);
    }

    fn u8le(self: *Encoder, value: u8) !void {
        try self.buffer.append(self.gpa, value);
    }

    fn u16le(self: *Encoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    fn i32le(self: *Encoder, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    fn u32le(self: *Encoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    /// Pane identifiers are 64-bit because they are counters that must not wrap
    /// within the life of a session, and a client may hold a stale one.
    fn u64le(self: *Encoder, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
    }

    fn name(self: *Encoder, value: *const Name) !void {
        try self.u8le(value.len);
        try self.buffer.appendSlice(self.gpa, value.slice());
    }

    fn blob(self: *Encoder, value: []const u8) !void {
        if (value.len > std.math.maxInt(u32)) return Error.BadLength;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value.len), .little);
        try self.buffer.appendSlice(self.gpa, &bytes);
        try self.buffer.appendSlice(self.gpa, value);
    }

    /// Complete the current message and return its payload: the tag followed by
    /// the body, without a length prefix.
    ///
    /// The returned slice is valid until the next call that touches the
    /// encoder, so the caller must hand it to `socket.encode` before encoding
    /// anything else.
    pub fn finish(self: *Encoder) ![]const u8 {
        if (self.buffer.items.len == 0) return Error.BadLength;
        return self.buffer.items;
    }

    pub fn writeRequest(self: *Encoder, request: Request) ![]const u8 {
        switch (request) {
            .list => try self.begin(Tag.list),
            .kill_all => try self.begin(Tag.kill_all),
            .create => |create| {
                try self.begin(Tag.create);
                try self.name(&create.name);
                try self.u16le(create.rows);
                try self.u16le(create.cols);
                try self.blob(create.program);
            },
            .attach => |attach| {
                try self.begin(Tag.attach);
                try self.name(&attach.name);
                try self.u16le(attach.rows);
                try self.u16le(attach.cols);
            },
            .detach => |detach| {
                try self.begin(Tag.detach);
                try self.name(&detach.name);
            },
            .kill => |kill| {
                try self.begin(Tag.kill);
                try self.name(&kill.name);
            },
            .input => |input| {
                try self.begin(Tag.input);
                try self.name(&input.name);
                try self.u64le(input.pane);
                try self.blob(input.data);
            },
            .resize => |resize| {
                try self.begin(Tag.resize);
                try self.name(&resize.name);
                try self.u16le(resize.rows);
                try self.u16le(resize.cols);
            },
            .split => |split| {
                try self.begin(Tag.split);
                try self.name(&split.name);
                try self.u8le(split.axis);
                try self.blob(split.program);
            },
            .close => |close| {
                try self.begin(Tag.close);
                try self.name(&close.name);
            },
            .focus => |focus| {
                try self.begin(Tag.focus);
                try self.name(&focus.name);
                try self.u8le(if (focus.backwards) 1 else 0);
            },
            .float => |float| {
                try self.begin(Tag.float);
                try self.name(&float.name);
            },
            .dock => |dock| {
                try self.begin(Tag.dock);
                try self.name(&dock.name);
                try self.u64le(dock.target);
            },
            .dock_cancel => |cancel| {
                try self.begin(Tag.dock_cancel);
                try self.name(&cancel.name);
            },
            .toggle_floats => |toggle| {
                try self.begin(Tag.toggle_floats);
                try self.name(&toggle.name);
            },
        }
        return self.finish();
    }

    pub fn writeEvent(self: *Encoder, event: Event) ![]const u8 {
        switch (event) {
            .list_end => try self.begin(Tag.list_end),
            .session => |info| {
                try self.begin(Tag.session);
                try self.name(&info.name);
                try self.u16le(info.rows);
                try self.u16le(info.cols);
                try self.u8le(info.clients);
                try self.i32le(info.pid);
                try self.u8le(if (info.running) 1 else 0);
            },
            .attached => |attached| {
                try self.begin(Tag.attached);
                try self.name(&attached.name);
                try self.u16le(attached.rows);
                try self.u16le(attached.cols);
            },
            .detached => |detached| {
                try self.begin(Tag.detached);
                try self.name(&detached.name);
            },
            .created => |created| {
                try self.begin(Tag.created);
                try self.name(&created.name);
            },
            .exited => |exited| {
                try self.begin(Tag.exited);
                try self.name(&exited.name);
                try self.u8le(exited.status);
            },
            .output => |output| {
                // The pane identifier precedes the payload so that a client can
                // dispatch the bytes before looking at them.
                try self.begin(Tag.output);
                try self.name(&output.name);
                try self.u64le(output.pane);
                try self.blob(output.data);
            },
            .layout => |layout| {
                try self.begin(Tag.layout);
                try self.name(&layout.name);
                try self.u16le(layout.area_rows);
                try self.u16le(layout.area_cols);
                try self.u64le(layout.focused);
                try self.u64le(layout.focused_float);
                try self.u8le(if (layout.docking) 1 else 0);
                try self.u8le(if (layout.floats_hidden) 1 else 0);
                if (layout.panes.len > std.math.maxInt(u16)) return Error.BadLength;
                try self.u16le(@intCast(layout.panes.len));
                for (layout.panes) |placement| {
                    try self.u64le(placement.id);
                    try self.u16le(placement.rect.x);
                    try self.u16le(placement.rect.y);
                    try self.u16le(placement.rect.width);
                    try self.u16le(placement.rect.height);
                    try self.u8le(if (placement.exited) 1 else 0);
                    try self.u8le(if (placement.floating) 1 else 0);
                    try self.u8le(placement.label);
                }
            },
            .failure => |failure| {
                try self.begin(Tag.failure);
                try self.blob(failure.message);
            },
        }
        return self.finish();
    }
};

/// Reads fields out of a decoded frame payload.
///
/// The payload is borrowed from the frame reader's buffer, so the slices this
/// returns into it are valid only until the next frame is read. Every field is
/// bounds-checked against the message length, because the bytes come from
/// another process.
pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,
    /// Storage for a decoded `layout` event's placements.
    ///
    /// The decoder does not allocate, so the room comes from here. A layout message
    /// carrying more panes than this is rejected rather than truncated; the bound
    /// matches the tree's own limit on how many panes it will navigate.
    placements: [max_panes]PanePlacement = undefined,

    pub const max_panes = 256;

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    pub fn tag(self: Decoder) Error!u8 {
        if (self.bytes.len == 0) return Error.BadLength;
        return self.bytes[0];
    }

    fn u8le(self: *Decoder) Error!u8 {
        if (self.offset + 1 > self.bytes.len) return Error.BadLength;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn u16le(self: *Decoder) Error!u16 {
        if (self.offset + 2 > self.bytes.len) return Error.BadLength;
        defer self.offset += 2;
        return std.mem.readInt(u16, self.bytes[self.offset..][0..2], .little);
    }

    fn i32le(self: *Decoder) Error!i32 {
        if (self.offset + 4 > self.bytes.len) return Error.BadLength;
        defer self.offset += 4;
        return std.mem.readInt(i32, self.bytes[self.offset..][0..4], .little);
    }

    fn u32le(self: *Decoder) Error!u32 {
        if (self.offset + 4 > self.bytes.len) return Error.BadLength;
        defer self.offset += 4;
        return std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
    }

    fn u64le(self: *Decoder) Error!u64 {
        if (self.offset + 8 > self.bytes.len) return Error.BadLength;
        defer self.offset += 8;
        return std.mem.readInt(u64, self.bytes[self.offset..][0..8], .little);
    }

    fn name(self: *Decoder) Error!Name {
        const length = try self.u8le();
        if (length == 0 or length > name_max) return Error.BadValue;
        if (self.offset + length > self.bytes.len) return Error.BadLength;
        defer self.offset += length;
        // The name was validated before it was encoded, but this side cannot
        // assume the peer did that.
        return Name.init(self.bytes[self.offset..][0..length]);
    }

    fn blob(self: *Decoder) Error![]const u8 {
        // The length is read through `u32le`, which bounds-checks the four bytes
        // before them. Reading them directly would run off the end of a message
        // that ended after its tag.
        const length = try self.u32le();
        if (self.offset + length > self.bytes.len) return Error.BadLength;
        defer self.offset += length;
        return self.bytes[self.offset..][0..length];
    }

    /// Decode a client request.
    pub fn request(self: *Decoder) Error!Request {
        // The tag is checked first; `offset` then starts just past it.
        _ = try self.tag();
        self.offset = 1;
        return switch (self.bytes[0]) {
            Tag.list => Request.list,
            Tag.kill_all => Request.kill_all,
            Tag.create => Request{ .create = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
                .program = try self.blob(),
            } },
            Tag.attach => Request{ .attach = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            Tag.detach => Request{ .detach = .{ .name = try self.name() } },
            Tag.kill => Request{ .kill = .{ .name = try self.name() } },
            Tag.input => Request{ .input = .{
                .name = try self.name(),
                .pane = try self.u64le(),
                .data = try self.blob(),
            } },
            Tag.resize => Request{ .resize = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            Tag.split => Request{ .split = .{
                .name = try self.name(),
                .axis = try self.u8le(),
                .program = try self.blob(),
            } },
            Tag.close => Request{ .close = .{ .name = try self.name() } },
            Tag.focus => Request{ .focus = .{
                .name = try self.name(),
                .backwards = (try self.u8le()) != 0,
            } },
            Tag.float => Request{ .float = .{ .name = try self.name() } },
            Tag.dock => Request{ .dock = .{
                .name = try self.name(),
                .target = try self.u64le(),
            } },
            Tag.dock_cancel => Request{ .dock_cancel = .{ .name = try self.name() } },
            Tag.toggle_floats => Request{ .toggle_floats = .{ .name = try self.name() } },
            else => Error.UnknownTag,
        };
    }

    /// Decode a server event.
    pub fn event(self: *Decoder) Error!Event {
        _ = try self.tag();
        self.offset = 1;
        return switch (self.bytes[0]) {
            Tag.list_end => Event.list_end,
            Tag.session => Event{ .session = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
                .clients = try self.u8le(),
                .pid = try self.i32le(),
                .running = (try self.u8le()) != 0,
            } },
            Tag.attached => Event{ .attached = .{
                .name = try self.name(),
                .rows = try self.u16le(),
                .cols = try self.u16le(),
            } },
            Tag.detached => Event{ .detached = .{ .name = try self.name() } },
            Tag.created => Event{ .created = .{ .name = try self.name() } },
            Tag.exited => Event{ .exited = .{
                .name = try self.name(),
                .status = try self.u8le(),
            } },
            Tag.output => Event{ .output = .{
                .name = try self.name(),
                .pane = try self.u64le(),
                .data = try self.blob(),
            } },
            Tag.layout => Event{
                .layout = blk: {
                    const session_name = try self.name();
                    const area_rows = try self.u16le();
                    const area_cols = try self.u16le();
                    const focused = try self.u64le();
                    const focused_float = try self.u64le();
                    const docking = (try self.u8le()) != 0;
                    const floats_hidden = (try self.u8le()) != 0;
                    const count = try self.u16le();

                    // The placements are decoded field by field into the caller's
                    // buffer. Reinterpreting the message bytes as `[]PanePlacement`
                    // would be faster and wrong: the wire format is packed, the struct
                    // has alignment and padding, and a peer could hand over bytes that
                    // happen to parse as a different length than they occupy.
                    if (count > self.placements.len) return Error.BadLength;
                    var index: usize = 0;
                    while (index < count) : (index += 1) {
                        self.placements[index] = .{
                            .id = try self.u64le(),
                            .rect = .{
                                .x = try self.u16le(),
                                .y = try self.u16le(),
                                .width = try self.u16le(),
                                .height = try self.u16le(),
                            },
                            .exited = (try self.u8le()) != 0,
                            .floating = (try self.u8le()) != 0,
                            .label = try self.u8le(),
                        };
                    }
                    break :blk .{
                        .name = session_name,
                        .area_rows = area_rows,
                        .area_cols = area_cols,
                        .focused = focused,
                        .focused_float = focused_float,
                        .docking = docking,
                        .floats_hidden = floats_hidden,
                        .panes = self.placements[0..index],
                    };
                },
            },
            Tag.failure => Event{ .failure = .{ .message = try self.blob() } },
            else => Error.UnknownTag,
        };
    }
};

/// Split a program string into null-separated arguments.
///
/// The program travels as one blob with NUL separators rather than a length
/// per argument, because `execve` wants NUL-terminated strings anyway and the
/// server only has to replace the separators with terminators.
pub fn splitProgram(program: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, program, 0);
    while (iterator.next()) |part| {
        if (count == out.len) break;
        if (part.len == 0) continue;
        out[count] = part;
        count += 1;
    }
    return count;
}

/// Join arguments into a NUL-separated program string.
pub fn joinProgram(out: *std.ArrayList(u8), gpa: std.mem.Allocator, argv: []const []const u8) !void {
    for (argv, 0..) |argument, index| {
        if (index != 0) try out.append(gpa, 0);
        // A NUL inside an argument would be indistinguishable from a separator,
        // so it cannot be represented and is not silently dropped.
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return Error.BadValue;
        try out.appendSlice(gpa, argument);
    }
}

test "a layout event round-trips with every pane's rectangle intact" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const placements = [_]PanePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .width = 40, .height = 24 }, .exited = false, .floating = false, .label = 0 },
        .{ .id = 2, .rect = .{ .x = 40, .y = 0, .width = 40, .height = 12 }, .exited = true, .floating = false, .label = 0 },
        .{ .id = 3, .rect = .{ .x = 40, .y = 12, .width = 40, .height = 12 }, .exited = false, .floating = false, .label = 0 },
    };

    const frame = try encoder.writeEvent(.{ .layout = .{
        .name = try Name.init("work"),
        .area_rows = 24,
        .area_cols = 80,
        .focused = 3,
        .focused_float = 0,
        .docking = false,
        .floats_hidden = false,
        .panes = &placements,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expect(event.layout.name.eql("work"));
    try std.testing.expectEqual(@as(u16, 24), event.layout.area_rows);
    try std.testing.expectEqual(@as(u16, 80), event.layout.area_cols);
    try std.testing.expectEqual(@as(u64, 3), event.layout.focused);
    try std.testing.expectEqual(@as(usize, 3), event.layout.panes.len);

    // Each placement is checked field by field: a packed wire format re-read as a
    // padded struct is exactly the kind of mismatch that would silently shift every
    // rectangle by a few cells.
    for (placements, event.layout.panes) |expected, got| {
        try std.testing.expectEqual(expected.id, got.id);
        try std.testing.expectEqual(expected.rect.x, got.rect.x);
        try std.testing.expectEqual(expected.rect.y, got.rect.y);
        try std.testing.expectEqual(expected.rect.width, got.rect.width);
        try std.testing.expectEqual(expected.rect.height, got.rect.height);
        try std.testing.expectEqual(expected.exited, got.exited);
    }
}

test "a layout event with no panes round-trips" {
    // A session whose last pane was closed still reports its area, so that the
    // client knows how much room it has and can draw background.
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const frame = try encoder.writeEvent(.{ .layout = .{
        .name = try Name.init("empty"),
        .area_rows = 24,
        .area_cols = 80,
        .focused = 0,
        .focused_float = 0,
        .docking = false,
        .floats_hidden = false,
        .panes = &.{},
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expectEqual(@as(usize, 0), event.layout.panes.len);
    try std.testing.expectEqual(@as(u64, 0), event.layout.focused);
}

test "a truncated layout event is rejected rather than read past its end" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const placements = [_]PanePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .width = 40, .height = 24 }, .exited = false, .floating = false, .label = 0 },
    };

    // Claim two placements but supply one, so the second read runs off the end.
    const frame = try encoder.writeEvent(.{ .layout = .{
        .name = try Name.init("work"),
        .area_rows = 24,
        .area_cols = 80,
        .focused = 1,
        .focused_float = 0,
        .docking = false,
        .floats_hidden = false,
        .panes = &placements,
    } });

    var bytes = try gpa.dupe(u8, frame);
    defer gpa.free(bytes);

    // The pane count sits at the end of the layout's fixed part. Rather than hardcoding that
    // length -- which silently rots the moment a field is added, as it did once already -- it is
    // measured by walking the frame with a decoder.
    const count_offset = try paneCountOffset(bytes);
    std.mem.writeInt(u16, bytes[count_offset..][0..2], 2, .little);

    var decoder = Decoder.init(bytes);
    try std.testing.expectError(Error.BadLength, decoder.event());
}

/// Where the pane count sits in an encoded layout event.
///
/// Found by walking the frame field by field, so that adding a field to the layout does not mean
/// editing a magic number here.
fn paneCountOffset(bytes: []const u8) !usize {
    var decoder = Decoder.init(bytes);
    _ = try decoder.tag();
    decoder.offset = 1;
    _ = try decoder.name();
    _ = try decoder.u16le(); // area_rows
    _ = try decoder.u16le(); // area_cols
    _ = try decoder.u64le(); // focused
    _ = try decoder.u64le(); // focused_float
    _ = try decoder.u8le(); // docking
    _ = try decoder.u8le(); // floats_hidden
    return decoder.offset;
}

test "a layout event carries floats and labels" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    // Two tiled panes and one floating above them, with the layout in dock-select mode so every
    // tiled pane carries a label. This is the message with the most fields, and the one where a
    // field-order mistake would show up as labels attached to the wrong panes.
    const placements = [_]PanePlacement{
        .{
            .id = 10,
            .rect = .{ .x = 0, .y = 0, .width = 40, .height = 24 },
            .exited = false,
            .floating = false,
            .label = 1,
        },
        .{
            .id = 11,
            .rect = .{ .x = 40, .y = 0, .width = 40, .height = 24 },
            .exited = false,
            .floating = false,
            .label = 2,
        },
        .{
            .id = 12,
            .rect = .{ .x = 20, .y = 5, .width = 40, .height = 12 },
            .exited = true,
            .floating = true,
            .label = 0,
        },
    };

    const frame = try encoder.writeEvent(.{ .layout = .{
        .name = try Name.init("floats"),
        .area_rows = 24,
        .area_cols = 80,
        .focused = 11,
        .focused_float = 12,
        .docking = true,
        .floats_hidden = false,
        .panes = &placements,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expect(event.layout.name.eql("floats"));
    try std.testing.expectEqual(@as(u64, 11), event.layout.focused);
    try std.testing.expectEqual(@as(u64, 12), event.layout.focused_float);
    try std.testing.expect(event.layout.docking);
    try std.testing.expectEqual(@as(usize, 3), event.layout.panes.len);

    for (placements, event.layout.panes) |expected, got| {
        try std.testing.expectEqual(expected.id, got.id);
        try std.testing.expectEqual(expected.floating, got.floating);
        try std.testing.expectEqual(expected.label, got.label);
        try std.testing.expectEqual(expected.exited, got.exited);
        // A float's rectangle is absolute window cells and overlaps the tiled ones, so it has to
        // survive the round trip exactly rather than being clipped to the area.
        try std.testing.expectEqual(expected.rect.x, got.rect.x);
        try std.testing.expectEqual(expected.rect.y, got.rect.y);
        try std.testing.expectEqual(expected.rect.width, got.rect.width);
        try std.testing.expectEqual(expected.rect.height, got.rect.height);
    }
}

test "float, dock and dock-cancel requests round-trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("work");

    {
        const frame = try encoder.writeRequest(.{ .float = .{ .name = name } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expect(request.float.name.eql("work"));
    }

    {
        // A target of zero means "start choosing", which must survive as zero rather than being
        // mistaken for an unset field.
        const frame = try encoder.writeRequest(.{ .dock = .{ .name = name, .target = 0 } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u64, 0), request.dock.target);
    }

    {
        const frame = try encoder.writeRequest(.{ .dock = .{ .name = name, .target = 7 } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u64, 7), request.dock.target);
    }

    {
        const frame = try encoder.writeRequest(.{ .dock_cancel = .{ .name = name } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expect(request.dock_cancel.name.eql("work"));
    }
}

test "split, close and focus requests round-trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("work");

    {
        const frame = try encoder.writeRequest(.{ .split = .{
            .name = name,
            .axis = 1,
            .program = "vim\x00notes.txt",
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u8, 1), request.split.axis);
        try std.testing.expectEqualStrings("vim\x00notes.txt", request.split.program);
    }

    {
        const frame = try encoder.writeRequest(.{ .focus = .{
            .name = name,
            .backwards = true,
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expect(request.focus.backwards);
    }

    {
        const frame = try encoder.writeRequest(.{ .close = .{ .name = name } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expect(request.close.name.eql("work"));
    }
}

test "a name rejects path separators and empties" {
    _ = try Name.init("work");
    _ = try Name.init("build-2.1");
    try std.testing.expectError(Error.BadValue, Name.init(""));
    try std.testing.expectError(Error.BadValue, Name.init("a/b"));
    try std.testing.expectError(Error.BadValue, Name.init("with space"));
    try std.testing.expectError(Error.BadValue, Name.init("a" ** 100));
}

test "an encoded payload starts with its tag, not a length" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const payload = try encoder.writeRequest(.list);

    // The distinction matters: `socket.encode` supplies the length prefix, and
    // a payload that also carried one would be decoded with the prefix read as
    // the tag.
    try std.testing.expectEqual(Tag.list, payload[0]);
    try std.testing.expectEqual(@as(usize, 1), payload.len);

    var decoder = Decoder.init(payload);
    try std.testing.expectEqual(Tag.list, try decoder.tag());
}

test "a request survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("work");

    {
        const frame = try encoder.writeRequest(.{ .attach = .{
            .name = name,
            .rows = 24,
            .cols = 80,
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u16, 24), request.attach.rows);
        try std.testing.expectEqual(@as(u16, 80), request.attach.cols);
        try std.testing.expect(request.attach.name.eql("work"));
    }

    {
        const frame = try encoder.writeRequest(.{ .input = .{
            .name = name,
            .pane = 7,
            .data = "ls -la\n",
        } });
        var decoder = Decoder.init(frame);
        const request = try decoder.request();
        try std.testing.expectEqual(@as(u64, 7), request.input.pane);
        try std.testing.expectEqualStrings("ls -la\n", request.input.data);
    }

    {
        const frame = try encoder.writeRequest(.list);
        var decoder = Decoder.init(frame);
        try std.testing.expectEqual(Request.list, try decoder.request());
    }
}

test "an event survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const name = try Name.init("build");

    const frame = try encoder.writeEvent(.{ .session = .{
        .name = name,
        .rows = 10,
        .cols = 40,
        .clients = 2,
        .pid = 4321,
        .running = true,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expect(event.session.name.eql("build"));
    try std.testing.expectEqual(@as(u16, 10), event.session.rows);
    try std.testing.expectEqual(@as(u8, 2), event.session.clients);
    try std.testing.expectEqual(@as(i32, 4321), event.session.pid);
    try std.testing.expect(event.session.running);
}

test "output carrying arbitrary bytes survives a round trip" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    // Pty output is not text: it is VT sequences full of NULs and high bytes,
    // and a decoder that treated it as a C string would truncate it.
    const raw = "\x1b[1;1H\x00\xff\xfe hello \x00\x1b[2J";

    const frame = try encoder.writeEvent(.{ .output = .{
        .name = try Name.init("tty"),
        .pane = 3,
        .data = raw,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expectEqualStrings(raw, event.output.data);
}

test "a truncated message is rejected rather than read past its end" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const payload = try encoder.writeRequest(.{ .attach = .{
        .name = try Name.init("work"),
        .rows = 24,
        .cols = 80,
    } });

    // Drop the columns field but keep the tag, so the decoder recognises the
    // message and then finds its body short. This is the case a bounds check
    // has to catch: the peer said "attach" and then stopped.
    const truncated = payload[0 .. payload.len - 2];

    var decoder = Decoder.init(truncated);
    try std.testing.expectError(Error.BadLength, decoder.request());
}

test "an unknown tag is reported rather than guessed at" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const frame = try encoder.writeRequest(.{ .detach = .{
        .name = try Name.init("work"),
    } });

    var bytes = try gpa.dupe(u8, frame);
    defer gpa.free(bytes);
    // Corrupt the tag. A version skew between client and server has to be
    // reported, not interpreted.
    bytes[4] = 99;
    std.mem.writeInt(u32, bytes[0..4], 2, .little);

    var decoder = Decoder.init(bytes[4..]);
    try std.testing.expectError(Error.UnknownTag, decoder.request());
    try std.testing.expectError(Error.UnknownTag, decoder.event());
}

test "a program string splits on its NUL separators" {
    const program = "vim\x00-c\x00set nu";
    var argv: [8][]const u8 = undefined;
    const count = splitProgram(program, &argv);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("vim", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("set nu", argv[2]);
}

test "joining a program round trips through splitting" {
    const gpa = std.testing.allocator;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joinProgram(&joined, gpa, &.{ "sh", "-c", "echo hi" });

    var argv: [8][]const u8 = undefined;
    const count = splitProgram(joined.items, &argv);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("echo hi", argv[2]);
}

test "an argument containing NUL is rejected" {
    const gpa = std.testing.allocator;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try std.testing.expectError(
        Error.BadValue,
        joinProgram(&joined, gpa, &.{ "echo", "a\x00b" }),
    );
}

test "a layout event reports hidden floats by omitting them" {
    // While the floats are hidden the list carries only the tiled panes. The flag is what tells the
    // client that floats exist but are put away, since otherwise "hidden" and "none" look identical.
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const placements = [_]PanePlacement{
        .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 },
            .exited = false,
            .floating = false,
            .label = 0,
        },
    };

    const frame = try encoder.writeEvent(.{ .layout = .{
        .name = try Name.init("hidden"),
        .area_rows = 24,
        .area_cols = 80,
        .focused = 1,
        .focused_float = 0,
        .docking = false,
        .floats_hidden = true,
        .panes = &placements,
    } });

    var decoder = Decoder.init(frame);
    const event = try decoder.event();
    try std.testing.expect(event.layout.floats_hidden);
    try std.testing.expectEqual(@as(usize, 1), event.layout.panes.len);
    // A hidden pane holds no focus, so the raised float is zero.
    try std.testing.expectEqual(@as(u64, 0), event.layout.focused_float);
}

test "the toggle request round-trips" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    const frame = try encoder.writeRequest(.{ .toggle_floats = .{
        .name = try Name.init("work"),
    } });

    var decoder = Decoder.init(frame);
    const request = try decoder.request();
    try std.testing.expect(request.toggle_floats.name.eql("work"));
}
