# piles

Highly opinionated and tiny window / workspace manager for MacOS.

Based on [parket](https://github.com/basuev/parket).

## Install

Build from source as I don't intend to publish it to brew:

```bash
make install
open /Applications/parket.app
```

Grant permissions in System Settings -> Privacy & Security when prompted, then
relaunch.

## Requirements

- macOS 14+, Apple Silicon
- Accessibility permission
- Input monitoring permission

## Features

- **workspaces** - up to 9 virtual workspaces via offscreen window hiding
- **monocle by default** - new workspaces start fullscreen; set
  `default_layout = "tile"` to use master-stack tiling by default
- **master-stack tiling** - dwm-style master/stack layout with configurable
  master width
- **per-workspace layouts** - toggle the active workspace between monocle and
  tile with option+m
- **monocle position indicator** - the menu bar shows focused window position
  and total window count, e.g. `2/5`
- **workspace navigation** - option+h/l jumps to the previous/next occupied
  workspace; add shift to move the focused window there
- **move-and-follow workspace keys** - option+1-9 moves the focused window to
  that workspace and switches to it
- **menubar indicator** - badge widgets show active workspace and occupied ones
- **custom keybindings** - configure built-in bindings and custom shell
  commands via `~/.config/piles/config.toml`
- **multi-monitor** - per-display workspaces, each monitor has its own workspace
  set
- **app switcher follow** - command+tab to a hidden workspace window opens that
  workspace
- **crash safety** - all windows restore on exit

## License

MIT
