# Roadmap

Each phase ends at a state that can be run and judged. The ordering is chosen
so that the riskiest integration is proven first and the cheapest to debug.

## Phase 0 — VT integration (done)

Prove that libghostty-vt links, parses, and exposes a screen we can read.

- `flake.nix` depends on `libghostty-vt` and exports the header and library
  directories to the Zig build
- `build.zig` locates the library and links it into the executable and tests
- `src/vt.zig` wraps the C ABI: terminal lifecycle, `vt_write`, resize, mode
  queries, render state, row and cell iteration
- `zmux dump` reads VT bytes on stdin, parses them, and prints the screen

Verified: CRLF line handling, cursor addressing (`CSI row;col H`), SGR styles
and 24-bit color, UTF-8 including wide characters, and the terminal reply path
(a cursor position report reaches the `write_pty` callback as `CSI 1;1R`).

This phase exists to settle the C ABI early. A wrong struct layout or a stale
enum produces silently wrong output rather than a compile error, so it is
better to find that with a fixed string than through a live shell.

Two things were learned here that shape later work.

**The library's API is moving.** Between two nixpkgs revisions the constructor
changed from `ghostty_terminal_new(allocator, out, cols, rows)` to taking an
options struct with a scrollback limit, and the mode query moved from a
dedicated `ghostty_terminal_mode_get` to `ghostty_terminal_get` with
`GHOSTTY_TERMINAL_DATA_MODE`. Treat `src/vt.zig` as the containment boundary:
when the pin moves, the compile errors will be concentrated there.

**Zig cannot infer the libc inside the Nix sandbox.** Without an explicit
`-Dtarget`, the build links Zig's bundled musl and emits a binary whose
interpreter does not exist on the host. The derivation passes the host triple
and glibc version for that reason; the comment there explains it.

**A Zig binary from this build is not Nix-relocatable without `patchelf`.**
Even with the right target, the linker records `/lib64/ld-linux-x86-64.so.2` as
the interpreter and a search path that does not name libghostty-vt. On a
machine that happens to provide the `/lib64` stub both problems are invisible
and the binary appears to work, so this only shows up elsewhere. The `postFixup`
step rewrites both. When changing this derivation, check `readelf -lW` and
`readelf -dW` rather than only running the binary.

## Phase 0.5 — command line

The interface the server will hang off, settled before there is a server.

