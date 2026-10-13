# Architecture

zmux is a terminal multiplexer: it keeps terminal sessions alive independently
of the terminal window that is currently looking at them, and arranges the
programs inside a session into panes.

## Process model

A server process owns every session and every pty. A client is a thin TUI that
attaches to one session over a unix socket.

```
┌─────────────────────────────────────────────────────┐
│ zmux server (one process, epoll-driven)             │
│                                                     │
│  Session "work"                                     │
│    ├── pane 1 ── pty ── child process (shell)       │
│    ├── pane 2 ── pty ── child process (editor)      │
│    └── float 1 ─ pty ── child process               │
│  Session "scratch"                                  │
│    └── pane 1 ── pty ── child process               │
│                                                     │
│  unix socket: $XDG_RUNTIME_DIR/zmux/<server>.sock   │
└─────────────────────────────────────────────────────┘
        ▲                                  ▲
        │ attach                           │ attach
   ┌────┴─────┐                       ┌────┴─────┐
   │ client A │  (TUI, own terminal)  │ client B │
   └──────────┘                       └──────────┘
```

The split is what makes sessions survive detaching. A client can exit at any
time without disturbing the programs inside; the server keeps reading their
ptys and updating terminal state.

Two clients may attach to the same session at once. They share the panes, so a
pane's pty size is negotiated across the attached clients rather than being
owned by one of them (see "Pane sizing" below).

## Division of responsibility

Escape sequence handling is deliberately not implemented here.

| Concern | Owner |
| --- | --- |
| pty creation, lifetime, resizing | zmux |
| epoll loop, session registry, IPC | zmux |
| pane tree, layout, focus, floating panes | zmux |
| TUI rendering (borders, status line) | zmux |
| VT parsing, screen state, reflow, scrollback | libghostty-vt |
| keystroke to byte sequence encoding | libghostty-vt |
| mouse event to byte sequence encoding | libghostty-vt |

`src/vt.zig` is the only module that knows the C ABI. Everything else works
with Zig types and explicit errors.

### Terminal replies

A terminal emulator must answer some escape sequences, not merely consume
them: cursor position reports, device attributes, window size queries and mode
reports. Programs block at startup waiting for these.

libghostty-vt exposes them through the `write_pty` callback
(`GHOSTTY_TERMINAL_OPT_WRITE_PTY`). When the parser generates a reply it calls
back with the exact bytes, and zmux writes them to the pane's pty master. This
callback must be registered before any bytes are fed to the parser, or a
program that probes the terminal will hang.

## Data structures

Ownership is a tree: the server owns sessions, a session owns its panes, and a
pane owns one pty plus one terminal.

```zig
const Server = struct {
    epfd: i32,
    listen_fd: i32,
    sessions: StringHashMap(*Session),
    clients: ArrayList(*Client),

    // epoll reports a bare fd, and fds are reused after close. Looking the
    // owner up here rather than trusting a cached pointer avoids delivering an
    // event to a freed pane.
    fd_index: AutoHashMap(i32, FdOwner),
};

const Session = struct {
    name: []const u8,
    id: u64,
    workspace: Workspace,
    floats: ArrayList(*Pane),
    focused: PaneId,
    focused_float: ?PaneId,
    clients: ArrayList(*Client), // empty means detached
    next_pane_id: u64,
};

const Workspace = struct {
    // Binary tree. Leaves are panes, interior nodes are splits.
    root: ?*Node,
};

const Node = union(enum) {
    leaf: PaneId,
    split: struct {
        axis: enum { horizontal, vertical },
        ratio: f32,
        first: *Node,
        second: *Node,
    },
};

const Pane = struct {
    id: PaneId,
    session: *Session,
    pty: Pty,
    vt: vt.Terminal,
    render: vt.RenderState,
    rect: Rect,       // final geometry, recomputed on layout
    is_float: bool,
    title: []const u8,
    exited: bool,
    exit_status: u32,
};
```

Three decisions are worth stating explicitly.

**`PaneId` is a stable identifier, never a pointer or an fd.** Moving a pane
between the workspace tree and the floating list is then an identifier
rewrite, and nothing that refers to the pane is invalidated.

**A pane owns exactly one terminal.** Two clients viewing the same session
share the parsed screen; the VT stream is not replayed per client.

