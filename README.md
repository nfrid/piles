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

TODO: update to my own list

- **workspaces** - 9 virtual workspaces via offscreen window hiding
- **master-stack tiling** - new windows auto-tile in dwm-style layout
- **monocle layout** - per-workspace fullscreen mode, toggle with option+m
- **menubar indicator** - badge widgets show active workspace and occupied ones
- **custom keybindings** - bind any key combo to shell commands via toml config
- **multi-monitor** - per-display workspaces, each monitor has its own workspace
  set
- **app switcher follow** - command+tab to a hidden workspace window opens that
  workspace
- **crash safety** - all windows restore on exit

## License

MIT
