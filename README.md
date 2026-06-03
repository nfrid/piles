# piles

Highly opinionated and tiny window / workspace manager for macOS.

Based on [parket](https://github.com/basuev/parket).

## For whom

This project is mainly made for myself. Feel free to fork it and make your own.
It is not trying to be a general purpose tiling window manager.

## Install

Build from source as I don't intend to publish it to brew.

```bash
make install
open /Applications/piles.app
```

Grant permissions in System Settings -> Privacy & Security when prompted, then
relaunch. You can also use `make start` during development to rebuild,
reinstall, restart the running app, and open it.

## Requirements

- macOS 14+, Apple Silicon
- Accessibility permission
- Input monitoring permission

## Features

- **workspaces** - 1 to 9 virtual workspaces, implemented by moving inactive
  windows offscreen
- **monocle by default** - new workspaces use monocle layout; set
  `default_layout = "tile"` for master-stack tiling by default
- **master-stack tiling** - dwm-style master/stack layout with configurable
  master width; drag the divider with the modifier key held to resize it
- **per-workspace layouts** - toggle the active workspace between monocle and
  tile
- **window focus and ordering** - cycle focus, move the focused window through
  the stack, and swap the focused window into master
- **workspace navigation** - jump directly by number, jump to the previous/next
  occupied workspace, or jump back to the last workspace
- **move windows around** - move the focused window to a numbered workspace, to
  the previous/next occupied workspace, or to another monitor
- **multi-monitor** - each display has its own workspace set; the menubar shows
  the focused monitor when more than one is connected
- **menubar indicator** - compact badge widgets show the active workspace and
  occupied workspaces
- **monocle switcher** - hold option in monocle layout to show the focused
  window and its neighbors by title
- **workspace overview** - option+o opens an 80% screen grid of workspaces and
  window titles; h/l move by column, j/k move by row, return or m to open, esc to close
- **app switcher follow** - command-tab to a hidden workspace window reveals the
  workspace that owns it
- **window assignment rules** - place windows by app, bundle id, exact title, or
  partial title via `[[assign]]` entries
- **custom keybindings** - configure built-in bindings, the global modifier, and
  custom shell commands
- **config reload** - reload the config from the menubar without restarting
- **crash safety** - windows are brought back onscreen on quit, SIGTERM, SIGINT,
  and normal process exit

## Controls

The default modifier is option. You can change it to `control` or `command` in
`~/.config/piles/config.toml`.

| Keys                                     | Action                                                    |
| ---------------------------------------- | --------------------------------------------------------- |
| option+1-9                               | switch to workspace                                       |
| option+shift+1-9                         | move focused window to workspace and follow it            |
| option+h / option+l                      | switch to previous / next occupied workspace              |
| option+shift+h / option+shift+l          | move focused window to previous / next occupied workspace |
| option+tab                               | switch to last workspace                                  |
| option+j / option+k                      | focus next / previous window                              |
| option+shift+j / option+shift+k          | move focused window next / previous                       |
| option+return                            | swap focused window into master                           |
| option+m                                 | toggle monocle / tile on the active workspace             |
| option+comma / option+period             | focus previous / next monitor                             |
| option+shift+comma / option+shift+period | move focused window to previous / next monitor            |
| option+shift+return                      | run the default custom command: `open -n -a Terminal`     |
| option+drag tile divider                 | resize the master area                                    |
| option+o                                 | toggle workspace overview                                 |

## Config

Config is optional and lives at `~/.config/piles/config.toml`. Start from
`config.example.toml`:

```bash
mkdir -p ~/.config/piles
cp config.example.toml ~/.config/piles/config.toml
```

Useful options:

```toml
workspace_count = 9
master_ratio = 0.55
default_layout = "monocle"
modifier = "option"
```

You can remap built-in actions:

```toml
[bindings]
focus_next = "j"
focus_prev = "k"
toggle_layout = "m"
last_workspace = "tab"
```

Add shell commands:

```toml
[[custom]]
key = "shift+return"
command = "open -n -a Terminal"
```

Assign new windows:

```toml
[[assign]]
bundle_id = "com.apple.Safari"
title_contains = "Developer"
monitor = 1
workspace = 2
position = 1
```

First matching assignment wins. `monitor`, `workspace`, and `position` are
1-based.

## Development

```bash
make test
make build
```

The test target is a small executable, not XCTest.

## License

MIT