**Floating panes use the same `Pane` type** as tiled ones. The only difference
is which list owns them, which is what makes switching between the two a move
rather than a teardown.

## Floating panes

A floating pane is a pane that the workspace has parked so it can be stacked
above the layout, keeping its contents alive.

Moving a pane between the layout and the float list must not touch the pty or
the terminal. The child process never observes the change, and its screen
state is preserved exactly. Only the owning list changes, and the client
redraws the affected rectangles. This is what makes the switch instant rather
than a restart.

A float is drawn over the tiled panes, and a tiled pane underneath one is not
painted at all while it is covered: whatever it would write is invisible, and
skipping it is what keeps typing in a float as cheap as typing in a tile. The
cost of that shortcut is that the cells under a float still hold it once the
float moves, is hidden or is closed, and no terminal reports them as changed,
because the layout changed rather than the terminal. The client therefore
remembers the rectangles the floats occupied on the previous frame and marks any
tiled pane intersecting an old or a new one stale, which repaints it in full.

## Painting

Each pane owns a libghostty-vt render state, which reports what changed since the
previous frame at two levels: a whole-frame flag and a per-row flag. The library
only ever sets these; clearing them is the renderer's job, and `update` reports
the frame as fully dirty for as long as they are not cleared. The client clears
the row flag as it paints each row and the frame flag once the frame is out, so a
keystroke costs one row rather than a screenful.

The row flags describe what changed inside a terminal. They cannot describe a pane
that moved, was uncovered by a float, or had a number drawn over it, because in
each of those cases the cells are unchanged and their position or their overlay is
not. Those cases set a `stale` flag on the pane, which repaints every row of it on
the next frame.

A frame is collected into one buffer per pane and written with a single write,
rather than a cursor move, a row and a reset going out separately. A pane with
nothing to paint writes nothing at all.

## Pane sizing

A pty has one size, but attached clients may have different window sizes. The
pane is sized to the smallest attached client, so every client can see all of
the content. This is the same compromise tmux makes.

When a pane is resized, the size is applied to the pty through `TIOCSWINSZ`
and to the terminal through `ghostty_terminal_resize`, which reflows wrapped
lines and can move rows between the active area and scrollback.

## Event loop

The server is a single-threaded epoll loop. Every source of work is a file
descriptor:

| fd | event |
| --- | --- |
| listening unix socket | a client wants to attach |
| client connection | a TUI sent a command |
| pty master | the child produced output, or exited |
| signalfd | `SIGCHLD`, so child exits are collected without a handler |

Child processes are started with `posix_spawn` rather than `fork`. The server
links a C library that maintains internal allocator state, and `fork` copies
that state into the child while leaving locks in an undefined condition.
`posix_spawn` avoids the window entirely.

Zig's standard library does not provide `openpty`. The pty layer opens
`/dev/ptmx` and configures the pair with `TIOCGPTN` and `TIOCSPTLCK`, which is
what `openpty` does internally.

## Platform support

Linux on x86_64 only. The event loop is epoll, so there is no kqueue path and
macOS is not a target. This keeps the poller, the pty layer and the process
handling single-implementation.

## Why libghostty-vt

Writing a VT parser that survives real programs is a large, long-tailed job:
reflow on resize, grapheme clustering, wide cells, the alternate screen,
bracketed paste, kitty keyboard and graphics protocols, and a long list of
edge cases in between. Ghostty's implementation is extracted from a terminal
emulator that already handles them.

The library is consumed as a C library through the Nix package
`libghostty-vt`, whose headers live in the `dev` output. `build.zig` locates it
through `GHOSTTY_VT_INCLUDE_DIR` and `GHOSTTY_VT_LIBRARY_DIR`, which the dev
shell and the Nix derivation both set.

### Version pinning

The headers and the shared object must come from the same revision. Zig
translates the headers at build time, so a mismatch between the translated
declarations and the linked library produces silent misbehaviour rather than a
compile error. Pinning both through one Nix package makes this structural.

One consequence is worth recording, because it is easy to get wrong when
reading upstream documentation: the `GHOSTTY_*` convenience macros in the
headers expand to calls to non-comptime inline functions, so they cannot be
used to build a comptime array from Zig. `src/vt.zig` packs mode numbers
directly using the layout documented in `modes.h` instead.
