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

`run` no longer exists: a later phase replaced it with `attach`, which always gives
you a shell. The harness now drives `zmux attach`. See "What `attach` and the session
name mean" below.

Still no server and no socket in this phase: one process owns one pty and
renders to its own terminal.

That single-pane loop lived in `src/session.zig`, and it is gone. The server and
the client replaced it, and once `main.zig` stopped reaching the file it was no
longer compiled at all, so nothing noticed when it came to reference a type that
had been deleted. Dead code that is not even type-checked is worse than dead
code, because it still reads as live. The pty, parser and input paths it covered
are exercised through `attach` instead.

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
restoration, and the cursor at its reported position. `SIGWINCH` arrived in Phase
3.1, because it only became meaningful once there was a server to tell. The status
line is the last piece.

Incremental repainting did *not* arrive here, despite the item above. The client
wrote every row of every pane on every frame, which is visible as flicker while
typing, and is what made typing in a floating pane worse than typing in a tiled
one. The library was reporting the changed rows correctly the whole time; the
client simply never cleared the dirty flags, and libghostty-vt only ever sets
them, so every frame was reported as fully dirty and the incremental information
was discarded. Phase 5.2 fixed this.

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

### What `attach` and the session name mean

These were settled after the phase, because the first version was confusing in a way
that only showed up in use.

`attach <name>` attaches to a session, **creating it if it does not exist**, running
`$SHELL`. It never starts a program of its own. That makes naming a session the whole
of the interface for reaching it: `zmux attach work` puts you in a shell called
`work`, whether or not it was already running.

There used to be a `run` command as well, which started a session running a
particular program. It was removed in a later commit, for two reasons. It existed
only because Phase 1 had no server, so it was the only way to get a program onto a
pty, and it stayed afterwards by inertia: a session containing a shell can start
anything, and the session survives what it starts. And it carried the bug that made
`run work` try to execute a program called `work`, because two commands both took a
positional, one meaning a session and one meaning a program, with nothing to tell
them apart. The symptom was "the shell prompt never appears" plus a session name the
user did not recognise, and neither pointed at the cause.

Nothing about that was a defect in the code. It was a command whose meaning was not
what a user would assume, and the assumption was the right one. It was found by the
user trying it, which is the only way it was going to be found: every test passed
throughout.

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

### A trap that was not a bug, and cost time anyway

`execve` takes `[*:null]` — a pointer to an array whose last element is null — and Zig
will happily let a slice be cast to one. Casting `[N][*:0]const u8` to `[*:null]` has no
null at the end, so the kernel reads past the array into whatever follows and the call
fails with `ENOENT`, which `childExec` reports as exit 127. It looks exactly like a
missing program.

This was carried for a while as a suspected defect in the child's controlling terminal,
because probing it with `stty` failed with the same 127 that `tty` did not. There was no
defect: the probe was passing a slice cast, and `tty` was passing a `[_:null]` literal.
The product and the test driver both build a proper null-terminated vector, so nothing
was ever wrong. It is written down because the symptom points at the pty, and the next
person to see exit 127 should check the vector before the terminal.

A regression test would be better than a note, but the failure needs a bad vector, and
the type that prevents one is the same type that makes it unrepresentable here.

A second trap in the same area, which cost time while diagnosing rather than in
the product: clap numbers positionals by declaration order across *all* parameters,
so an option whose value name matches a positional's shifts the positional's slot.
`attach` and `kill` therefore have their own parameter lists, and neither declares an
option sharing a value name with its positional.


## Phase 4 — multiple panes (done)

- Workspace binary tree with `ratio`-based splits
- Layout computation from the tree
- Split, close, and move focus between panes
- One pty and one terminal per pane
- Size panes to the smallest attached client

Judgement: several programs run side by side, each responding to input, with
resizing that reflows correctly.

### What was built

A session is now a list of panes plus the tree that says where they go. Each pane owns
one pty and one parsed terminal, so two panes are two programs and two screens. The
server divides the session's area into rectangles and tells the client where they are;
the client keeps one terminal per pane and paints each into its rectangle.

