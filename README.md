# Hammerspoon Stepper

Non-tiling window manager based around graceful moves.

## Philosophy

Stepper is built around **interactive steps, not preset sizes**. Instead of snapping to halves, thirds, or other fixed layouts, you build window arrangements through small, reversible increments.

- **Piecemeal**: Each keypress makes a small change. Repeat to continue.
- **Reversible**: Every action can be undone by the opposite action.
- **No presets**: No half-screen, no thirds, no memorized layouts. Just steps.
- **Predictable**: The same key always does the same thing, regardless of window position.
- **Instant**: No animations. All operations happen immediately.

### Why Not a Tiling Manager?

Traditional tiling managers offer two extremes: rigid presets ("snap to left half") or complete tiling tyranny (every window must tile, no overlap allowed). Stepper takes a different path:

- **Iterative**: Both position and size are adjusted incrementally. Hold the key to keep going.
- **Overlapping-friendly**: Windows can overlap naturally. No forced tiling grid.
- **Organic layouts**: Your arrangement emerges from small adjustments, not preset templates.
- **Predictable**: The same key always does the same thing. No hidden modes or position-dependent behavior.

The result feels more like sculpting than snapping.

## Key Bindings

All bindings use **fn + modifier + arrow keys** (Home/End/PageUp/PageDown):

| Modifier | Action | Keys |
|----------|--------|------|
| *(none)* | Step move | fn + arrows |
| **shift** | Step resize | fn + shift + arrows |
| **ctrl** | Move to screen edge | fn + ctrl + arrows |
| **ctrl+shift** | Resize to screen edge | fn + ctrl + shift + arrows |
| **option** | Shrink/unshrink | fn + option + arrows |
| **cmd** | Focus within current screen | fn + cmd + arrows |
| **option+cmd** | Focus across screens | fn + option + cmd + arrows |
| **shift+option** | Center/maximize toggle | fn + shift + option + up/down |
| **shift+option** | Half/third cycle | fn + shift + option + left/right |

## Step Resize Behavior (fn + shift + arrows)

Resize from the bottom-right corner. The arrow keys move that corner in the indicated direction:

- **left/up**: shrink (pull the corner inward)
- **right/down**: grow (push the corner outward)

The top-left corner stays fixed. Use ctrl+arrow to re-snap to an edge after resizing.

**Wraparound**: When growing hits a screen edge, the resize wraps to shrinking from the opposite side. For example, a window at the top of the screen can be resized down until it fills the screen, then continued presses shrink it from the top while staying stuck to the bottom.

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

### Focus Direction (fn + cmd + arrows)
Focus the nearest window in that direction (on the same screen):
- **left/right**: based on window's left edge (x position)
- **up/down**: based on window's top edge (y position)
- Wraps around: keep pressing to cycle through all windows on the screen
- **Skips hidden windows**: Windows fully covered by other windows are excluded
- **Shadow-constrained**: Prioritizes windows that overlap with the current window's projection:
  - Up/down first looks for windows with horizontal overlap (directly above/below)
  - Left/right first looks for windows with vertical overlap (directly beside)
  - Falls back to all screen windows if no overlapping candidates exist

### Focus Across Screens (fn + option + cmd + arrows)
Jump to an adjacent screen, focusing the window closest to where you came from:
- **left**: go to left screen, focus window with rightmost edge
- **right**: go to right screen, focus window with leftmost edge
- **up**: go to upper screen, focus window with bottommost edge
- **down**: go to lower screen, focus window with topmost edge
- **Skips hidden windows**: Windows fully covered by other windows are excluded

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

## Unassigned (Available Functions)

The following operations are implemented but not currently bound to keys:

### Compact Mode
Shrink window to a small size and dock it at the bottom of the screen.
- Works like a minimized dock: windows line up left-to-right at the screen bottom
- Each new compact window appears to the right of existing ones
- Wraps to the row above when the bottom row is full
- Press again to restore original size and position
- App-specific minimum sizes are respected (see `minShrinkSize` in config)

### Max Height
Expand window to full screen height while keeping width and horizontal position.
**Reversible**: Press again to restore previous height.

### Max Width
Expand window to full screen width while keeping height and vertical position.
**Reversible**: Press again to restore previous width.

### Native Fullscreen
Toggle macOS native fullscreen mode (with the green button animation).

### Show Focus Highlight (fn + cmd + delete)
Flash a border around the currently focused window. Useful for locating which window has keyboard focus.

## Bear Note HUD

Open Bear notes like a HUD: a keyboard shortcut opens a specific note right where you left off, with caret and scroll position preserved. Press again to summon the note to your cursor. Press again to send it back.

### Note Hotkeys (hyperkey + letter)

Configured in `bear-notes.json`. Each hotkey cycles through four states:

| Press | State | Action |
|-------|-------|--------|
| 1st | Not open | Opens note in Bear, restores caret/scroll position |
| 2nd | Open, not focused | Raises + focuses the note window |
| 3rd | Focused | Centers the window on the mouse cursor |
| 4th | Summoned | Returns to original position, refocuses previous app |

Default bindings (hyperkey = ctrl+alt+shift+cmd):

| Key | Note |
|-----|------|
| N | `_mem NOW` |
| R | `_app rcmd` |
| D | Weekly days |
| W | Weekly work |
| T | Weekly thoughts |
| S | `_topsight 2026` |
| I | `_index 2026` |

Weekly note titles use template variables (`weekNum`, `weekDays`) defined in `bear-notes.json`.

### URL Handler

The `hammerspoon://open-bear-note` URL handler is also available for external launchers:

```
hammerspoon://open-bear-note?title=<encoded title>
hammerspoon://open-bear-note?id=<note id>
```

### Position Tracking

- **Caret**: Read/written via `AXSelectedTextRange` on Bear's `AXTextArea`
- **Scroll**: Read/written via `AXValue` on the vertical `AXScrollBar`
- **Storage**: `bear-hud-positions.json` (persists across Hammerspoon reloads)
- **Auto-save**: Every 3s while Bear is frontmost + on Bear deactivate
- **ID support**: When opened by `id`, learns the title→id mapping so auto-save works by id

## Mouse Drag

Hold **fn** and drag to move the window under the cursor.
Useful for apps where other window managers don't work (Kitty, Bear, etc.).

Hold **fn + shift** and drag to resize. The window is divided into a 3x3 grid — where you start dragging determines the resize behavior:

| Cursor position | Resize behavior |
|----------------|-----------------|
| Corner (e.g. top-left) | Resize from that corner; opposite corner stays fixed |
| Edge (e.g. right) | Resize that edge only; opposite edge stays fixed |
| Center | Move the window (same as fn-only) |

Releasing shift or fn stops the resize cleanly.

## Dependencies

- [WinWin Spoon](http://www.hammerspoon.org/Spoons/WinWin.html)
