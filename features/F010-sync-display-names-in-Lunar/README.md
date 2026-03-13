# Sync Display Names in Lunar

## Problem

The 4 identical LG HDR 4K monitors have no distinguishing serial numbers or EDID data. macOS assigns UUIDs to each display port, and Lunar uses these UUIDs to identify monitors and store per-display settings (including custom names).

Periodically — on wake, reconnection, or for no apparent reason — macOS reassigns the UUIDs to different physical ports. When this happens, Lunar's carefully set position names (←Left, ⊙Middle Center, Right→, ↑Top Center) end up on the wrong monitors, making brightness control confusing.

## Solution

Hammerspoon can always determine which physical position each monitor occupies by looking at screen frame coordinates relative to the built-in display (`screenswitch.buildScreenMap()`). This feature uses that position detection to update Lunar's display names whenever monitors reconnect.

### Flow

1. The existing screen watcher in `layout.lua` detects a transition to 5 displays
2. After a stabilization delay (2s debounce + 3s extra), `syncLunarNames()` fires
3. Hammerspoon builds the screen position map and gets each screen's current UUID
4. The Python script `lunar-sync-names.py` reads Lunar's plist, finds entries matching each UUID, and updates their `name` field
5. If any names changed: Lunar is quit, the plist is written, and Lunar is relaunched
6. If names are already correct: nothing happens (no restart)

### Position → Name Mapping

| Position | Lunar Name | How Detected |
|----------|-----------|--------------|
| bottom | ↓Bottom Center | Built-in Retina Display (anchor) |
| center | ⊙Middle Center | Center column, closest above built-in |
| top | ↑Top Center | Center column, furthest above built-in |
| left | ←Left | Left of built-in's X range |
| right | Right→ | Right of built-in's X range |

Position detection is in `screenswitch.buildScreenMap()` — screens whose center X falls within the built-in display's X range are "center column" (sorted by Y), others are sides (sorted by X).

## Files

- `lunar-sync-names.py` — Python script that modifies Lunar's plist (`fyi.lunar.Lunar` defaults domain). Takes a JSON `{uuid: name}` argument. Exit 0 = names changed, exit 1 = no changes needed, exit 2 = error.
- Integration code lives in `lua/layout.lua` (`syncLunarNames` function and screen watcher hook)

## Manual Trigger

From the Hammerspoon console:

```lua
layout.syncLunarNames()
```

## How Lunar Stores Display Data

Lunar's preferences (`defaults read fyi.lunar.Lunar displays`) contain an array of JSON strings, one per display ever seen. Each entry has:

- `serial` — matches macOS display UUID (`hs.screen:getUUID()`)
- `name` — the display name shown in Lunar's UI (what we update)
- `edidName` — hardware EDID name (e.g., "LG HDR 4K (2)")
- `id` — Lunar's internal numeric ID
- `brightness`, `contrast`, etc. — per-display settings

Over time, as macOS reassigns UUIDs, Lunar accumulates multiple entries for what is physically the same monitor. Each UUID combination gets its own entry with independent settings.