The split between the two sides is deliberate. The server owns the tree, so it computes
the geometry and sizes each pane's pty from its rectangle — one place where a width is
decided, which is what keeps a program from being told a size the client is not drawing.
The client owns nothing but the pixels: it parses each pane's bytes into its own
terminal and positions the rows.

Geometry is computed on every layout and never stored, so a resize is one walk of the
tree rather than a migration of stored coordinates that could disagree with it.

Input carries the pane it is meant for rather than relying on which pane is focused. A
keystroke already in flight when focus moves must reach the pane the user was typing
into, and focus is the server's idea, read later.

Key bindings are vim-flavoured behind the existing `ctrl-b` prefix: `s` splits side by
side, `v` stacks, `q` closes the focused pane, `F` floats it, `f` toggles the floats,
`h`/`j`/`k`/`l` move focus, `<`/`>` move the focused pane past its neighbour, `o`
rotates the arrangement, `w` lists the sessions and switches to one, and `x` reads
the focused pane's history. A bare `ctrl-b` twice still detaches, and a key the prefix
does not use does nothing at all.

Closing the last pane discards the session, which is what a program exiting in it already
did. It used to remove the pane and leave the session behind, so the client stayed attached
to an empty window with a status line over it, and its state had no name: attached to
something with no panes, neither running a session nor detached from one. The two ways of
emptying a session now do the same thing.

Closing a pane also re-sends the remaining screens, which the exiting path already did and
this one did not. The space a closed pane gave up is drawn over by the panes that grew into
it, and what was underneath is not something the server tracks.

That last part was not always so. An unused key after the prefix used to detach, on the
reasoning that a typo should not leave the client in a state where the next byte is eaten.
Nothing is eaten: the prefix is consumed by the handler whether or not the key after it is
one it knows, so the next byte is an ordinary keystroke either way. What detaching actually
did was end the client on a mistyped key. It was noticed when `ctrl-b g` closed the window:
`g` is bound inside the scroll mode only, so at the top level it was a stray key and the
client went away. tmux ignores an unbound key, which left the session running and no client
attached when probed the same way.

The prefix was `ctrl-a` until the key was moved to `ctrl-b`, which is what tmux uses. It is
written as one named constant rather than as a byte in three places, because a prefix that
agreed with itself in only two of them would leave the third key either dead or sent to the
program by mistake. The records earlier in this file still say `ctrl-a`: they describe what
a phase verified when it was written, and rewriting them would claim a test ran against a
key that did not exist yet.

### Reading a pane's history

`ctrl-b x` opens the focused pane's scrollback. The movement keys follow `less` and
vim, which is where the habit comes from: `j`/`k` a line, `J`/`K` ten, `ctrl-d` and
`ctrl-u` half a screen, `ctrl-f` and `ctrl-v` a whole one, `g` and `G` the ends, `q`
or Escape to leave. The capitals moving by ten is the one addition, for crossing a long
history without holding a key.

Page-up is `ctrl-v` rather than `ctrl-b` because `ctrl-b` became the prefix. `less` uses
both for that movement, so the pairing survives the change, and the prefix is checked
before the movement keys so a reader pressing it gets out of the mode rather than
scrolling. The symmetry is tested: every movement is checked against the viewport's own
absolute row, since a sign is not visible in the code and a renamed key is exactly what
leaves one pointing the wrong way.

Scrollback is the library's, not a copy: the pane's own terminal holds the history, and
the mode moves its viewport. That is what makes it free — nothing crosses the wire, the
program is not disturbed, and the rows read are the rows the program wrote, with their
colours and their wide characters intact.

The mode exists rather than a pair of keys because it changes what every key means. `j`
is a scroll rather than a `j`, and `q` leaves rather than closing the pane beneath the
reader. Every keystroke is consumed, so nothing typed at a view of the past reaches a
program that would act on it.

A viewport that followed new output would be unreadable, so scrolling stops the pane
from following; output still arrives and still goes into the history. Typing puts the
viewport back at the bottom first, because the program's answer would otherwise arrive
below the view and the user would be typing without seeing it.

