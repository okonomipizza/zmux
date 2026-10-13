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
# Start a session and attach to it. With no program, starts $SHELL.
zmux run
zmux run htop

# Start one without attaching.
zmux run -d -n build -- make

# See what is running.
zmux ls
# build: 80x24, 1 client(s), pid 4321, running

zmux attach build   # ctrl-a detaches, leaving the program running
zmux kill build
zmux kill-all
```

Inside an attached session the prefix key is `ctrl-a`:

| key | action |
| --- | --- |
| `ctrl-a s` | split the focused pane side by side |
| `ctrl-a v` | split it into stacked halves |
| `ctrl-a q` | close the focused pane |
| `ctrl-a f` | float the focused pane above the layout |
| `ctrl-a d` | dock a floating pane back into the layout |
| `ctrl-a -` | hide the floating panes, or show them again |
| `ctrl-a h` / `k` | move focus to the previous pane |
| `ctrl-a l` / `j` | move focus to the next pane |
| `ctrl-a ctrl-a` | detach, leaving every pane running |

Each pane is its own program on its own pty, so a split gives two shells side by
side. A pane whose program exits keeps its last screen until the pane is closed.

A floating pane is drawn above the layout, centred, and can be put back. Parking it
does not touch its pty, so the program inside carries on without noticing, and the
space it leaves is given to a neighbouring pane that grows into it. Docking asks
which pane to split: the layout freezes, each tiled pane shows a number, and the
number you press is divided along its longer side. Escape cancels.

`ctrl-a -` puts the floating panes away and brings them back. A hidden float keeps
running and keeps its screen; it is simply not drawn, and it cannot take focus, so
nothing is ever typed into a pane you cannot see. Showing them again returns focus
to the pane you were working in before the float appeared.

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
./zig-out/bin/drive -- ./zig-out/bin/zmux run vi /tmp/out.txt
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
src/session.zig     the single-pane event loop from phase 1
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

