# Hammerspoon Stepper

Window management with smart edge-aware resizing using fn + arrow key combinations.

## Key Bindings

All bindings use **fn + modifier + arrow keys** (Home/End/PageUp/PageDown):

| Modifier | Action | Keys |
|----------|--------|------|
| *(none)* | Move window | fn + arrows |
| **shift** | Smart resize | fn + shift + arrows |
| **ctrl** | Move to edge | fn + ctrl + arrows |
| **ctrl+shift** | Resize to edge | fn + ctrl + shift + arrows |
| **option** | Shrink/unshrink | fn + option + arrows |

## Smart Resize Behavior (fn + shift + arrows)

The smart resize adapts based on which screen edges the window is touching.

### Horizontal (left/right)

| Window Position | fn+shift+left | fn+shift+right |
|-----------------|---------------|----------------|
| **Full width** (both edges) | shrink from left | shrink from right |
| **At left edge only** | grow rightward | shrink from right |
| **At right edge only** | shrink from left | grow leftward |
| **Middle** (no edge) | shrink from right | grow rightward |

### Vertical (up/down)

| Window Position | fn+shift+up | fn+shift+down |
|-----------------|-------------|---------------|
| **Full height** (both edges) | shrink from top | shrink from bottom |
| **At top edge only** | grow downward | shrink from bottom |
| **At bottom edge only** | shrink from top | grow downward |
| **Middle** (no edge) | shrink from bottom | grow downward |

### Design Philosophy

- **Edge-aware**: When a window is "stuck" at an edge, resizing keeps it stuck there
- **Reversible**: Each direction can undo the other's action
- **No screen jumping**: Full-size windows won't accidentally move to another screen

## Other Operations

### Move to Edge (fn + ctrl + arrows)
Moves the window to touch the specified screen edge without resizing.

### Resize to Edge (fn + ctrl + shift + arrows)
Expands the window to fill from its current position to the specified edge.

### Shrink/Unshrink (fn + option + arrows)
- **left/up**: Shrink to minimum width/height
- **right/down**: Restore to previous size

## Mouse Drag

Hold **cmd + option + ctrl** and drag to move the window under the cursor.
Useful for apps where other window managers don't work (Kitty, Bear, etc.).

## Dependencies

- [WinWin Spoon](http://www.hammerspoon.org/Spoons/WinWin.html)
