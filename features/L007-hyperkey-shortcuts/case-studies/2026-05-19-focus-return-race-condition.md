# Case: hyper+key dismiss returns to wrong window — race at WindowServer (2026-05-19)

**Project:** [stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) × [L007-hyperkey-shortcuts](https://stepper.internal/features/L007-hyperkey-shortcuts/) × [F027-worldclass-code-debugging](https://fleet.internal/features/F027-worldclass-code-debugging/)

**The ask:** Make `<hyper>n` a true toggle — press once to raise the `_mem NOW` Bear note, press again to return to whatever window the user was on before (e.g. Chrome), instead of macOS picking some other Bear window by z-order.

**The bug we kept solving:** Capture worked. Restore failed. Restore worked but flashed `_budget` first. Restore worked but only ==🔴half the time==.

==🟣The truth: macOS cross-app focus is async, but `win:minimize()` triggers a synchronous WindowServer z-order recalc. Issuing both back-to-back is a race — whichever lands first at WindowServer wins. Reordering them in Lua doesn't help; only inserting a real delay between them does.==

## Contents

- [Timeline of fix attempts](#timeline-of-fix-attempts)
- [Why each earlier fix half-worked](#why-each-earlier-fix-half-worked)
- [The actual fix](#the-actual-fix)
- [Meta-lessons](#meta-lessons)
- [Tags](#tags)

## Timeline of fix attempts

| # | Hypothesis | Change | Result |
|---|------------|--------|--------|
| 1 | We don't remember the prior window | Capture `priorWindow = hs.window.focusedWindow()` at hotkey entry; call `priorWindow:focus()` after `noteWin:minimize()` in [`bear-hud.lua`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua) `handleNoteHotkey` | ==🔴No change== — still landed on another Bear note |
| 2 | `:focus()` doesn't activate across app boundaries | Use [`focusModule.focusSingleWindow`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/focus.lua) (does `raise()` + `focus()` + 100ms verify) instead of plain `:focus()` | ==🟡Log said success== — "After 100ms, focused: Google Chrome" — but user reported "exact same thing". Cause: visible flash of `_budget` Bear window between minimize and focus settle |
| 3 | Wrong execution order | Focus prior FIRST, then minimize | ==🟡Worked ~50% of the time== — intermittent |
| 4 | **Race at WindowServer** | Focus prior, wait 150ms for the cross-app focus to settle, THEN minimize | ==🟢Consistent== |

## Why each earlier fix half-worked

The minimize+focus pair are two events at the system layer:

- `win:focus()` / `focusSingleWindow()` → AX message to WindowServer asking to raise window + activate app. **Async at the WindowServer**. Hammerspoon's 100ms verify is a sanity check, not a barrier — focus settle can complete anywhere from a few ms to ~100ms.
- `noteWin:minimize()` → synchronous call that immediately triggers WindowServer's own z-order recalc. When Bear's frontmost window minimizes, WindowServer picks the next Bear window (the recently-saved-position `_budget 19may2026`) and brings it forward.

Both events get queued at WindowServer back-to-back. Whichever arrives second wins (clobbers the other's z-order decision). Reordering them in our Lua code is reordering the *queueing*, not the *settling*. ==🔵That's why fix #3 was intermittent: most of the time queueing order matches settle order, but not always — depends on whatever else WindowServer is doing at that instant.==

The diagnostic signal we missed for too long: ==🟣intermittent / half-working / "works once, breaks once" is the signature of a race==. The right move after fix #2 was already "this is a race, insert a real delay or use a different mechanism", not "let me try another reorder."

## The actual fix

In [`bear-hud.lua:handleNoteHotkey`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua):

```lua
if priorWindow then
  local pw = priorWindow
  priorWindow = nil
  pcall(function() focusModule.focusSingleWindow(pw) end)
  hs.timer.doAfter(0.15, function()
    pcall(function() noteWin:minimize() end)
  end)
else
  noteWin:minimize()
end
```

The 150ms gap is well past the typical cross-app focus settle (~30–80ms) and well past the verify timer in [`focus.lua:focusSingleWindow`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/focus.lua) (100ms). By the time minimize fires, the note is no longer in the frontmost app, so its minimize triggers no z-order grab.

Same change applied to `handleLiveToggle` for the X/Q/A/Z live-window slots.

The capture side is unchanged: at hotkey entry, store `focusedAtEntry` unless we're already on the target (preserves the value captured on the raising press for the dismissing press to consume).

## Meta-lessons

### 1. ==🔵Intermittent = race. Stop reordering, start delaying.==

After fix #3 (reorder), the user got "working half the time." That's the canonical race-condition fingerprint. The right next move is ==🟢instrument timing or insert a settle delay==, not ==🔴yet another reorder of the same two calls==. We tried two reorders before pivoting to delay; one reorder was already too many.

This generalizes [F027 §0 (one-why-deeper)](https://fleet.internal/features/F027-worldclass-code-debugging/#0-one-why-deeper) at the system-call layer: ==🟣when a race is the actual cause, "fix the logic" cannot fix it — only "respect the system's settle time" can==.

### 2. ==🔵Logs can show success while UX is broken==

Fix #2's log clearly read: `[focusSingleWindow] After 100ms, focused: Google Chrome`. The user saw a Bear flash and reported "same as before." ==🟢Both were true.== The 100ms verify catches the *eventual* state but not the *transient* glitch the user perceives. For UX bugs, the success criterion is "no visible flash," not "final state is correct." We should have asked "what did you see during the press?" earlier, instead of trusting the success log.

### 3. ==🔵`hs.window:focus()` is not the same as "make this window frontmost"==

For same-app focus changes, `:focus()` is enough. For cross-app, you need ==🟣raise+focus+activate==, which is what [`focusModule.focusSingleWindow`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/focus.lua) packages. ==🟢Default to the bundled helper for any cross-app focus restore in this codebase== — bare `:focus()` is a footgun for "I want Chrome to come forward from Bear."

### 4. ==🔵A separate, earlier bug muddied the diagnosis==

Before the focus-return work, `<hyper>n` produced raw `Esc + n` because the [Hyperkey app](https://hyperkey.app/)'s CGEventTap had silently died (process still alive, [Accessibility still granted](https://stepper.internal/features/L007-hyperkey-shortcuts/#the-stack)). Quit + relaunch + ==🟣wait ~5–10s for tap registration== fixed it. Easy to confuse the symptom space when two unrelated bugs stack — verify the upstream layer is healthy *before* touching the downstream logic. See [`hyperkey_event_tap_dies` memory](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/hyperkey_event_tap_dies.md).

## Tags

- hammerspoon, hs.window, focus, minimize, race-condition, windowserver
- intermittent-bug signature — half-working = race, not logic
- cross-app activation — `:focus()` ≠ raise+activate
- related: [F027 §0](https://fleet.internal/features/F027-worldclass-code-debugging/#0-one-why-deeper), [hyperkey_event_tap_dies.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/hyperkey_event_tap_dies.md)
