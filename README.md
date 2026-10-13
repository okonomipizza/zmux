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

Phases 0, 0.5 and 1 of the roadmap are complete. Escape sequence handling comes
from libghostty-vt, the command line is parsed with
[zig-clap](https://github.com/Hejsil/zig-clap), and a program can be run on a
pty that zmux renders.

```sh
# Run a program on a new pty and render it here. With no program, starts $SHELL.
zmux run
zmux run htop
zmux run vi notes.txt
```

Ctrl-a detaches, leaving the program running; the child is terminated when zmux
exits, since there is no server to hand it to yet.

`dump` parses escape sequences on stdin and prints the resulting screen, which
is useful for inspecting what zmux makes of a byte stream:

```sh
printf 'Hello, \033[1;32mWorld\033[0m!\r\n' | zmux dump
```

The session commands are accepted but have no server behind them yet, so they
report that and exit non-zero. The server and the TUI are phases 2 and 3.

```sh
zmux ls
zmux attach <session>
zmux detach
zmux kill <session>
zmux kill-all
```

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
src/terminal.zig    the local terminal: raw mode, and the screen renderer
src/session.zig     the event loop tying pty, parser and renderer together
tools/drive.zig     test driver that plays keystrokes into a program
flake.nix           dev shell, package, and formatter
ARCHITECTURE.md     process model, data structures, and design decisions
ROADMAP.md          phase plan and open questions
```

