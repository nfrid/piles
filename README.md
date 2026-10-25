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
- **move windows around** - move the focused window to a numbered workspace
  without leaving your current workspace, move to the previous/next occupied
  workspace and follow it, or move to another monitor
- **multi-monitor** - each display has its own workspace set; the menubar shows
  the focused monitor when more than one is connected
- **menubar indicator** - compact badge widgets show the active workspace and
  occupied workspaces
- **monocle switcher** - hold option in monocle layout to show the focused
  window and its neighbors by title
- **workspace overview** - option+o opens an 80% screen grid of workspaces and
  window titles; h/l move by column, j/k move by row, return or m to open, o to glance
  the selected workspace, esc to close
- **workspace glance** - option+shift+o opens the same style overlay for windows on
  the current workspace only; navigate and focus without leaving the workspace
- **app switcher follow** - command-tab to a hidden workspace window reveals the
  workspace that owns it
- **window assignment rules** - place windows by app, bundle id, exact title, or
  partial title via `[[assign]]` entries
- **custom keybindings** - configure built-in bindings, the global modifier, and
  custom shell commands
- **config reload** - reload the config from the menubar without restarting
- **ipc control** - `piles-ctl` sends commands over a unix socket so tools like
  Hammerspoon can trigger actions without faking key events
- **diagnostics and recovery** - inspect tracked state, validate configuration,
  rescan windows, or restore offscreen windows after a crash
- **clean shutdown** - windows are brought back onscreen on quit, SIGTERM, SIGINT,
  and normal process exit. SIGKILL and fatal crashes bypass this cleanup

## Controls

The default modifier is option. You can change it to `control` or `command` in
`~/.config/piles/config.toml`.

| Keys                                     | Action                                                    |
| ---------------------------------------- | --------------------------------------------------------- |
| option+1-9                               | switch to workspace                                       |
| option+shift+1-9                         | move focused window to workspace (stay on current)        |
| option+h / option+l                      | switch to previous / next occupied workspace              |
| option+shift+h / option+shift+l          | move focused window to previous / next occupied workspace and follow it     |
| option+tab                               | switch to last workspace                                  |
| option+j / option+k                      | focus next / previous window                              |
| option+shift+j / option+shift+k          | move focused window next / previous                       |
| option+return                            | swap focused window into master                           |
| option+m                                 | toggle monocle / tile on the active workspace             |
| option+p                                 | pause / resume automatic tiling                           |
| option+f                                 | toggle floating for the focused window                    |
| option+comma / option+period             | focus previous / next monitor                             |
| option+shift+comma / option+shift+period | move focused window to previous / next monitor            |
| option+shift+return                      | run the default custom command: `open -n -a Terminal`     |
| option+drag tile divider                 | resize the master area                                    |
| option+o                                 | toggle workspace overview (all workspaces)                |
| option+shift+o                           | toggle workspace glance (current workspace windows)       |
| option+q                                 | close the focused window (app stays running)              |

## Config

Config is optional and lives at `~/.config/piles/config.toml`. The parser supports
the subset used in `config.example.toml`: quoted strings, numbers, booleans,
tables, and arrays of tables. Start from that file:

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
toggle_pause = "p"
toggle_floating = "f"
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

## Pause and floating windows

Use option+p or the menu's Pause Tiling / Resume Tiling item to pause. The menu
bar shows `paused`. IPC has the same controls:

```bash
piles-ctl pause
piles-ctl resume
piles-ctl toggle
```

Pause stops automatic tiling, corrective resize, and master-divider dragging.
Workspace switching and focus commands still work. Windows on inactive
workspaces stay hidden; when switching while paused, piles restores their saved
position and size rather than applying a layout. Resume discovers windows again
and retiles active workspaces. Pause is temporary and does not survive a restart.

Use option+f, the menu's Floating Window item, or these commands for the focused
tracked window:

```bash
piles-ctl window floating toggle
piles-ctl window floating on
piles-ctl window floating off
```

Floating windows keep their workspace, focus order, and entry in the window
lists. They do not take a tile slot and piles does not correct their manual
position or size. Switching workspaces hides and restores them with their saved
geometry. Switching floating off puts the window back into the current layout,
unless tiling is paused. Per-window choices last for the lifetime of that window.

Set the initial mode of newly discovered windows with existing assignment rules:

```toml
[[assign]]
bundle_id = "com.apple.calculator"
floating = true
```

The first matching rule still wins. `floating = false` explicitly starts windows
in tiling mode. A floating-only rule does not move the window to another monitor.
Reloading config does not override manual choices for windows already tracked.

## IPC (`piles-ctl`)

