const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Loop = switch (@import("builtin").os.tag) {
    .linux => EPoll,
    .macos => KQueue,
    else => @compileError("platform not supported"),
};

pub const Event = union(enum) {
    readable: usize,
    disconnect: usize,
    signal: usize,
};

// High bit of data.u64 marks a signal fd entry (never set in valid user-space pointers).
const SIGNAL_MARK: u64 = 1 << 63;
const MAX_SIGNALS: usize = 8;

const EPoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,
    signal_fds: [MAX_SIGNALS]?SignalEntry = .{null} ** MAX_SIGNALS,

    const SignalEntry = struct { sfd: posix.fd_t, tag: usize };

    pub fn init() !EPoll {
        return .{
            .efd = try posix.epoll_create1(0),
            .ready_list = undefined,
            .signal_fds = .{null} ** MAX_SIGNALS,
        };
    }

    pub fn deinit(self: *EPoll) void {
        for (self.signal_fds) |maybe_entry| {
            if (maybe_entry) |entry| posix.close(entry.sfd);
        }
        posix.close(self.efd);
    }

    pub fn addFd(self: *EPoll, fd: posix.fd_t, tag: usize, disconnect: bool) !void {
        var events: u32 = linux.EPOLL.IN;
        if (disconnect) events |= linux.EPOLL.RDHUP;
        var ev = linux.epoll_event{
            .events = events,
            .data = .{ .u64 = tag },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    pub fn addSignal(self: *EPoll, signum: u32, tag: usize) !void {
        // Reserve slot before any signal/fd setup so we can fail cleanly.
        const slot_idx = blk: {
            for (self.signal_fds, 0..) |entry, i| {
                if (entry == null) break :blk i;
            }
            return error.TooManySignals;
        };

        var mask: linux.sigset_t = std.mem.zeroes(linux.sigset_t);
        linux.sigaddset(&mask, signum);

        var old_mask: linux.sigset_t = std.mem.zeroes(linux.sigset_t);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, &old_mask);
        errdefer _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);

        const rc = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
        if (@as(isize, @bitCast(rc)) < 0) return error.SignalFdFailed;
        const sfd: posix.fd_t = @intCast(rc);
        errdefer posix.close(sfd);

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = SIGNAL_MARK | slot_idx },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, sfd, &ev);

        self.signal_fds[slot_idx] = .{ .sfd = sfd, .tag = tag };
    }

    pub fn remove(self: *EPoll, fd: posix.fd_t) void {
        posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    }

    pub fn wait(self: *EPoll, timeout_ms: i32) Iterator {
        const count = posix.epoll_wait(self.efd, &self.ready_list, timeout_ms);
        return .{ .index = 0, .ready_list = self.ready_list[0..count], .epoll = self };
    }

    pub const Iterator = struct {
        index: usize,
        ready_list: []linux.epoll_event,
        epoll: *EPoll,

        pub fn next(self: *Iterator) ?Event {
            if (self.index >= self.ready_list.len) return null;
            defer self.index += 1;

            const ev = self.ready_list[self.index];
            const val = ev.data.u64;

            if (val & SIGNAL_MARK != 0) {
                const i: usize = @intCast(val & ~SIGNAL_MARK);
                const entry = self.epoll.signal_fds[i].?;
                // consume the signal notification
                var info: linux.signalfd_siginfo = undefined;
                _ = posix.read(entry.sfd, std.mem.asBytes(&info)) catch {};
                return .{ .signal = entry.tag };
            }

            const tag: usize = @intCast(val);
            if (ev.events & linux.EPOLL.ERR != 0) return .{ .disconnect = tag };
            // Drain readable data before reporting disconnect so trailing
            // bytes aren't dropped when EPOLLIN and EPOLLRDHUP/HUP arrive together.
            if (ev.events & linux.EPOLL.IN != 0) return .{ .readable = tag };
            const hup_mask = linux.EPOLL.RDHUP | linux.EPOLL.HUP;
            if (ev.events & hup_mask != 0) return .{ .disconnect = tag };
            return .{ .readable = tag };
        }
    };
};

const KQueue = struct {
    kfd: posix.fd_t,
    ready_list: [128]posix.Kevent = undefined,

    pub fn init() !KQueue {
        return .{ .kfd = try posix.kqueue(), .ready_list = undefined };
    }

    pub fn deinit(self: *KQueue) void {
        posix.close(self.kfd);
    }

    pub fn addFd(self: *KQueue, fd: posix.fd_t, tag: usize, disconnect: bool) !void {
        _ = disconnect; // kqueue reports disconnect via EV_EOF automatically
        const change = posix.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = tag,
        };
        _ = try posix.kevent(self.kfd, &.{change}, &.{}, null);
    }

    pub fn addSignal(self: *KQueue, signum: u32, tag: usize) !void {
        const change = posix.Kevent{
            .ident = signum,
            .filter = std.c.EVFILT.SIGNAL,
            .flags = std.c.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = tag,
        };
        _ = try posix.kevent(self.kfd, &.{change}, &.{}, null);
    }

    pub fn remove(self: *KQueue, fd: posix.fd_t) void {
        const change = posix.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = posix.kevent(self.kfd, &.{change}, &.{}, null) catch {};
    }

    pub fn wait(self: *KQueue, timeout_ms: i32) Iterator {
        var ts: posix.timespec = undefined;
        const ts_ptr: ?*const posix.timespec = if (timeout_ms < 0) null else blk: {
            ts = .{
                .sec = @divTrunc(timeout_ms, 1000),
                .nsec = @rem(timeout_ms, 1000) * 1_000_000,
            };
            break :blk &ts;
        };
        const count = posix.kevent(self.kfd, &.{}, &self.ready_list, ts_ptr) catch 0;
        return .{ .index = 0, .ready_list = self.ready_list[0..count] };
    }

    pub const Iterator = struct {
        index: usize,
        ready_list: []posix.Kevent,

        pub fn next(self: *Iterator) ?Event {
            if (self.index >= self.ready_list.len) return null;
            defer self.index += 1;

            const ev = self.ready_list[self.index];
            if (ev.filter == std.c.EVFILT.SIGNAL) return .{ .signal = ev.udata };
            if (ev.flags & std.c.EV.ERROR != 0) return .{ .disconnect = ev.udata };
            // EV_EOF can be set while bytes are still buffered (ev.data > 0).
            // Drain those bytes first; the next wait will redeliver EV_EOF.
            if (ev.flags & std.c.EV.EOF != 0 and ev.data == 0) return .{ .disconnect = ev.udata };
            return .{ .readable = ev.udata };
        }
    };
};
