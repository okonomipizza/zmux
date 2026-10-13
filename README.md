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

Phase 0 of the roadmap is complete: libghostty-vt is integrated, and VT data
can be parsed and rendered as text.

```sh
# Parse escape sequences on stdin and print the resulting screen.
printf 'Hello, \033[1;32mWorld\033[0m!\r\n' | zmux dump
```

There is no pty, server or TUI yet; those are phases 1 to 3.

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
zig build              # build into ./zig-out/bin/zmux
zig build run          # build and run
zig build test         # run unit tests
zig fmt src build.zig  # format
```

## Build with Nix

```sh
nix build .#zmux
./result/bin/zmux
```

## Layout

```
build.zig        Zig build definition, including libghostty-vt discovery
src/main.zig     entry point and the `dump` command
src/vt.zig       the only module that knows libghostty-vt's C ABI
flake.nix        dev shell, package, and formatter
ARCHITECTURE.md  process model, data structures, and design decisions
ROADMAP.md       phase plan and open questions
```

