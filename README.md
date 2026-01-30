# Hammerspoon Stepper

Window management with smart edge-aware resizing using fn + arrow key combinations.

## Philosophy

Stepper is built around **interactive steps, not preset sizes**. Instead of snapping to halves, thirds, or other fixed layouts, you build window arrangements through small, reversible increments.

- **Piecemeal**: Each keypress makes a small change. Repeat to continue.
- **Reversible**: Every action can be undone by the opposite action.
- **No presets**: No half-screen, no thirds, no memorized layouts. Just steps.
- **Edge-aware**: Windows "stick" to edges and behave intelligently at boundaries.
- **Instant**: No animations. All operations happen immediately.

### Why Not a Tiling Manager?

Traditional tiling managers offer two extremes: rigid presets ("snap to left half") or complete tiling tyranny (every window must tile, no overlap allowed). Stepper takes a different path:

- **Iterative**: Both position and size are adjusted incrementally. Hold the key to keep going.
- **Overlapping-friendly**: Windows can overlap naturally. No forced tiling grid.
- **Organic layouts**: Your arrangement emerges from small adjustments, not preset templates.
- **Context-aware**: The same key does different things depending on where your window is.

The result feels more like sculpting than snapping.

## Key Bindings

All bindings use **fn + modifier + arrow keys** (Home/End/PageUp/PageDown):

| Modifier | Action | Keys |
|----------|--------|------|
| *(none)* | Move window | fn + arrows |
| **shift** | Smart resize | fn + shift + arrows |
| **ctrl** | Move to edge | fn + ctrl + arrows |
| **ctrl+shift** | Resize to edge | fn + ctrl + shift + arrows |
| **option** | Shrink/unshrink | fn + option + arrows |
| **ctrl+option** | Focus direction | fn + ctrl + option + arrows |
| **ctrl+option+cmd** | Focus across screens | fn + ctrl + option + cmd + arrows |
| **shift+option** | Center/maximize toggle | fn + shift + option + up/down |
| **shift+option** | Half/third cycle | fn + shift + option + left/right |
| **cmd** | Compact/expand toggles | fn + cmd + arrows |

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

### Why This Complexity?

Without this logic, resizing a window that fills the screen would push it to another monitor. The smart resize ensures:
- Windows "stuck" at an edge stay stuck while resizing
- Each direction can undo the other's action
- Full-size windows won't accidentally jump to another screen

## Other Operations

### Move to Edge (fn + ctrl + arrows)
Moves the window to touch the specified screen edge without resizing.
**Reversible**: Press again when already at that edge to restore previous position.

### Resize to Edge (fn + ctrl + shift + arrows)
Expands the window to fill from its current position to the specified edge.
**Reversible**: Press again when already at that edge to restore previous size.

### Shrink/Grow (fn + option + arrows)
- **left**: Toggle shrink width to minimum (press again to restore)
- **up**: Toggle shrink height to minimum (press again to restore)
- **right**: Restore shrunk width, or grow to right edge if not shrunk (toggle)
- **down**: Restore shrunk height, or grow to bottom edge if not shrunk (toggle)

### Focus Direction (fn + ctrl + option + arrows)
Focus the nearest window in that direction (on the same screen):
- **left/right**: based on window's left edge (x position)
- **up/down**: based on window's top edge (y position)
- Wraps around: keep pressing to cycle through all windows on the screen

### Focus Across Screens (fn + ctrl + option + cmd + arrows)
Jump to an adjacent screen, focusing the window closest to where you came from:
- **left**: go to left screen, focus window with rightmost edge
- **right**: go to right screen, focus window with leftmost edge
- **up**: go to upper screen, focus window with bottommost edge
- **down**: go to lower screen, focus window with topmost edge

### Center Toggle (fn + shift + option + up)
Progressive centering:
1. First press: center vertically
2. Second press: center horizontally
3. Third press: restore previous position

### Maximize Toggle (fn + shift + option + down)
- Press to maximize window to fill screen
- Press again to restore previous size and position

### Half/Third Cycle (fn + shift + option + left/right)
Cycle through edge-aligned layouts:
1. First press: half-width, full-height, aligned to that edge
2. Second press: third-width, full-height, aligned to that edge
3. Third press: restore previous size and position

### Compact Mode (fn + cmd + left)
Shrink window to a small size and dock it at the bottom of the screen.
- Works like a minimized dock: windows line up left-to-right at the screen bottom
- Each new compact window appears to the right of existing ones
- Wraps to the row above when the bottom row is full
- Press again to restore original size and position
- App-specific minimum sizes are respected (see `minShrinkSize` in config)

### Max Height (fn + cmd + up)
Expand window to full screen height while keeping width and horizontal position.
**Reversible**: Press again to restore previous height.

### Max Width (fn + cmd + right)
Expand window to full screen width while keeping height and vertical position.
**Reversible**: Press again to restore previous width.

### Native Fullscreen (fn + cmd + down)
Toggle macOS native fullscreen mode (with the green button animation).

## Mouse Drag

Hold **cmd + option + ctrl** and drag to move the window under the cursor.
Useful for apps where other window managers don't work (Kitty, Bear, etc.).

## Dependencies

- [WinWin Spoon](http://www.hammerspoon.org/Spoons/WinWin.html)
