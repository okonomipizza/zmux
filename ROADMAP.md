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

Still no server and no socket in this phase: one process owns one pty and
renders to its own stdout.

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

## Phase 2 — TUI

Draw the screen and a minimal frame around it.

- Enter the alternate screen, enable raw mode, restore on exit
- Render from the render state, redrawing only rows the library marks dirty
- Draw a status line, and the cursor at its reported viewport position
- Handle `SIGWINCH` and propagate the new size

Judgement: an editor is usable, with correct colors and a visible cursor.

## Phase 3 — server, sessions and IPC

Split into server and client, and add the session commands.

- Length-prefixed message framing over a unix socket
- Server: session registry, client registry, epoll over listeners, clients and
  ptys, `signalfd` for `SIGCHLD`
- Client: attach, detach, and forward input
- Start the server on demand when a socket is missing
- Commands: `ls`, `attach`, `detach`, `kill <session>`, `kill-all`

Judgement: detach and reattach preserves a running program and its scrollback,
and two clients can view one session at once.

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

These are not yet decided. None of them block Phase 1.

**Session persistence across a server restart.** libghostty-vt's headers
describe a snapshot API, but the pinned build does not export those symbols, so
serialising terminal state is not available today. Either sessions are simply
lost on restart, or a future revision provides the API.

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
