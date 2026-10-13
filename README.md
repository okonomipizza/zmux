# zmux

A simple terminal multiplexer.

## Features

- **Simple** — a small, focused feature set rather than a tmux clone.
- **Persistent floating panes** — panes that float above the layout and survive
  detaching.
- **Swappable workspace panes** — rearrange the panes of the current workspace.

Escape sequence handling is delegated to
[libghostty-vt](https://github.com/ghostty-org/ghostty), the VT library
extracted from [Ghostty](https://ghostty.org). zmux owns the pty, the server
and the TUI. See [ARCHITECTURE.md](ARCHITECTURE.md) for the reasoning and
[ROADMAP.md](ROADMAP.md) for what is built and what is planned.

## Status

Phases 0, 0.5, 1, 2, 3, 4 and 5 of the roadmap are complete. Escape sequence handling
comes from libghostty-vt, the command line is parsed with
[zig-clap](https://github.com/Hejsil/zig-clap), and there is a server that owns
the sessions.

```sh
# Enter a session, creating it if it is not running yet. This is the only way in:
# `attach work` runs your shell under the name "work".
zmux attach work
zmux attach default

# See what is running.
zmux ls
# work: 80x24, 0 client(s), pid 4321, running

zmux kill work
zmux kill-all
```

Attaching always gives you a shell. To run something else, start it from that
shell: `zmux attach work`, then `htop`. A multiplexer whose session contains a
shell is more useful than one whose session contains a single command, because the
shell can start anything and the session survives it.

Inside an attached session the prefix key is `ctrl-a`:

| key | action |
| --- | --- |
| `ctrl-a s` | split the focused pane side by side |
| `ctrl-a v` | split it into stacked halves |
| `ctrl-a q` | close the focused pane |
| `ctrl-a F` | float the focused pane above the layout |
| `ctrl-a d` | dock a floating pane back into the layout |
| `ctrl-a f` | hide the floating panes, or show them again |
| `ctrl-a h` / `k` | move focus to the previous pane |
| `ctrl-a l` / `j` | move focus to the next pane |
| `ctrl-a <` / `>` | move the focused pane past its neighbour |
| `ctrl-a o` | rotate every pane one place along |
| `ctrl-a w` | list the sessions and switch to one |
| `ctrl-a ctrl-a` | detach, leaving every pane running |

`ctrl-a w` lists the sessions in the same window, numbered from one. Type a
number and press Enter to move to that session, or Escape to stay where you
are. Nothing is detached and no pane is closed: the session being left keeps
running, and its panes are still there when you come back. The list is asked for
each time the menu opens, so a session started in another terminal is there and
one whose last pane exited is not.

`ctrl-a <` and `ctrl-a >` swap the focused pane with the pane beside it in the
layout's order, which is the same order the focus keys walk. `ctrl-a o` shifts
every pane one place along instead, last to first. Neither changes the shape of
the layout: the split ratios you built stay as they are, and only which pane sits
where changes. The programs inside are not disturbed beyond being resized to
their new rectangles, so a swap costs nothing but a redraw.

Each pane is its own program on its own pty, so a split gives two shells side by
side. A pane is drawn with a border around it, and the program is given the area
inside that border rather than the whole rectangle, so its own wrapping agrees with
what you see. A pane whose program exits is closed and its space given to a
neighbour; the last pane keeps its final screen, because a session with nothing to
draw could not be told apart from a broken one.

A floating pane is drawn above the layout, centred, and can be put back. Parking it
does not touch its pty, so the program inside carries on without noticing, and the
space it leaves is given to a neighbouring pane that grows into it. Docking asks
which pane to split: the layout freezes, each tiled pane shows a number, and the
number you press is divided along its longer side. Escape cancels.

`ctrl-a f` puts the floating panes away and brings them back. A hidden float keeps
running and keeps its screen; it is simply not drawn, and it cannot take focus, so
nothing is ever typed into a pane you cannot see. Showing them again returns focus
to the pane you were working in before the float appeared.

Colour is drawn, including 24-bit colour, so a shell's prompt, an editor's syntax
highlighting and a shell's dimmed autosuggestion all look as they should. A session
is given `TERM=xterm-256color` when the environment it would otherwise inherit says
`dumb`: zmux parses VT and draws colour, so `dumb` would tell the programs inside
something untrue about the terminal they are on. Any other `TERM` is passed through
untouched.

A session's pty and screen live in the server, so detaching costs the session
nothing: the program keeps running while nothing is watching, and reattaching
redraws the screen as it stands. A server is started on first use and keeps
running until `kill-all`.

Resizing the window while attached reaches the program inside the session, so a
full-screen editor re-lays out without being detached and reattached.

The bottom row is a status line showing the session name, its size and whether
the program is still running. That row belongs to zmux rather than to the
program, so the session is given the window minus one row and nothing the program
draws is ever covered up.

`dump` parses escape sequences on stdin and prints the resulting screen, which
is useful for inspecting what zmux makes of a byte stream:

```sh
printf 'Hello, \033[1;32mWorld\033[0m!\r\n' | zmux dump
```

Not yet built: copy mode and configuration. `zmux detach` outside
an attached client reports that, because the prefix key is how a client detaches.
See [ROADMAP.md](ROADMAP.md).

## Development

A development shell with a pinned Zig toolchain and libghostty-vt is provided.

```sh
nix develop
```

The shell provides `zig`, `zls` and `libghostty-vt`. The two Zig tools are
pinned to the same release (`0.16.0`); `zls` only works against the exact Zig
release it was built for, so keep them in sync.

The shell exports `GHOSTTY_VT_INCLUDE_DIR` and `GHOSTTY_VT_LIBRARY_DIR`, which
is how `build.zig` finds the VT library. Building outside the shell requires
setting both.

Common commands:

```sh
zig build               # build into ./zig-out/bin/zmux
zig build run           # build and run
zig build test          # run unit tests
zig build drive         # build the interactive test driver (tools/drive.zig)
zig fmt src tools build.zig  # format
```

The test driver runs a program on a pty and feeds it keystrokes on a schedule,
which is how interactive programs are checked without a human at the keyboard:

```sh
./zig-out/bin/drive -- ./zig-out/bin/zmux attach test-session
```

## Build with Nix

```sh
nix build .#zmux
./result/bin/zmux
```

The build sandbox has no network, so Zig cannot fetch `build.zig.zon`
dependencies there. The flake pre-fetches them in a separate fixed-output
derivation and passes the result to `zig build --system`. That derivation is
keyed by a hash, so after changing a dependency run the build once, take the
hash from the mismatch message, and paste it into `zmuxDeps.outputHash`.

## Layout

```
build.zig           Zig build definition, including libghostty-vt discovery
build.zig.zon       Zig package dependencies (zig-clap)
src/main.zig        entry point and command line parsing
src/vt.zig          the only module that knows libghostty-vt's C ABI
src/pty.zig         pty allocation, child spawning, raw fd I/O
src/terminal.zig    the local terminal: raw mode, the screen renderer, and the
                    status line
src/layout.zig      the pane tree: splits, ratios, rectangle computation, and parking
src/socket.zig      unix sockets and length-prefixed message framing
src/protocol.zig    the client/server message set and its encoding
src/runtime.zig     where the socket lives, and starting a server on demand
src/server.zig      the session registry and its epoll loop
src/client.zig      attach, detach, one terminal per pane, and painting the layout
src/signal.zig      signals delivered as a descriptor, for SIGWINCH
tools/drive.zig     test driver that plays keystrokes into a program
flake.nix           dev shell, package, and formatter
ARCHITECTURE.md     process model, data structures, and design decisions
ROADMAP.md          phase plan and open questions
```

