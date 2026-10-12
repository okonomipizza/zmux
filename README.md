# zmux

A simple terminal multiplexer.

## Features

- **Simple** — a small, focused feature set rather than a tmux clone.
- **Persistent floating panes** — panes that float above the layout and survive
  detaching.
- **Swappable workspace panes** — rearrange the panes of the current workspace.

## Development

A development shell with a pinned Zig toolchain is provided via
[mitchellh/zig-overlay](https://github.com/mitchellh/zig-overlay).

```sh
nix develop
```

The shell provides `zig` and `zls`. Both are pinned to the same release
(`0.16.0`); `zls` only works against the exact Zig release it was built for, so
keep the two in sync.

Common commands:

```sh
zig build              # build into ./zig-out/bin/zmux
zig build run          # build and run
zig build test         # run unit tests
```

## Build with Nix

```sh
nix build .#zmux
./result/bin/zmux
```

## Layout

```
build.zig       Zig build definition
src/main.zig    entry point
flake.nix       dev shell, package, and formatter
```