The mode refuses to open on a pane with no history. One that has printed less than a
screenful, or that is on the alternate screen where there is no scrollback at all, would
give a frozen screen and a mode that swallowed every key, which reads as the program
hanging. That is checked by asking the terminal how many rows it holds rather than by
tracking any of it here.

### Switching sessions without detaching

`ctrl-b w` opens a menu over the whole window listing the sessions numbered from one.
A number and Enter moves to that session; Escape stays where you are. The session being
left is not closed and its panes keep running, so this is a move rather than a restart.

The menu is drawn over the window rather than inside the status line, because the
sessions it lists are not the one on screen and drawing it beside them would invite
reading the listing as part of the current layout. It reuses the `list` request and the
`session` events that `zmux ls` already had, so nothing new crosses the wire to fetch
it; the events fill the menu instead of being printed.

Switching is one request rather than a detach followed by an attach, and that is not a
convenience. A client that attached before letting go of the old session would be in two
watcher lists at once, and the server would send it output for panes it no longer has.
The server removes the old watcher and attaches to the new session in one step, and the
client drops its panes, because they belong to the session being left.

The size travels with the request. The server does not remember a client's size between
requests, and the session being moved to has to be sized to this client, which is why
`attach` carries its own too.

Verified: an attached client at 80x24 shows the first pane's text on row 1 and the status
line reading `1 pane(s)`. Sending `ctrl-a s` produces `2 pane(s)`, and the client's output
contains cursor moves at columns 1 and 41 — the two halves of the window — so both panes
are painting. Detach, resize (`winch 39 100` from a program that traps `WINCH`), `kill` and
`kill-all` all still behave. `zig build test` passes 73 tests, including 16 for the tree
and 14 for the protocol. Checked with both a `zig build` and a `nix build` binary.

### Two bugs this phase found

**A reply was computed and then thrown away.** The server flushes a client's queue at the
end of `serviceClient`, but the read that *follows* a request commonly reports the peer's
close — a client that has sent one request and is waiting for the answer still shows up
that way. That path returned early, discarding the listing it had just built. The symptom
was `zmux ls` printing nothing while the server's own log said it had sent the listing,
and the fix is to flush on the way out of every path, including the ones that end the
connection.

**The first pane had no rectangle.** `addPane` puts a leaf in the tree, but a rectangle is
what the tree produces, and `createSession` never asked for one. The layout event therefore
carried a zero-width, zero-height pane, and the client skipped it because there was nowhere
to draw. The pane's screen was being parsed and sent correctly the whole time; only its
geometry was missing. `createSession` now calls `relayout` after adding the first pane.
This one is worth remembering because it is invisible in the code that looks responsible:
the drawing, the sizing and the protocol were all right.

## Phase 5 — floating panes (done)

- Float list, drawn above the layout in z-order
- Move a pane between the tree and the float list without touching its pty
- Focus and raise a float; resize and move it
- Restore a float into the layout at its remembered ratio

Judgement: a pane can be parked and restored mid-command with no visible
interruption to the program inside it.

### What was built

A pane can be lifted out of the layout and drawn above it, and put back. `ctrl-a f` parks
the focused pane; `ctrl-a d` begins docking it back.

Parking changes which list owns the pane and nothing else. The pty is not touched and the
child is not signalled, so the program inside has no way to tell that it moved — which is
the whole point, and is what makes the switch instant rather than a restart. A parked pane
is centred at three quarters of the window rather than keeping the rectangle it had while
tiled: a pane that was a narrow slice of the layout reads as a stray sliver once it is
above everything, and one that filled the window would not read as floating at all.

The space a parked pane leaves is handed to a neighbour, so the remaining panes grow
instead of leaving a hole. The neighbour is chosen by geometry, not by tree adjacency: a
pane whose sibling happens to be a subtree would otherwise give its space to whatever leaf
that subtree puts first, which can be on the far side of the window. The tree is walked for
a pane that shares a horizontal edge — one stacked directly above or below — and only if
there is none is a side-by-side neighbour used. Growing by rows is the better default,
because terminal content is laid out in rows and a pane that gains rows shows more of what
it already had, while one that gains columns only gets wider margins.

