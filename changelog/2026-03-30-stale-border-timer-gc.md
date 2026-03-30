# Stale border fix: store timer references to prevent GC

**Date**: 2026-03-30
**Symptom**: Blue continuous-corner border stuck on left display indefinitely. Survived window moves, wasn't visible to CGWindowList or Hammerspoon canvas APIs.

## Theory

`hs.timer.doAfter()` returns a timer object. If the return value isn't stored, Lua's garbage collector can collect it before the callback fires -- silently cancelling the cleanup.

Both `flashFocusHighlight` (focus.lua) and `flashEdgeHighlight` (stepper.lua) discarded their timer return values:

```lua
-- OLD: timer eligible for GC
hs.timer.doAfter(0.3, function()
  safeDeleteCanvas(focusHighlight)
  focusHighlight = nil
end)
```

When GC collects the timer:
1. The 0.3s cleanup callback never fires
2. The 2.0s failsafe callback also never fires (same bug)
3. `focusHighlight` still holds the canvas reference, preventing the canvas itself from being GC'd
4. The border stays on screen until the next focus navigation (which deletes the old canvas before creating a new one)

## Diagnosis notes

- `hs.canvas.allCanvases` does not exist -- the earlier "0 canvases" result was a nil fallback, not real data
- `focusHighlight` is a module-local in focus.lua, unreachable from IPC -- couldn't inspect it directly
- CGWindowList (via Swift) confirmed 0 Hammerspoon-owned windows once the border had already cleared
- The border cleared on its own during debugging (possibly triggered by a focus operation or delayed GC)

## Fix

**focus.lua**: Added `focusHighlightTimer` and `focusHighlightFailsafe` module-level locals. Each `flashFocusHighlight` call stops previous timers before starting new ones. Removed the `focusHighlightGen` generation counter -- explicit timer cancellation is simpler and more reliable.

**stepper.lua**: Same pattern for `flashEdgeHighlight` -- added `edgeHighlightTimer`.

## Status

Plausible but unconfirmed. Will know for sure if stale borders stop recurring.
