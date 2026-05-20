# Case: every event-tap hotkey died at once — Chrome's orphaned Secure Input lock (2026-05-20)

**Project:** [stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) × [L007-hyperkey-shortcuts](https://stepper.internal/features/L007-hyperkey-shortcuts/) × [L010-move-to-resize](https://stepper.internal/features/L010-move-to-resize/) × [F027-worldclass-code-debugging](https://fleet.internal/features/F027-worldclass-code-debugging/)

**The symptom:** Every stepper hyper-hotkey *and* every rcmd app-toggle (e.g. `ropt+g` → Figma) stopped responding at the same instant. ==🔵[Hyperkey](https://hyperkey.app/) was the prime suspect== — but rcmd doesn't depend on Hyperkey, so a single misbehaving app couldn't explain both. "Something weird is going on."

==🟣The truth: macOS **Secure Input** (`EnableSecureEventInput`) was stuck ON, held by Google Chrome because a password field had focus. Secure Input suppresses **every `CGEventTap` system-wide** — so Hyperkey, rcmd, and all Hammerspoon eventtaps die together, while plain Carbon `hs.hotkey` bindings keep working. Then closing the offending tab made it *worse*: it **orphaned** the lock (the focused field was destroyed with no blur event), leaving `chrome://restart` as the only cure.==

## Contents

- [GICV (retroactive)](#gicv-retroactive)
- [The fingerprint: selective death](#the-fingerprint-selective-death)
- [Finding the holder — and the MCP-Chrome trap](#finding-the-holder--and-the-mcp-chrome-trap)
- [Why closing the tab backfired](#why-closing-the-tab-backfired)
- [The fix](#the-fix)
- [Meta-lessons](#meta-lessons)
- [Tags](#tags)

## GICV (retroactive)

> **GOAL:** When all event-tap–based hotkeys die at once, identify the true cause in seconds and fix it without a logout/reboot.
>
> **INVARIANT:** Plain Carbon `hs.hotkey` bindings (e.g. `ctrl+alt+arrow`) are unaffected and serve as the canary. Hammerspoon config is *not* reloaded — the cause is external to it.
>
> **COMPLETION:** `kCGSSessionSecureInputPID` is absent from `ioreg`; Hyperkey, rcmd, and stepper hotkeys all fire again.
>
> **VERIFICATION:** `ioreg -l -w 0 | grep kCGSSessionSecureInputPID` returns nothing post-fix (it returned `=983` while broken); user confirms live hotkeys.

## The fingerprint: selective death

Two independent subsystems dying simultaneously is the tell — look for a ==🟢shared system-level cause==, not two coincidental failures. The one command that cracks it:

```bash
ioreg -l -w 0 | grep kCGSSessionSecureInputPID
# broken:  "kCGSSessionSecureInputPID"=983   ← a PID holds Secure Input
# healthy: (no output — macOS drops the key when no secure session exists)
```

PID 983 was Chrome. The clincher that it was *Secure Input* specifically (not Chrome generally): the [Hammerspoon console](openfile:///Users/sara/bin/hs-console.sh) showed a stepper hotkey *still firing* mid-outage —

```
08:43:16  trigger: move-to-display:left 'kitty'    ← ctrl+alt+← still works
```

That maps cleanly onto the mechanism:

| Hotkey path | Mechanism | Under stuck Secure Input |
|---|---|---|
| Hyperkey → ⌘⌃⌥⇧ combos | Hyperkey `CGEventTap` | ==🔴dead== (Caps Lock never becomes hyper) |
| rcmd `ropt`+letter | rcmd `CGEventTap` | ==🔴dead== |
| Hammerspoon eventtaps | `CGEventTap` | ==🔴suppressed== (keyDown blocked) |
| stepper `ctrl+alt+arrow` ([`stepper.lua:1022`](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)) | Carbon `RegisterEventHotKey` | ==🟢works== |

==🟣Carbon hotkeys survive; event taps die. That selective-survival pattern *is* the Secure-Input signature== — and it proved Hyperkey was a victim, not the cause.

## Finding the holder — and the MCP-Chrome trap

PID 983 = `/Applications/Google Chrome.app/.../Google Chrome` with **zero flags** = the user's interactive Chrome. It is *not* one of the 5 headless [MCP browsers](https://fleet.internal/features/F003-multi-mcp-browsers/) (`--headless=new --remote-debugging-port=92xx --user-data-dir=/tmp/mcp-chrome-*`), which have no key window and so cannot hold Secure Input.

==🔴Trap:== AppleScript `tell application "Google Chrome"` routed to a *headless MCP* instance (wrong tabs, and JS-from-Apple-Events off there), not the GUI Chrome. ==🟢Fix: target the exact PID via Hammerspoon Accessibility==:

```lua
local ax = hs.axuielement.applicationElement(hs.application.applicationForPID(983))
pcall(function() ax:setAttributeValue("AXManualAccessibility", true) end) -- make Chrome build its web AX tree
-- read AXFocusedWindow / AXFocusedUIElement → page title + AXURL;
-- DFS each window in AXWindows for subrole "AXSecureTextField"
```

==🔵Gotcha:== the web AX tree is empty on the *first* query right after enabling `AXManualAccessibility` (DFS `visited=1`); re-run and it populates (`visited` in the thousands).

## Why closing the tab backfired

My first call was **wrong**: the AX-*focused* window was a MAS dashboard (`simulado.mas2.internal/hospital/ACH/`), so I suggested blurring/closing it. The user closed it — ==🔴still stuck==.

A second pass scanned **all 10** windows (tree now populated) and found ==🔴`secureFields=0` in every one==, yet `ioreg` still read `983`. That is an ==🟣orphaned lock==: Chrome enables Secure Input on password-field focus and disables it on **blur** — but closing or navigating a tab destroys the focused field with *no blur event*, so the reference is stranded inside Chrome's process. Nothing remains to click.

==🔵The right move would have been to enumerate every window before recommending an irreversible action.== `AXFocusedWindow` (the front window) ≠ the window owning the focused secure field when the app is backgrounded.

## The fix

==🟢Quit & relaunch Chrome.== The cleanest path preserves the session: type **`chrome://restart`** in any Chrome address bar — Chrome relaunches and restores its windows/tabs (DevTools windows excepted). No external process can decrement another process's `EnableSecureEventInput` count, so blurring or AX tricks cannot help once the lock is orphaned.

Post-restart: the `ioreg` key is gone; stepper + Hyperkey + rcmd all live. ==🟢Confirmed by the user.==

> **Why this is a big win:** the user had been plagued by this for ages, and the *only* previously-known cure was *closing System Settings* (on the occasions it happened to be the holder) — stumbled into through "untold pain," with no recourse at all when Chrome was the holder. The `ioreg` one-liner generalizes to **any** holder (Chrome, System Settings, Terminal's Secure Keyboard Entry, 1Password…): find the PID, make that app release or quit. Chrome is one of the most-used apps, so this *will* recur — now with a 10-second diagnosis.

## Meta-lessons

### 1. ==🔵N unrelated subsystems failing together → one shared cause==

The user's own instinct — "rcmd doesn't use Hyperkey, so something weird is going on" — was the key insight. ==🟢When independent features break at the same instant, stop debugging them individually and find the common substrate== (here the `CGEventTap` layer, killed wholesale by Secure Input). [F027 §0 one-why-deeper](https://fleet.internal/features/F027-worldclass-code-debugging/#0-one-why-deeper): the surface suspect (Hyperkey) was one "why" short of the truth.

### 2. ==🔵Verify the upstream layer before touching your own config==

The reflex was "reload Hammerspoon." But input wasn't even being *delivered* to it — IPC was alive and all 58 hotkeys were still registered. ==🟢Confirm the event reaches your code before you debug your code.== This mirrors the [L007 "verify upstream first" lesson](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L007-hyperkey-shortcuts/case-studies/2026-05-19-focus-return-race-condition.md), and note it is a *different* failure from [`hyperkey_event_tap_dies`](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/hyperkey_event_tap_dies.md): there the tap *died*; here the tap is healthy but the OS *suppresses delivery* to it.

### 3. ==🔴Don't recommend an irreversible action off a single-window heuristic==

Suggesting "close the tab" from the AX-*focused* window was premature and turned a blur-fixable state into a restart-only one. A full enumeration was cheap and would have shown the focused window wasn't special. ==🟣When the next step is destructive (close / delete / kill), pay for the complete scan first.==

### 4. ==🔵Target by PID; mind lazy AX trees==

`tell application "Google Chrome"` is ambiguous when many Chrome processes share the bundle id — it hit a headless MCP one. ==🟢`hs.axuielement.applicationElement(hs.application.applicationForPID(pid))` is unambiguous.== And Chrome only exposes web content to AX after `AXManualAccessibility=true` *and* a second query.

## Tags

- macos, secure-input, EnableSecureEventInput, CGEventTap, hyperkey, rcmd, hammerspoon, carbon-hotkeys, chrome
- selective-survival fingerprint — Carbon hotkeys live while event taps die ⇒ Secure Input
- orphaned-lock — closing a tab with a focused password field strands the reference; `chrome://restart` is the cure
- `ioreg kCGSSessionSecureInputPID` = the first check whenever hotkeys die en masse
- memory: [secure_input_breaks_hotkeys.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/secure_input_breaks_hotkeys.md)
- related: [F027 §0](https://fleet.internal/features/F027-worldclass-code-debugging/#0-one-why-deeper), [F027 §6](https://fleet.internal/features/F027-worldclass-code-debugging/#6-mistrust-claudes-self-knowledge), [hyperkey_event_tap_dies.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/hyperkey_event_tap_dies.md)
