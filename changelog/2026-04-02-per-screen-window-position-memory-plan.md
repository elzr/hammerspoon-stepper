# Per-Screen Window Position Memory

## Context

Windows moved between screens lose their per-screen positions. The current system has `naturalSize`/`naturalPosition` (single global, not per-screen) and `displayUndo` (single-level, 1hr TTL). The user wants each window to remember its frame on every screen it visits, so moving a window right→center→right restores the right position, and moving back to center restores the center position. Screens are used as focus/memory states — center for intense work, sides for ambient context.

## Architecture: new `lua/screenmemory.lua` module

Follows existing pattern — each `.lua` returns a module table, loaded via `dofile()`.

### Data structures

```
sessionMemory[winID][screenPos]  = {frameRel={x,y,w,h}, ts=epoch}   -- in-memory
persistentMemory["app\ntitle"][screenPos] = {frameRel, ts}           -- on disk
lastKnownTitle[winID] = {app=str, title=str}                        -- rename tracking
```

### Public API

| Function | Called by | When |
|----------|----------|------|
| `init()` | stepper.lua startup | Load from disk, prune >30d entries |
| `saveDeparture(win, screenPos)` | screenswitch `moveToScreen`, stepper undo path | Before window moves away |
| `lookupArrival(win, screenPos)` | screenswitch `moveToScreen` | Returns `frameRel` or nil |
| `updateFromLayout(entries)` | layout `save()` | Bulk update from autosave data |
| `seedFromRestore(win, screenPos, frameRel)` | layout `restoreFromJSON`, `retryMisses` | After restore places a window |

### Disk persistence

- File: `data/screen-memory.json`
- Write: debounced 5s after last `saveDeparture` or `updateFromLayout`
- Load: on `init()`
- Prune: on load, delete entries with `ts` older than 30 days

### Rename handling (no orphans)

Track `lastKnownTitle[winID]`. On `saveDeparture`, if app+title changed:
1. Merge all screen positions from old persistent key into new key (keep newer timestamps)
2. Delete old persistent key
3. Update `lastKnownTitle[winID]`

## File changes

### 1. NEW: `lua/screenmemory.lua`

Full module with the 5 functions above + debounced disk write + pruning.

`saveDeparture(win, screenPos)`:
1. Compute `frameRel` from `win:frame()` relative to `win:screen():frame()`
2. Save to `sessionMemory[winID][screenPos]`
3. Handle rename (merge old->new persistent key, delete old)
4. Save to `persistentMemory[app+title][screenPos]`
5. Schedule debounced disk write

`lookupArrival(win, screenPos)`:
1. Check `sessionMemory[winID][screenPos]` -> return if found
2. Check `persistentMemory[app+title][screenPos]` -> return if found
3. Return nil

`updateFromLayout(entries)`:
- For each entry with `screenPosition`: update persistent memory, find live window by title to also update session memory
- Uses post-protection-substitution data (correct positions)

`seedFromRestore(win, screenPos, frameRel)`:
- Sets `sessionMemory[winID][screenPos]` only (no persistent write needed)

### 2. MODIFY: `lua/screenswitch.lua`

**Remove**: `naturalSize` table, `naturalPosition` table, all references

**Add**: `screenmemory` module reference via `M.setScreenMemory(mod)`

**Rewrite `moveToScreen`**:
1. Build map, get targetScreen, check not same screen
2. Reverse-lookup departure position name from map
3. `screenmemory.saveDeparture(win, departurePos)` -- BEFORE anything changes
4. `setupWindowOperation(true)`
5. `remembered = screenmemory.lookupArrival(win, position)`
6. IF remembered: apply remembered.frameRel to targetScreen:frame() with rounding + clamping
   ELSE: simplified proportional mapping (minus naturalSize/naturalPosition)
7. `instant(function() win:setFrame(newFrame) end)`
8. Flash focus highlight

### 3. MODIFY: `lua/stepper.lua`

- Load screenmemory module
- Init: `screenmemory.init()`, `screenswitch.setScreenMemory(screenmemory)`, pass to `layout.init`
- Undo path in `moveToDisplay`: save departure memory before restoring undo frame

### 4. MODIFY: `lua/layout.lua`

- Store screenmemory reference in `init()`
- Call `screenmemory.updateFromLayout(entries)` at end of `save()`
- Call `screenmemory.seedFromRestore()` in `restoreFromJSON` and `retryMisses`

### 5. MODIFY: `.gitignore`

Add `screen-memory.json`.

## Also in this session

- **L006 wake settle delay**: Reduced `WAKE_SETTLE_DELAY` from 3s to 1s
- **L006 surgical restore**: `restoreFromJSON` now skips windows already in position and only replays z-order for moved windows (reduces flicker)

## What's NOT changing

- `displayUndo` stays — undo is "go back to previous screen" and now also saves departure memory
- All existing hotkey bindings unchanged
- Layout save/restore behavior unchanged (surgical restore preserved)
- Bear summon/unsummon unchanged (uses absolute frames, independent)
