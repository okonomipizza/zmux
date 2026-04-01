// src/c.zig
pub const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "600");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/wait.h");
});