Docking is a two-step choice because the layout is a tree with no notion of "where the user
remembers it was". `ctrl-a d` freezes the layout, labels each tiled pane with a number, and
hides the floats so the labels can be read; the user presses a digit and the float is
spliced into that pane. The split follows the chosen pane's longer side, so the two halves
come out roughly square rather than as a pair of slivers. Escape cancels.

Verified: splitting twice and then parking one pane leaves three panes, of which the float
paints at rows 5 to 20 and column 14 of an 80x24 window — a centred 53x16 rectangle, which
is two thirds of the window in both directions. The parked pane's program is still running
afterwards, and so are the others. Docking into pane 1 changes the layout so that pane 1's
two children are stacked while the rest is unchanged, which is the split along its longer
side. `zig build test` passes 89 tests, five of them for the float geometry and the label
lookup.

A park that would leave no tiled panes is refused: a session with no layout has nothing to
dock back into, and the tree would be empty while a float still needed somewhere to belong.

### Hiding a float without closing it

`ctrl-a f` puts the floating panes away and brings them back. One key for both directions,
because there are only two states and a pair of keys would leave the user working out which
one they are in.

A hidden float is still a live pane: the program runs, the pty is open, and the screen keeps
being parsed. It is simply not drawn. That falls out of the existing design rather than
needing new machinery — `focused_float` already means "which float is showing", so hiding is
clearing it and setting a flag, and showing is setting it again.

Two rules the user set shape the implementation. A hidden pane never holds focus, which is
free: the layout event omits hidden floats entirely, so there is nothing for the client to
focus and nothing for input to reach. And showing a float again returns focus to the pane the
user was working in beforehand, which needs `focus_before_float`.

That second rule had a bug worth recording. The remembered pane was read from the tree
*before* the pane was detached — but at that moment the tree's focus is the pane being
floated, so hiding would have restored focus to the very pane being hidden. It contradicts the
first rule, and it is invisible in the code that looks responsible, because every piece is
doing what it says. The remembered pane is now read after the detach, when the tree has
already moved focus to the surviving tiled pane. The test that caught it asserts focus is the
tiled survivor and that the float is not in the tree, which is the property that makes the two
rules consistent rather than merely both present.

One consequence worth noting: a raised float now takes input in preference to the tiled pane.
Before this, input went to the tiled focus whatever was drawn on top, so a floated pane could
be seen but not typed into.

### Borders, and who owns the cells they take

A pane is drawn with a box around it, and the program inside is given the area *within* that
box rather than the whole rectangle. The two have to agree: the server sizes the pty by the
interior and the client paints the program's cells into it, and an off-by-one is a shell whose
text wraps one column away from where the border is.

That arithmetic therefore exists once, on `protocol.Rect`, which both sides already share.
`layout.Rect` delegates to it rather than repeating it. A second copy would be the kind of
duplication that looks harmless until one of them is corrected.

A rectangle smaller than three by three is left whole and gets no border, because a frame plus
one cell of content does not fit in less. Insisting would hand libghostty-vt a zero-sized
terminal, which it rejects.

The border is redrawn when the pane moves or comes out from under a float, not when its program
writes. Content is painted inside the interior and can never reach the border, so redrawing the
frame per keystroke would send two escape sequences per row for cells that cannot have changed.
Getting this wrong is not a correctness bug but it nearly triples the cost of typing, which is
how it was noticed.

### A pane whose program exits

A pane whose shell exits is now closed and its space given to a neighbour. It used to be kept
with its final screen, which meant a dead rectangle the user had to close by hand after every
`exit`. The last pane is still kept, because a session with no panes at all cannot be told apart
from a broken one, and it is the pane that carries the exit status.

Closing a pane has to forget it in three places, not one: the pane list, the workspace tree and
the float list. A float removed from the pane list but left in `floats` was the bug here — the
toggle then believed there was still something to show, and the session stayed in the hidden
state with nothing left to reveal. That bookkeeping now lives in `Session.forgetPane`, which
touches no pty and is therefore testable; closing a real pane frees a terminal and a reply route,
which a fabricated pane does not own.

