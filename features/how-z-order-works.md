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

The private `CGSOrderWindow` / `SLSOrderWindow` APIs can place a window relative to another, but they're undocumented and require a C extension. [Hammerspoon issue #2046](https://github.com/Hammerspoon/hammerspoon/issues/2046) confirms this gap.

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

## Current Implementation: Unconditional focus()

The working implementation calls `w:focus()` on every captured above-window back-to-front, then `focusSingleWindow(prevWin)` at the end. This produces correct z-order in all cases (same-app, interleaved multi-app) but causes beeps and menu bar flashing from the rapid app activations.

```lua
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

### Attempt 3: Deferred restore (wait for modifier key release)

**Idea**: Use `hs.eventtap` to watch `flagsChanged` events, defer the entire restore until all modifier keys (ctrl/shift/cmd/alt/fn) are released. No modifiers held → no beep when `focus()` activates apps.

**Result**: Still beeped, and the restore triggered with a long visible delay (well after keys were released). The `hs.eventtap` + `checkKeyboardModifiers()` approach appears unreliable for detecting modifier release timing — possibly because the hyper key combo (fn+ctrl+shift+cmd+opt) doesn't generate clean per-key `flagsChanged` events, or because the modifier state reported by `checkKeyboardModifiers()` lags behind physical key state. The delay was visually jarring regardless.

### Why Beeps Are Fundamentally Hard

The beep happens at the **window server level**, not the event loop level. When `focus()` activates an app, the window server notifies that app of the current physical modifier state. If hyper keys (ctrl+shift+cmd+opt) are physically down, the newly activated app receives those modifiers and beeps because it has no handler for that key combination. This happens below the level where `hs.eventtap` can intercept — it's a consequence of app activation itself, not of keyboard events flowing through the normal event pipeline.

The only known path to eliminating beeps would be:
- **`CGSOrderWindow`/`SLSOrderWindow`**: Private Core Graphics APIs that can reorder windows without activating apps. Would require a C extension for Hammerspoon. See [issue #2046](https://github.com/Hammerspoon/hammerspoon/issues/2046).
- **Suppress system alert sound globally** during restore: Hacky, affects all apps, timing-sensitive.
- **Accept the beeps**: The current approach. Z-order is correct; beeps are cosmetic.