Every command from the design is parsed: `ls`, `attach <session>`, `detach`,
`kill <session>`, `kill-all`, plus `dump`. Parsing uses
[zig-clap](https://github.com/Hejsil/zig-clap), pinned in `build.zig.zon`.

The commands with no implementation behind them report that and exit non-zero
rather than failing silently, so the interface can be exercised now and the
server slotted in without changing how it is called.

Two things worth recording.

**clap's version matters more than usual.** The 0.10.0 that nixpkgs carries
compiles against an older Zig and fails against 0.16 with four unrelated
errors. 0.12.0 declares `minimum_zig_version = "0.16.0-dev"` and works. Check
that field when the toolchain moves.

**Nix cannot fetch Zig dependencies.** The build sandbox has no network, so
`zig build` fails with `NameServerFailure` trying to reach the package URL. The
flake pre-fetches into a fixed-output derivation and the build consumes it with
`--system`. Note that `--fetch` leaves each dependency as a tarball while
`--system` wants it unpacked, because it reads the dependency's own `build.zig`
to learn which modules it exports; the derivation unpacks after fetching.

## Phase 1 — pty and a live shell

Get a real program running and responding.

1. Open `/dev/ptmx`, obtain the slave with `TIOCGPTN`, unlock with `TIOCSPTLCK`
2. Spawn `$SHELL` on the slave with `fork` and `setsid`, with the slave on fds 0/1/2
3. Register the master in epoll and feed reads into `vt_write`
4. Register the `write_pty` callback and forward replies to the master
5. Encode keystrokes with libghostty-vt's key encoder and write them to the master
6. Apply `TIOCSWINSZ` and `ghostty_terminal_resize` together

Judgement: `vim` starts and responds. An editor probes the terminal at startup
and blocks without a cursor position report, so this single test exercises the
pty, the parser, the reply path and the input encoder at once.

This is done. `zmux run [program]` starts a program on a new pty and renders it
to the terminal zmux was started from. Verified by driving `vim` through a pty:
typing text, leaving insert mode, `:w` and `:q!` all work, and the file is
written. `tools/drive.zig` is the harness that feeds those keystrokes on a
schedule; build it with `zig build drive`.

Still no server and no socket in this phase: one process owns one pty and
renders to its own terminal.

### A bug this phase found

The session originally passed its own address to the terminal for the reply
callback, then returned itself by value. The copy left the terminal holding a
pointer to the stack slot the copy came from, so the callback wrote through a
stale address. Against a single cursor position query it appeared to work; `vim`
issues them continuously and crashed almost immediately with
`incorrect alignment`.

The fix is to heap-allocate the session so its address is stable. The general
lesson is worth keeping: a pointer handed across a C boundary must not point
into a value that is later copied, and the failure only shows up under a caller
that uses the callback repeatedly. There is a regression test for it.

### What Zig 0.16 changed underneath this phase

These were each confirmed by compiling against the pinned toolchain, because
the failure mode for most of them is a compile error naming a replacement that
does not exist.

**`std.posix` has lost nearly all of its POSIX wrappers.** `open`, `close`,
`write`, `dup2`, `fork`, `execve`, `setsid`, `waitpid`, `fcntl`, `openpty` and
`posix_spawn` are all gone; the compiler reports only
`no member named 'X'`. Surviving and used here: `openatZ`, `read`, `sigprocmask`,
`signalfd`, `tcgetattr`. Everything else goes through the raw syscalls in
`std.os.linux`, which return `usize` and report errors as negative errno. The
two-step idiom is `linux.errno(rc)` first, then narrow the fd with `@intCast` —
casting before checking does not compile. `linux.E.init` does not exist either;
the decoder is `linux.errno`.

**The ioctl names drop the `TIOC` prefix.** They live in `std.os.linux.T`, so
`TIOCGPTN` is `T.IOCGPTN` (`0x80045430`) and `TIOCSCTTY` is `T.IOCSCTTY`
(`0x540e`). Searching the std source for `TIOC` finds nothing.

**`std.c.posix_spawn` cannot be used on Linux.** It is a declaration that
aliases the Darwin implementation, whose body asserts the target is Darwin, so
touching it is a compile error with or without `-lc`. It is reachable through
`@cImport("spawn.h")`, but glibc does not define `POSIX_SPAWN_SETSID` and offers
no file action for `TIOCSCTTY`, so it cannot give the child a controlling
terminal. Phase 1 uses the `fork` path for that reason, which the earlier plan
had ruled out.

**`std.posix.winsize` uses `row`/`col`/`xpixel`/`ypixel`.** There is no
`ws_row`; that spelling is a compile error.

**Two smaller traps.** `std.posix.sigprocmask` returns `void`, not an error
union, so `try` on it fails to compile. And when the slave side closes, reading
the master returns `error.InputOutput` (EIO) rather than 0, so the read loop
must treat it as end of file or it spins forever.

## Phase 2 — TUI (done)

Draw the screen and a minimal frame around it.

- Enter the alternate screen, enable raw mode, restore on exit
- Render from the render state, redrawing only rows the library marks dirty
- Draw a status line, and the cursor at its reported viewport position
- Handle `SIGWINCH` and propagate the new size (done in Phase 3.1)

Judgement: an editor is usable, with correct colors and a visible cursor.

Most of this phase arrived early, in Phase 1: the alternate screen, raw mode with
restoration, incremental repainting of the rows the library marks dirty, and the
cursor at its reported position. `SIGWINCH` arrived in Phase 3.1, because it only
became meaningful once there was a server to tell. The status line is the last
piece.

### The status line reserves its row

The bottom row belongs to zmux, so the session's terminal is one row shorter than
the window and the status line has nowhere to overlap the program's output. The
alternative — drawing over the last row — would hide a row of a full-screen
editor, which uses every row it is given. tmux and screen reserve a row for the
same reason.

That one-row difference is the whole reason the client tracks two sizes rather
than one. `sessionSize` is the single place it is applied, and it clamps so that a
window of one row still leaves the program a row: libghostty-vt rejects a
zero-row terminal, and the status line giving up its row is better than the
program having nowhere to draw.

The line is drawn in inverse video with no colour of its own, so it stays legible
on whatever palette the user has, and it is padded to the full width so the bar
covers the row. It is truncated rather than wrapped, because a wrapped status line
would scroll the screen underneath it.

Verified: attaching at 24x80 shows `STATUS-TEST` on row 1 and
` zmux | st | 80x23 | running | ctrl-a detach` on row 24, with row 23 blank. A
program that prints `stty size` reports `winch 39 100` after an attached client is
resized to 40x100, so the session is given the window minus the status row. A
detached session has no client and therefore no status line, and keeps all 24 rows.

## Phase 3.1 — resizing (done)

Make a resized window reach the program in the session.

The kernel signals whoever holds the terminal, which is the client, while the
program is on the far side of a pty the server owns. So the client reads the new
size and forwards it: client gets `SIGWINCH`, queries the terminal, sends a
`resize` request, the server applies `TIOCSWINSZ` and resizes its terminal, and
the kernel then signals the program, which re-reads the size itself.

`SIGWINCH` is delivered through `signalfd` rather than a handler, so it arrives as
one more readable descriptor in the epoll loop that already exists. A handler
would have to hand the news to that loop through an atomic flag, and the loop
would then have to poll the flag — either blocking for up to some timeout or
busy-looping. The loop has no timeout, because one would wake it forever for
nothing.

Verified: a shell that traps `WINCH` and prints `stty size` logs `start 24 80`
when its pty is created and `winch 40 100` after the attached client's terminal is
resized to 40x100, and `zmux ls` then reports the session as 100x40.

Two notes on the implementation. The signal set must be *blocked* before the
signalfd is created; a blocked signal is not delivered to its default action and
is not dropped, it stays pending until the descriptor is read. And there are two
different `sigset_t` definitions in the standard library — the kernel's array of
`c_ulong` and the one `std.posix` resolves to when linking libc — which are not
interchangeable; this module uses the `std.posix` one throughout so its wrappers
and the raw syscall agree.

## Phase 3 — server, sessions and IPC (done)

Split into server and client, and add the session commands.

- Length-prefixed message framing over a unix socket
- Server: session registry, client registry, epoll over listeners, clients and
  ptys, `signalfd` for `SIGCHLD`
- Client: attach, detach, and forward input
- Start the server on demand when a socket is missing
- Commands: `ls`, `attach`, `detach`, `kill <session>`, `kill-all`

Judgement: detach and reattach preserves a running program and its scrollback,
and two clients can view one session at once.

### What was built

The server was built before the TUI, because the TUI's shape depends on what a
client can ask for. That is why this phase is done and Phase 2 is not.

The decision that shapes the phase is that a session's pty and its terminal live
in the **server**. A client that disconnects therefore costs the session nothing:
the program keeps running and its screen keeps being parsed, so a reconnecting
client is simply shown the current screen. If the terminal lived in the client,
detaching would mean killing the program or replaying every byte it had ever
produced.

The cost is that the server must render for clients that may be a different size
than the session was created at. zmux keeps the session's terminal at the size the
most recent resize asked for and forwards the pty's bytes to clients unchanged;
each client parses those bytes with its own terminal. Several clients may watch
one session and they share its size, which is the compromise tmux makes.

Two smaller choices are worth recording. Client indices, not pointers, are what
sessions store, because the client list reorders as clients come and go; the
sweep that removes a dead client therefore has to rewrite the indices of the client
that `swapRemove` moves into its slot, and getting that wrong sends one client's
screen to another's terminal. And a reattaching client is sent the screen re-emitted
as the VT sequences that would produce it, rather than a snapshot: the client
already has a terminal, so this reuses the one rendering path instead of adding a
second that has to track libghostty-vt.

Verified: `zig build test` passes 46 tests. A detached session survives, `ls`
reports it, `attach` from a separate process redraws the screen it accumulated
while nothing was watching, `ctrl-a` detaches without ending it, and `kill`,
`kill-all` and the empty and unknown-session cases behave. Checked with both a
`zig build` and a `nix build` binary.

`signalfd` is not used. The child is reaped with a non-blocking `waitpid` on each
pass of the loop, which needs no signal plumbing and cannot miss a child, because
the pty's readability already wakes the loop when the child dies.

### Two bugs this phase found

**Opening the pty slave without `O_NOCTTY` steals the caller's controlling
terminal.** This is the one that cost the most time, because its only symptom was
a session that reported a pid and never ran anything. The server calls `setsid` so
that it outlives the shell that started it, which leaves it a session leader with
no controlling terminal. In that state, opening `/dev/pts/N` *without* `O_NOCTTY`
silently makes that pty the server's own controlling terminal, and the child's
`TIOCSCTTY` then fails because the terminal belongs to another session — so the
child exits before `exec` and no program ever runs. The parent only needs the
descriptor for the child to inherit on fds 0/1/2, so it opens with `O_NOCTTY` and
lets the child claim the terminal. There is a regression test that forks, calls
`setsid`, and checks that a program still runs.

**A clap positional is only valid until the iterator advances.** `Args.Iterator.next`
returns a slice into the iterator's own buffer, which the next call reuses. clap
stores that slice, so the name read out of a `clap.ResultEx` is valid only until
some other argument is parsed. The symptom was an `attach` that reported "no such
session" for a session `ls` plainly listed, because the name it sent had been
overwritten by a stale argument. Names are copied into local storage before
anything else touches the iterator.

A second trap in the same area, which cost time while diagnosing rather than in
the product: clap numbers positionals by declaration order across *all* parameters,
so an option whose value name matches a positional's shifts the positional's slot.
`attach` and `kill` now have their own parameter lists, and only `run` declares
`--name`.


## Phase 4 — multiple panes

- Workspace binary tree with `ratio`-based splits
- Layout computation from the tree
- Split, close, and move focus between panes
- One pty and one terminal per pane
- Size panes to the smallest attached client

Judgement: several programs run side by side, each responding to input, with
resizing that reflows correctly.

## Phase 5 — floating panes

- Float list, drawn above the layout in z-order
- Move a pane between the tree and the float list without touching its pty
- Focus and raise a float; resize and move it
- Restore a float into the layout at its remembered ratio

Judgement: a pane can be parked and restored mid-command with no visible
interruption to the program inside it.

## Phase 6 — hardening

- A client disconnecting mid-write must not take down the session
- A pane whose child exits keeps its final screen until closed
- Server restart behaviour: sessions are lost, but the client reports it clearly
- Bound per-session memory; large scrollback is the main consumer
- Recover from `EINTR` and partial writes on the socket

## Open questions

These are not yet decided. None of them block the remaining work.

**Session persistence across a server restart.** libghostty-vt's headers
describe a snapshot API, but the pinned build does not export those symbols, so
serialising terminal state is not available today. Sessions are therefore lost
when the server exits, and a client reports that the connection went away.

**Several clients of different sizes.** Attaching resizes the session to the
newest client's terminal, so two clients of different sizes fight over it. The
compromise is the one tmux makes; a better answer is to size to the smallest and
letterbox the rest. Resizing an *attached* client now propagates correctly, but
the choice of which client wins is still last-one-in.

**Copy mode.** Scrollback browsing, selection and search are natural for a
multiplexer but are a phase of their own. `ghostty_terminal_scroll_viewport`
already supports absolute and prompt-relative scrolling, so the mechanism
exists.

**Configuration.** Key bindings, prefix key and appearance are currently
undecided. A file format should be chosen before bindings proliferate rather
than after.

**Multiple sessions per client.** Attaching to one session at a time is the
simplest model. Switching between sessions within a client, without
detaching, may be worth adding later.