When piles is running, it listens on a unix socket (default
`~/.config/piles/socket`). `make build`, `make install`, and `make start` symlink
`piles-ctl` into `~/.local/bin` (add that directory to your `PATH` if needed).
After `make install`, the symlink points at the copy inside
`/Applications/piles.app`; after `make build` alone, it points at
`.build/release/piles-ctl`.

```bash
piles-ctl ping
piles-ctl workspace next
piles-ctl workspace prev
piles-ctl overview
piles-ctl glance
piles-ctl workspace 3
piles-ctl workspace 3 --move
```

Commands mirror hotkey actions: `workspace last`, `focus next|prev`,
`window move next|prev`, `window close`, `layout toggle`, `master swap`,
`monitor focus next|prev`, `monitor move next|prev`.

IPC commands have a two-second timeout. Existing files and active sockets at the
configured path are not overwritten. Only one piles instance can manage windows
at a time, even with IPC disabled.

Disable or relocate the socket in config, then use Reload Config:

```toml
ipc_enabled = true
ipc_socket = "~/.config/piles/socket"
```

Hammerspoon example (requires `piles-ctl` on `PATH` from `make install`):

```lua
local ctl = "piles-ctl"
hs.eventtap.new({hs.eventtap.event.types.gesture}, function(e)
  if e:getGestureType() == "swipe" and e:getProperty(hs.eventtap.properties.gestureFingerCount) == 4 then
    local dir = e:getProperty(hs.eventtap.properties.gestureDirection)
    if dir == 3 then hs.execute(ctl .. " workspace prev") end
    if dir == 4 then hs.execute(ctl .. " workspace next") end
    if dir == 1 then hs.execute(ctl .. " overview") end
  end
end):start()
```

## Diagnostics and recovery

Read-only commands return one JSON object:

```bash
piles-ctl status
piles-ctl windows
```

`status` reports `paused` and lists monitors and their workspaces, layouts, and window counts.
`focused_monitor`, monitor indices, workspace indices, and `active_workspace`
are 1-based. `windows` lists tracked windows in monitor/workspace/stack order,
including windows on inactive workspaces. Each window has its PID, monitor,
workspace, a `floating` flag, and an `active` flag that means its workspace is active on that
monitor. App name, bundle ID, title, and frame are optional when unavailable.
Frame coordinates use the Accessibility coordinate system, with the origin at
the primary display's top-left corner; offscreen positions can be negative.
These commands do not move or focus windows.

Validate a config without contacting or changing the running app:

```bash
piles-ctl config validate
piles-ctl config validate config.example.toml
```

Validation reports syntax errors, unknown keys, wrong types, and invalid values
that would otherwise fall back to defaults. Exit code 0 means valid, 1 means a
validation or read failure, and 2 means invalid command arguments. A missing
optional default config is valid and uses defaults; an explicitly supplied
missing path is an error.

Ask the running app to discover windows again:

```bash
piles-ctl rescan
```

Rescan preserves existing window assignments and ordering. It applies assignment
rules to newly discovered windows and retiles active workspaces. Its JSON report
has `discovered_windows` and `unavailable_apps`; unavailable apps retain their
previously tracked windows unless AX confirms that they are invalid or no longer
trackable, such as a window that has become a dialog. Missing AX data alone does
not remove a window.

After quitting piles, or after a crash, restore offscreen windows with:

```bash
piles-ctl rescue
```

Rescue launches the main `piles` executable beside `piles-ctl` in one-shot mode.
It refuses to run while another piles instance holds the lock, even if IPC is
disabled. It uses the main executable's Accessibility permission and does not
start hotkeys, IPC, or tiling. Fully onscreen windows stay unchanged; other
windows move inside the display with the largest overlap, or the nearest display
if completely offscreen. Window sizes are preserved. Fullscreen, minimized, and
hidden applications' windows are not brought out of those states.

The report separates restored, skipped, and failed windows, plus applications
whose window lists could not be read. Partial failures return exit code 1.
Rescue exits when finished; launch piles normally afterwards. The equivalent
direct command is `/Applications/piles.app/Contents/MacOS/piles --rescue`.

## Development

```bash
make test
make build
```

The test target is a small executable, not XCTest. `make test` also builds the
CLI and tests it with temporary configs and a fake rescue executable. Recovery
geometry tests use injected window data; no test moves real windows. The
benchmark's window tracking uses mocked AppleScript calls.

`make benchmark` opens temporary Terminal windows for its workload and closes
only those windows on completion or interruption. Existing Terminal windows are
left alone. Avoid adding your own tabs to benchmark windows while it runs.

## License

MIT
