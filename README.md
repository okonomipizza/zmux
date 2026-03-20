# zmux

A terminal multiplexer written in Zig, powered by [Ghostty](https://github.com/ghostty-org/ghostty)'s virtual terminal emulation library.

## Features

- **Workspace management** -- up to 9 workspaces, switchable by number or cycling
- **Pane splitting** -- vertical / horizontal splits with a tree-based layout
- **Pane operations** -- navigate, swap, resize, close, move across workspaces
- **Floating pane** -- overlay pane toggled per workspace
- **Scroll mode** -- vi-style scrollback navigation
- **Copy mode** -- vi-style visual selection, yank, and paste
- **Clipboard integration** -- OSC 52 for system clipboard (works through SSH / VMs)
- **Bracketed paste** -- safe handling of pasted content

## Requirements

- Zig >= 0.15.1
- Linux (uses epoll and POSIX PTY)
- A terminal emulator that supports OSC 52 for clipboard (e.g. Ghostty, iTerm2, kitty)

## Build

```sh
zig build
```

The binary is placed at `zig-out/bin/zmux`.

```sh
zig build run
```

## Key Bindings

The prefix key is **Ctrl-b**. Press it first, then a command key.

### General

| Key | Action |
|-----|--------|
| `Ctrl-b` `q` | Quit zmux |
| `Ctrl-b` `Enter` | Cancel prefix mode |

### Workspaces

| Key | Action |
|-----|--------|
| `Ctrl-b` `n` | New workspace |
| `Ctrl-b` `i` | Next workspace (repeatable) |
| `Ctrl-b` `u` | Previous workspace (repeatable) |
| `Ctrl-b` `1`-`9` | Switch to workspace N |
| `Ctrl-b` `m` `1`-`9` | Move active pane to workspace N |

### Panes

| Key | Action |
|-----|--------|
| `Ctrl-b` `\` | Split vertically |
| `Ctrl-b` `-` | Split horizontally |
| `Ctrl-b` `h` / `j` / `k` / `l` | Focus pane left / down / up / right (repeatable) |
| `Ctrl-b` `H` / `J` / `K` / `L` | Swap pane left / down / up / right (repeatable) |
| `Ctrl-b` `>` / `<` | Resize pane larger / smaller (repeatable) |
| `Ctrl-b` `x` | Close active pane |
| `Ctrl-b` `f` | Toggle floating pane |

### Scroll Mode

| Key | Action |
|-----|--------|
| `Ctrl-b` `s` | Enter scroll mode |
| `j` / `k` | Scroll down / up |
| `Enter` | Exit scroll mode |

### Copy Mode

| Key | Action |
|-----|--------|
| `Ctrl-b` `c` | Enter copy mode |
| `h` / `j` / `k` / `l` | Move cursor |
| `w` / `b` | Next / previous word |
| `0` / `$` | Beginning / end of line |
| `g` / `G` | Top / bottom of screen |
| `Ctrl-u` / `Ctrl-d` | Half page up / down |
| `v` | Start visual selection |
| `y` | Yank selection to clipboard and exit |
| `q` / `Escape` | Exit copy mode |
| `Ctrl-b` `p` | Paste from clipboard |

Yanked text is copied to the system clipboard via OSC 52, so it works across SSH sessions and VMs (e.g. macOS host + Multipass Ubuntu guest).


## Configuration

UI colors can be customized via `~/.config/zmux/zmux.jsonc`. Create the file and set any of the following properties:

```jsonc
{
  // Border colors
  "active_border_color": "green",       // default: green
  "inactive_border_color": "bright_black", // default: bright_black

  // Copy mode cursor
  "copy_cursor_fg": "black",            // default: black
  "copy_cursor_bg": "yellow",           // default: yellow

  // Status bar
  "status_bg": "bright_black",          // default: bright_black
  "status_fg": "white",                 // default: white

  // Active workspace indicator
  "active_workspace_bg": "green",       // default: green
  "active_workspace_fg": "black",       // default: black

  // Mode label (e.g. SCROLL, COPY)
  "mode_label_bg": "yellow",            // default: yellow
  "mode_label_fg": "black"              // default: black
}
```

Available colors: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `bright_black`, `bright_red`, `bright_green`, `bright_yellow`, `bright_blue`, `bright_magenta`, `bright_cyan`, `bright_white`

Unrecognized or missing keys are silently ignored and fall back to their defaults.

## License
MIT
