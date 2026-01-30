# Claude Notes for Hammerspoon Stepper

## Project Overview

This is a Hammerspoon window management config (`stepper.lua`) that provides keyboard-driven window control using fn + modifier + arrow key combinations. It extends the WinWin spoon with smart resize behavior, edge snapping, cross-screen focus, and mouse drag support.

The config lives in this Dropbox project folder but is loaded by `~/.hammerspoon/init.lua` via:
```lua
require("hs.ipc")  -- Enable CLI control
dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper.lua")
```

## Reloading Hammerspoon from CLI

IPC must be enabled (`require("hs.ipc")` in init.lua). Then reload with:

```bash
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "hs.reload()" &>/dev/null & sleep 0.2; /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "return 'ready'"
```

Key points:
- The `&` after reload is critical - it backgrounds the command so it doesn't hang waiting for a response from the reloading process
- `&>/dev/null` suppresses the expected "message port invalidated" error
- 0.2s sleep is enough for Hammerspoon to restart
- The second `hs` command verifies the reload completed

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
-- This responds to fn + ctrl + option + Delete
hs.hotkey.bind({"ctrl", "option"}, "forwarddelete", function()
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
- ctrl+option: focus window on same screen
- ctrl+option+cmd: focus window on adjacent screen
- cmd: compact/max-height/max-width/fullscreen toggles

## Documentation

**Important**: When adding or changing key bindings or user-facing behavior, always update README.md to reflect the changes. The README serves as the user-facing documentation for all operations.
