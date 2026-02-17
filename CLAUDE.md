# Claude Notes for Hammerspoon Stepper

## Project Overview

This is a Hammerspoon window management config that provides keyboard-driven window control using fn + modifier + arrow key combinations. It extends the WinWin spoon with smart resize behavior, edge snapping, cross-screen focus, and mouse move support.

## Project Structure

```
stepper/
├── lua/
│   ├── stepper.lua       # Main entry point, key bindings, core window operations
│   ├── focus.lua         # Focus navigation, occlusion detection, visual highlights
│   ├── mousemove.lua     # fn+mouse move/resize windows
│   ├── screenswitch.lua  # Move window to specific display by position
│   └── bear-hud.lua      # Bear note HUD with caret/scroll persistence
├── data/
│   ├── bear-notes.jsonc   # Note hotkey configuration
│   └── bear-hud-positions.json  # Runtime caret/scroll positions (not tracked)
├── docs/                 # Architecture notes and decision records
├── CLAUDE.md             # This file
└── README.md             # User-facing documentation
```

Modules use the standard Lua pattern: return a table of public functions, loaded via `dofile()`.

## Loading from Hammerspoon

The config lives in this Dropbox project folder and is loaded by `~/.hammerspoon/init.lua` via:
```lua
require("hs.ipc")  -- Enable CLI control
dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua")
```

## Reloading Hammerspoon from CLI

IPC must be enabled (`require("hs.ipc")` in init.lua). Use the reload script:

```bash
~/bin/hs-reload.sh
```

The script backgrounds the reload command (to avoid hanging), waits for restart, and verifies completion.

## fn Key Workaround

Hammerspoon cannot bind to `fn` directly. Instead, bind to the key that fn transforms the arrow keys into:

| Physical Keys | Hammerspoon Key |
|--------------|-----------------|
| fn + Left Arrow | `home` |
| fn + Right Arrow | `end` |
| fn + Up Arrow | `pageup` |
| fn + Down Arrow | `pagedown` |
| fn + Delete | `forwarddelete` |

Example:
```lua
-- This responds to fn + cmd + Delete
hs.hotkey.bind({"cmd"}, "forwarddelete", function()
  -- ...
end)
```

## Key Bindings Pattern

The project uses a consistent modifier escalation pattern:
- No extra modifier: move window
- shift: resize
- ctrl: snap to edge
- ctrl+shift: resize to edge
- option: shrink/unshrink
- shift+option: center/maximize/half-third toggles
- cmd: focus window on same screen
- option+cmd: focus window on adjacent screen

## Documentation

**Important**: When adding or changing key bindings or user-facing behavior, always update README.md to reflect the changes. The README serves as the user-facing documentation for all operations.