A float is the exception, and it took three attempts to get right. A float whose program exits is
kept, showing that it ended, rather than closed. It is where a program is consulted, and the output
it leaves is usually the reason it was being consulted, so discarding it the moment the program ends
destroys the thing the user was looking at; and a float occupies no space the layout would reclaim,
so there is nothing to give away. A badge reading `exited` goes on its top edge, where the dock label
also goes, because without one the frame is indistinguishable from a program that is running and
simply not printing.

Getting there exposed two faults that had been there all along. `paneEnded` counted all panes rather
than tiled ones, so a float's exit took the tiled path and closed the pane. And the pane list cannot
tell a float from a tiled pane at all, since both are in it: the float list is the only thing that
knows, which is what `isFloating` answers and what the test pins.

Two of the three attempts at verifying this were wrong in the same way. A hand-written VT parser in
the probe dropped the float's frame and reported that the float had vanished — which is what the
*old* behaviour looked like, so it read as confirmation of the bug being fixed. Feeding the client's
output through libghostty-vt instead, the same library the product uses, gave the real screen. A
probe that parses escape sequences is a second implementation of the thing under test.

### A flaky test, and what it was

`pty.test.spawn a child on the pty and read its output` failed about one run in three. The
read loop stopped at the first empty read, but a pty reports two different things that way:
a child that has already exited returns end of file, and one that has not yet written
returns nothing. Only the first is a reason to stop. The loop now reads until the slave
closes, and the reap is retried rather than treated as a failure at the first look. Five
consecutive runs are clean.

## Phase 5.1 — colour (done)

Draw the styles the library reports, and stop telling programs the terminal cannot do
colour.

The client's pane painter took each cell's grapheme and discarded everything else. No
colour was emitted at all, for anything: a shell's prompt, `ls --color`, an editor's
syntax highlighting and a shell's dimmed autosuggestion were all drawn as plain text.
A user reported it as being unable to tell how much of a fish autosuggestion they had
typed, because the suggestion and their own input were the same colour. That was the
visible symptom of a painter that had never drawn a style.

The library resolves palette indices to RGB for us, so the painter asks for the
resolved foreground and background rather than carrying a palette of its own, and
writes them as 24-bit colour. A colour the cell does not set is written as the
terminal's *default* (39 or 49) rather than an RGB guess: zmux does not know the user's
theme, and guessing white-on-black would override it.

Each sequence starts from a reset, and the sequence is only written when a cell's style
differs from the one before it, so a run of text in one colour costs one escape rather
than one per character.

Two things had to change around it that were not obviously part of the job:

**The row buffer is no longer clipped by length.** It used to be truncated to the
pane's width, which was correct when it held only glyphs and became wrong the moment it
also held escape sequences: cutting at a byte offset splits a sequence and corrupts the
terminal. Cells are counted instead, and the row ends with a reset so a colour cannot
bleed into the cursor move that follows or into the pane beside it.

**`TERM=dumb` is no longer passed to a session.** A program told the terminal is `dumb`
disables colour, so a user whose environment says that saw no colour however well the
painter worked. zmux parses VT and draws colour, so `dumb` is untrue about the terminal
the program is on; a session is given `xterm-256color` instead. Any other `TERM` is the
user's own information and is passed through untouched, and a missing `TERM` is left
missing rather than invented.

Verified: a shell printing `\033[31m` red and `\033[38;2;0;200;0m` green renders both,
with the red resolved by the library to the terminal's own palette entry. A fish
session with `TERM=dumb` in the environment that started the server shows seven distinct
styles, including the grey `38;2;102;102;102` of its autosuggestion. `zig build test`
passes 103 tests, including the SGR encoder and the `TERM` substitution, and the tests
caught two bugs on the way: an introducer written as `3;2` instead of `38;2`, which
draws the 8-colour form with stray parameters, and a replacement value missing its
`TERM=` prefix, which would have handed the child a bare word where a variable belongs.

## Phase 5.2 — incremental repainting

Repaint only what changed, so that typing does not flicker.

