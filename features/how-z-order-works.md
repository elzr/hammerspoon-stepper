# Window Z-Order in macOS and Hammerspoon

## How macOS Z-Order Works

macOS window ordering is **application-centric**, not window-centric. This is fundamentally different from CSS `z-index` where each element has an independent stacking position.

### The Layer Model

```
┌─────────────────────────────────────┐
│  Active app's windows (frontmost)   │  ← Activated app gets promoted
├─────────────────────────────────────┤
│  Other apps' windows (interleaved)  │  ← Retain their relative order
├─────────────────────────────────────┤
│  Desktop                            │
└─────────────────────────────────────┘
```

When you activate an app, macOS promotes *some* of its windows to the front. The exact behavior depends on which activation method you use (see below). Windows from other apps generally stay in their relative order, but they all end up behind the active app's promoted windows.

### Key Concept: No Public API for Arbitrary Z-Position

There is **no public macOS API** to say "put window W at z-position 5." You can only:
- Bring a window to the front (`raise`, `focus`, `activate`)
- Send a window to the back (`sendToBack`)
- Read the current z-order (`hs.window.orderedWindows()`)

The private `CGSOrderWindow` / `SLSOrderWindow` APIs can place a window relative to another, but they require SIP to be partially disabled to work cross-app (see attempt 4 below). [Hammerspoon issue #2046](https://github.com/Hammerspoon/hammerspoon/issues/2046) confirms this gap.

## Hammerspoon APIs and What They Actually Do

### `win:raise()`
- Calls `AXRaise` via the Accessibility API
- **Brings the window to the front visually** (z-order)
- **Does NOT activate the app** or change keyboard focus
- **Same-app limitation**: When called on a window whose app is *not* active, `AXRaise` only reorders the window *within that app's window stack*. It won't move it above windows from the currently active app.
- No beeps, no flashing, no side effects

### `win:focus()`
- Calls `becomeMain()` + `app:_bringtofront()`
- **Activates the window's app** (full app switch)
- **Gives keyboard focus** to the window
- Side effects: app activation sound, menu bar change, visual focus ring
- Cross-app: works reliably to bring any window to absolute front

### `app:activate(false)`
- Activates the app, bringing its **most recently focused** window to front
- Other windows from the app stay where they are
- Does NOT move ALL windows

### `app:activate(true)`
- Activates the app and brings **ALL its windows** to front
- Affects windows on **ALL screens and desktops**
- Too aggressive for surgical z-order work

### `win:sendToBack()`
- Implemented by focusing all overlapping windows back-to-front
- Essentially does what our `restoreZOrder` does: N focus() calls
- Same beep/flash problems

### `hs.window.orderedWindows()`
- Returns all visible standard windows, front-to-back
- Read-only snapshot of z-order
- Includes windows from all apps, all screens
- This is what `getAppsAbove()` uses to capture state

## The Core Problem

When we toggle a window (raise it above everything), then untoggle it, we need to put it back. But:

1. **We can read z-order** (via `orderedWindows()`) ✓
2. **We cannot write z-order** to an arbitrary position ✗
3. **We can only push things to the top** (`raise`, `focus`) or bottom (`sendToBack`)

So the only way to "lower" a window is to raise everything that should be above it. And raising cross-app windows requires `focus()`, which causes app switching, beeps, and flashing.

## What Works, What Doesn't

| Approach | Z-order correct? | Beeps? | Flashing? | Surgical? |
|----------|:-:|:-:|:-:|:-:|
| `focus()` each above-window | Yes | Yes | Yes | Yes (per-window) |
| `app:activate(true)` per app | Yes | No | Some | No (ALL windows of app) |
| `raise()` each + single `focus(prevWin)` | Mostly* | Minimal | Minimal | Yes |
| Do nothing (just focus prevWin) | Partial | No | No | Yes |

\* `raise()` correctly reorders windows within the same app. Cross-app interleaving may not be perfectly restored because `raise()` on an inactive app's window only reorders within that app's stack.

## Current Implementation: Deferred focus()

The implementation defers `w:focus()` calls until all modifier keys are released, then calls `focus()` on every captured above-window back-to-front, then `focusSingleWindow(prevWin)` at the end. This produces correct z-order in all cases (same-app, interleaved multi-app) without beeps.

```lua
-- Poll HID state every 50ms until modifiers released (2s timeout)
local function anyModifiersHeld()
  local mods = hs.eventtap.checkKeyboardModifiers()
  return mods.cmd or mods.alt or mods.shift or mods.ctrl
end

-- When modifiers released:
for i = #appsAbove, 1, -1 do
  w:focus()              -- activates w's app, brings w to absolute front
  hs.timer.usleep(10000) -- 10ms settle
end
focusSingleWindow(prevWin)
```

## Failed Attempts to Reduce Beeps (Feb 2026)

### Attempt 1: Same-App Optimization (focus at app boundaries, raise within)

**Idea**: Track `lastPid`. If the next window belongs to the same app as the last `focus()`, use `raise()` instead — the app is already active so `raise()` correctly reorders within its stack.

**Result**: Z-order was correct (confirmed by logs: 1 `focus()` + 3 `raise()` for 4 Chrome windows). But still beeped — even a single `focus()` call on Chrome while hyper modifiers are physically held causes a beep. Reducing from N to 1 `focus()` doesn't help if 1 is still too many.

### Attempt 2: raise()-only (focus prevWin first, then raise all above-windows)

**Idea**: Focus `prevWin` first (unavoidable, desired), then `raise()` all above-windows back-to-front. Since `raise()` doesn't activate apps, no beeps from the above-windows.

**Result**: Wrong z-order. Apple explicitly documents that `AXRaise` on a non-active app's window "will not go in front of the active application's windows." After focusing prevWin (Chrome), the `raise()` calls on other Chrome windows brought them above prevWin — the wrong Chrome window ended up on top. And when prevWin's app differs from the above-windows' app, `raise()` can't cross the app boundary at all. `raise()` is fundamentally insufficient for cross-app z-order.

### Attempt 3: Deferred restore via eventtap (wait for modifier release)

**Idea**: Use `hs.eventtap` to watch `flagsChanged` events, defer the entire restore until all modifier keys (ctrl/shift/cmd/alt/fn) are released. No modifiers held → no beep when `focus()` activates apps.

**Result**: Still beeped, and the restore triggered with a long visible delay (well after keys were released). The `hs.eventtap` + `checkKeyboardModifiers()` approach appeared unreliable — possibly because the hyper key combo (fn+ctrl+shift+cmd+opt) doesn't generate clean per-key `flagsChanged` events, or because the modifier state reported by `checkKeyboardModifiers()` lags behind physical key state.

### Attempt 4: CGSOrderWindow / SLSOrderWindow (C extension)

**Idea**: Use private `CGSOrderWindow` or `SLSOrderWindow` API via a compiled Lua C module to reorder windows without app activation. These APIs place a window above/below another by window ID, bypassing the app activation mechanism entirely.

**Implementation**: Built `cgs_order.c` → `~/.hammerspoon/cgs_order.so`, exposing `reorder(windowID, mode, relativeWindowID)`. Tried both `CGSOrderWindow` and `SLSOrderWindow` (SkyLight equivalent).

**Result**: Both return error 1000 (`kCGErrorFailure`) for cross-app windows. The process's own CGS/SLS connection can only reorder windows it owns. Reordering other apps' windows requires a privileged connection (like the Dock's), which in turn requires SIP to be partially disabled (as yabai does with its scripting addition). Not viable without SIP modification.

The limitation is permissions, not code — the module compiled and loaded fine.

### Attempt 5: Deferred restore via polling (current implementation)

**Idea**: Same deferred approach as attempt 3, but using a polling timer with `hs.eventtap.checkKeyboardModifiers()` every 50ms instead of reactive eventtap events. Only checks beep-causing modifiers (cmd/alt/shift/ctrl), not fn (which is a hardware key that doesn't cause beeps). Times out after 2s and restores anyway.

**Result**: Still beeps. The modifier polling itself works (`checkKeyboardModifiers()` reliably reports when modifiers are released), but beeps still occur when the deferred `focus()` calls fire. This suggests the beep may not be purely from held modifiers — it may be an artifact of rapid app activation itself, or a race between the HID state that `checkKeyboardModifiers()` reads and the window server's own modifier tracking.

## Why Beeps Are So Hard to Eliminate

The problem is a chain of constraints where each link forces the next:

1. **No z-order write API exists.** macOS lets you *read* window order (`orderedWindows()`) but the only way to *set* position is pushing a window to the front. No "put window W at position N."

2. **So restoring z-order requires raising every above-window.** To put 5 windows back above the Bear note, you must bring each one to the front, back-to-front. There's no shortcut.

3. **Cross-app raising requires `focus()`.** `raise()` (AXRaise) only reorders within the active app's own stack — Apple explicitly won't let it jump above the active app's windows. `focus()` is the only call that crosses the app boundary.

4. **`focus()` activates the target app.** That's what makes it work — it tells the window server "this app is now frontmost." There's no "raise without activating" public API.

5. **App activation forwards held modifier state.** This happens inside the window server, not in the event pipeline. The moment Chrome gets activated, the window server tells Chrome "hey, ctrl+shift+cmd+opt are currently down." Chrome has no menu item for that combo, so it beeps.

6. **Private APIs that skip activation (`CGSOrderWindow`/`SLSOrderWindow`) need SIP disabled.** They work — yabai uses them — but only via a scripting addition injected into the Dock process, which has a privileged connection. From Hammerspoon's own connection, they return error 1000 for other apps' windows.

7. **Deferring until modifiers are released should work in theory** but still beeps in practice — either `checkKeyboardModifiers()` races with the window server's own modifier tracking, or the rapid app-switch sequence itself produces beeps for a reason other than modifiers.

## Next investigations

- **Debug #7**: trigger restoreZOrder from the HS console with zero modifiers held. If it still beeps, the beeps aren't from modifiers at all and the entire deferred approach is a dead end.
- **Mute alert sound during restore**: `hs.osascript.applescript('set volume alert volume 0')` before the focus() loop, restore after. Hacky but would silence beeps regardless of their cause.
