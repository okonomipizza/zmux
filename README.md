# zmux

A simple terminal multiplexer.

## Features

- **Simple** — a small, focused feature set rather than a tmux clone.
- **Persistent floating panes** — panes that float above the layout and survive
  detaching.
- **Swappable workspace panes** — rearrange the panes of the current workspace.
- **Configurable keys and colours** — rebound prefix commands, and colours for
  the borders and the status line.

Escape sequence handling is delegated to
[libghostty-vt](https://github.com/ghostty-org/ghostty), the VT library
extracted from [Ghostty](https://ghostty.org). zmux owns the pty, the server
and the TUI. See [ARCHITECTURE.md](ARCHITECTURE.md) for the reasoning and
[ROADMAP.md](ROADMAP.md) for what is built and what is planned.

## Configuration

The first time zmux attaches to a session it writes a configuration file with
every setting at its default, and reads it from then on:

```
$XDG_CONFIG_HOME/zmux/config.json     # or ~/.config/zmux/config.json
```

It is a flat JSON object of dotted names to strings. Delete a line to keep that
setting's default, or change its value; a setting that is absent falls back to
its default, so a file holding only what you changed is valid. An unreadable or
malformed file is the defaults rather than a failure, and a name this build does
not know is ignored, so one mistyped line does not cost you the rest.

Keys are single characters. Colours are `#rrggbb`:

```json
{
  "keybind.close": "Q",
  "keybind.scroll": "z",
  "border.active.fg": "#7ca86c",
  "border.inactive.fg": "null",
  "status.bg": "#2e3440",
  "status.fg": "#d8dee9"
}
```

`border.inactive.fg` is `null` by default, meaning an unfocused pane's frame
keeps whatever the terminal is doing rather than being given a colour of its
own. The other colours always have a value.

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

Inside an attached session the prefix key is `ctrl-b`:

| key | action |
| --- | --- |
| `ctrl-b \` | split the focused pane side by side |
| `ctrl-b -` | split it into stacked halves |
| `ctrl-b q` | close the focused pane |
| `ctrl-b F` | float the focused pane above the layout |
| `ctrl-b d` | dock a floating pane back into the layout |
| `ctrl-b f` | hide the floating panes, or show them again |
| `ctrl-b h` / `k` | move focus to the previous pane |
| `ctrl-b l` / `j` | move focus to the next pane |
| `ctrl-b <` / `>` | move the focused pane past its neighbour |
| `ctrl-b o` | rotate every pane one place along |
| `ctrl-b w` | list the sessions and switch to one |
| `ctrl-b x` | read the focused pane's history |
| `ctrl-b ctrl-b` | detach, leaving every pane running |

`ctrl-b x` opens the focused pane's scrollback for reading. `j` and `k` move a
line at a time, `J` and `K` ten, `ctrl-d` and `ctrl-u` half a screen, `ctrl-f`
and `ctrl-v` a whole one, `g` and `G` go to the ends, and `q` or Escape leaves.
Nothing is detached and the program keeps running: only the viewport moves, so
what you are reading is the pane's own history rather than a copy of it.

While the history is open the pane stops following new output, because a
viewport that moved under the reader would be unreadable. Typing anything puts
it back at the bottom first, so the program's answer is visible rather than
arriving below the view. A pane with no history to show is left alone: a mode
that opened onto a frozen screen would read as the program hanging.

`ctrl-b w` lists the sessions in the same window, numbered from one. Type a
number and press Enter to move to that session, or Escape to stay where you
are. Nothing is detached and no pane is closed: the session being left keeps
running, and its panes are still there when you come back. The list is asked for
each time the menu opens, so a session started in another terminal is there and
one whose last pane exited is not.

`ctrl-b <` and `ctrl-b >` swap the focused pane with the pane beside it in the
layout's order, which is the same order the focus keys walk. `ctrl-b o` shifts
every pane one place along instead, last to first. Neither changes the shape of
the layout: the split ratios you built stay as they are, and only which pane sits
where changes. The programs inside are not disturbed beyond being resized to
their new rectangles, so a swap costs nothing but a redraw.

Each pane is its own program on its own pty, so a split gives two shells side by
side. A pane is drawn with a border around it, and the program is given the area
inside that border rather than the whole rectangle, so its own wrapping agrees with
what you see. A tiled pane whose program exits is closed and its space given to a
neighbour, and so is one closed with `ctrl-b q`. When it is the last pane the
session goes with it: a session with nothing to draw has nothing to attach to, so
the client is told it ended and returns to the terminal zmux was started from.

A floating pane is drawn above the layout, centred, and can be put back. Parking it
does not touch its pty, so the program inside carries on without noticing, and the
space it leaves is given to a neighbouring pane that grows into it. Docking asks
which pane to split: the layout freezes, each tiled pane shows a number, and the
number you press is divided along its longer side. Escape cancels.

A float whose program exits is kept rather than closed, with an `exited` badge on
its top edge. The output it leaves behind is usually why it was being consulted,
and a float occupies no space the layout would reclaim, so it stays until you close
it with `ctrl-b q`. A tiled pane is different: its space belongs to the layout, so
it is closed and a neighbour grows into the room.

`ctrl-b f` puts the floating panes away and brings them back. A hidden float keeps
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

Detaching is not the same as the server dying. If the server itself exits, every
program in every session goes with it and nothing comes back: the panes, the
scrollback and the programs' own state are gone, and a client that was attached
says so and returns to the terminal zmux was started from. The library zmux draws
with cannot export a screen, so there is nothing to save and restore. tmux behaves
the same way.

A key the prefix does not use does nothing at all. It used to detach, which meant
a mistyped key ended the client and lost the session with it; tmux ignores the
key, and the prefix is spent either way, so the next keystroke is an ordinary one
whether or not the key after it was understood.

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

Not yet built: copy mode. `zmux detach` outside
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

## Install

With a flake, by attribute path:

```nix
inputs.zmux.url = "github:okonomipizza/zmux";

home.packages = [ inputs.zmux.packages.${pkgs.system}.zmux ];
```

Or as an overlay, which makes `pkgs.zmux` exist like any other package:

```nix
nixpkgs.overlays = [ inputs.zmux.overlays.default ];

home.packages = [ pkgs.zmux ];
```

The overlay carries the Zig overlay it needs along with it, so it is the only
one to add.

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