The symptom was reported as flicker while typing, worst in a floating pane. The
cause was not the renderer being slow: the client painted every row of every
pane on every frame, and a float added the panes underneath it to the same frame.
Measured on the real client through a pty, one keystroke cost 4,876 bytes in a
tiled pane and 5,127 in a float.

libghostty-vt tracks dirty state at two levels, a whole-frame flag and a per-row
flag, and `render.h` states that the caller is expected to reset both: `update`
only ever sets them. The client reset neither, so the first frame's flags stayed
set and every later frame was reported as fully dirty. The library was computing
the changed rows correctly all along and the information was being thrown away.
`RowIterator.isDirty` had been wrapped in `vt.zig` and never called.

- `RenderState.clearDirty` and `RowIterator.clearDirty` wrap the two setters
- `drawPane` paints a row only when it is dirty, and clears the flag either way
- A frame is collected into one buffer and written once, rather than three writes
  per row
- A pane that is covered by a float is skipped, and a pane that stops being
  covered is marked stale so that the next frame repaints it in full
- A pane that moved, resized or gained a label is marked stale, because its
  cells did not change but their position or their overlay did

Verified: one keystroke costs 359 bytes tiled and 359 floated, an idle frame
costs nothing, and a pane uncovered by hiding a float repaints all of its rows.
The `drive` tool reports this and fails the run if a keystroke costs more than
two kilobytes; `measure` reports the row counts directly.

Judgement: the flicker is gone and typing costs the same whether or not a pane is
floating. What is not done is partial-row painting: a row that changed by one
cell is still written whole. That is the next step if the cost ever matters
again, and it needs cell-level damage tracking that the library does not provide
today.

## Phase 6 — hardening

Done:

- `EINTR` is retried on the socket's read, write and accept. It was reported as
  `SyscallFailed`, and the write path drops the client on any failure, so a signal
  arriving mid-write ended a connection that was perfectly healthy. The retry cannot
  spin: the descriptors are non-blocking, so a second call returns `EAGAIN`.
- A `kill` or `kill-all` now says the session was *killed* rather than reporting an exit
  status. `killSession` broadcast `exitStatusOf`, which is zero when no pane has exited,
  so destroying a session with programs still running told the user their program had
  finished successfully. The event carries an explicit flag, because no status value could
  mean "not an exit": 255 is reachable from `exit(255)` and from signal 127.
- A client whose server goes away reports it instead of returning silently. It used to
  restore the terminal and leave the user at their shell with the window simply gone.

Still open:

- Bound per-session memory; large scrollback is the main consumer. The configuration sets a
  32 MiB byte limit per pane, which is a deliberate ceiling rather than a measured one.
- Server restart behaviour: sessions are lost, but the client reports it clearly. The report
  is now clearer, but nothing survives a restart.
- **Unverified:** a server that dies while a client is attached, rather than one that is
  killed by `kill-all`. The message is written and reachable, but driving it needs the
  server's own pid, and `zmux ls` reports the *pane's* pid. Killing that is an ordinary
  program exit, which is what three attempts at the probe did before this was noticed —
  each one looked like confirmation that the fix was needed.

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

**Configuration.** Settled: a flat JSON object of dotted names to strings, under
`$XDG_CONFIG_HOME/zmux/config.json`, written in full on first attach and read
once at start-up. Flat rather than nested because every value is either a single
character or a colour, and nesting would need a structure and a parser to match
it for no gain in what a user can say. Written on first use rather than shipped
with the source, so that the file a user opens shows every knob rather than an
empty object they have to look up, and so that a packaged zmux does not overwrite
what they set.

The prefix key itself is not configurable. It is one constant used in three
places, and a prefix that could be changed in the file but was missed in one of
them would leave a key either dead or sent to the program by mistake; that is a
class of bug worth not having. Everything behind the prefix is configurable.

What is still undecided: whether a configuration change should be picked up
without restarting. Reading the file once is the simple model, and a colour
already drawn has no way to be reconciled with a file that changed underneath it.

**Multiple sessions per client.** Attaching to one session at a time is the
simplest model. Switching between sessions within a client, without
detaching, may be worth adding later.
