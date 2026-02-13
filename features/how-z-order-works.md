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
- N focus() calls under the hood
- Same beep/flash problems as manual z-order restore

### `hs.window.orderedWindows()`
- Returns all visible standard windows, front-to-back
- Read-only snapshot of z-order
- Includes windows from all apps, all screens
- Useful for debugging window stacking

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

## Current Implementation: Per-Window Minimize

After exploring five different approaches to z-order restoration (all with unsolvable beep or permission issues), we abandoned z-order restore entirely in favor of `win:minimize()`.

When toggling a window off (or unsummoning), we simply minimize that specific window. macOS automatically focuses the next window in z-order — no manual restore needed. When toggling back on, `focusSingleWindow()` calls `win:unminimize()` before `raise()` + `focus()`.

This works with macOS instead of against it: the window server handles focus transfer better than we can replicate from userspace. The only trade-off is that dismissed windows go to the dock instead of staying visible behind other windows, but in practice this is the desired behavior for a HUD-style toggle.

## Failed Attempts at Z-Order Restoration (Feb 2026)

The approaches below document why z-order restore was abandoned. They're preserved as a reference for anyone hitting similar problems.

### Attempt 1: Same-App Optimization (focus at app boundaries, raise within)

**Idea**: Track `lastPid`. If the next window belongs to the same app as the last `focus()`, use `raise()` instead — the app is already active so `raise()` correctly reorders within its stack.

**Result**: Z-order was correct (confirmed by logs: 1 `focus()` + 3 `raise()` for 4 Chrome windows). But still beeped — even a single `focus()` call on Chrome while hyper modifiers are physically held causes a beep.

### Attempt 2: raise()-only (focus prevWin first, then raise all above-windows)

**Idea**: Focus `prevWin` first, then `raise()` all above-windows back-to-front.

**Result**: Wrong z-order. `AXRaise` on a non-active app's window can't jump above the active app's windows. `raise()` is fundamentally insufficient for cross-app z-order.

### Attempt 3: Deferred restore via eventtap (wait for modifier release)

**Idea**: Defer the entire restore until all modifier keys are released.

**Result**: Still beeped, with a visible delay. The `hs.eventtap` + `checkKeyboardModifiers()` approach was unreliable for detecting modifier release timing.

### Attempt 4: CGSOrderWindow / SLSOrderWindow (C extension)

**Idea**: Use private `CGSOrderWindow`/`SLSOrderWindow` via a compiled Lua C module to reorder windows without app activation.

**Result**: Returns error 1000 for cross-app windows. Requires a privileged connection (like the Dock's), which needs SIP partially disabled. Not viable — see [design principle: work with macOS](/docs/design.md).

### Attempt 5: Deferred restore via polling

**Idea**: Poll `checkKeyboardModifiers()` every 50ms, restore when modifiers released.

**Result**: Still beeps. The beep may not be purely from held modifiers — possibly an artifact of rapid app activation itself.

### Why Z-Order Restore Is Fundamentally Hard on macOS

1. **No z-order write API** — you can read window order but only push to front or back
2. **Cross-app raising requires `focus()`** — `raise()` only works within the active app
3. **`focus()` activates the target app** — which forwards held modifier state, causing beeps
4. **Private APIs need SIP disabled** — `CGSOrderWindow` works but only from privileged processes
5. **Deferring doesn't help** — beeps persist even after modifiers are released

The lesson: per-window minimize sidesteps all of this by letting macOS handle focus transfer natively.
