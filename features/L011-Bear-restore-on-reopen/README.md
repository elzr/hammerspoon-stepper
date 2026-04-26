# L011 — Bear-restore-on-reopen

> Persist Bear note window frame across close-reopen, alongside the existing caret + scroll persistence in [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua). When you summon a note via livekey, it returns not just to the same scroll position but to the same window frame on screen.

**Status:** design — pending implementation.

**Created:** 2026-04-26

## Contents

- [Why Bear is special](#why-bear-is-special)
- [Relationship to L010](#relationship-to-l010-the-dual)
- [What gets persisted](#what-gets-persisted)
- [Lifecycle](#lifecycle)
- [Coordination with L010](#coordination-with-l010)
- [Implementation sketch](#implementation-sketch)
- [Edge cases](#edge-cases)

## Why Bear is special

Bear has a property that's unusually rare among the apps the user keeps open with many windows: ==🟢each Bear window's identity reliably matches a single document==. The window's title is the note title; one note per window; closing a Bear window closes that note's view but the note itself persists in the underlying SQLite store.

This is the opposite of the user's other always-open multi-window apps:

| App | Doc-window match | Why |
|-----|------------------|-----|
| ==🟢[Bear](https://bear.app/)== | **Reliable** | Each window = exactly one note; title = note title; close-reopen via livekey is the user's preferred interaction (instead of minimize) |
| ==🔴[Chrome](https://www.google.com/chrome/)== | **Unreliable** | A window's content swaps as the user changes tabs; title shifts to the active tab; closing a Chrome window destroys multiple unrelated tabs at once |
| ==🔴[Kitty](https://sw.kovidgoyal.net/kitty/)== | **Unreliable** | Sessions hold many shells; each Kitty window can have multiple OS-tabs holding multiple sessions; window title is whatever the active shell sets it to |

Because Bear's identity contract is reliable, ==🟣persistent state keyed on `app+title` actually maps to a stable concept== — "this specific note." The user doesn't lose information across close-reopen because the note is the durable thing; the window is just a view. Persisting the window's spatial state (frame) and reading state (caret, scroll) per-note lets the user *summon a note back exactly as they left it*.

The Stepper hyperkey HUD livekey shortcuts (==🔵[L007-hyperkey-shortcuts](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L007-hyperkey-shortcuts)==) make close-and-summon faster than minimize-and-restore for these notes — so this feature plugs the gap that close-reopen would otherwise create.

## Relationship to L010 (the dual)

==🟣L010 and L011 are duals==:

- ==🔵[L010 — move-to-resize-on-single-screen](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize-on-single-screen)== persists a **virtual frame** — *hypothetical-future state* about where the window WOULD be if the screen were infinite. Used to revive a squeeze.
- ==🔵L011== persists a **visible frame** — *realized-past state* about where the window WAS at last save. Used to revive a position.

Both are forms of "remember per-note geometry across close-reopen," but they answer different questions: L010 answers *"how was this note squeezed?"*; L011 answers *"where was this note sitting?"*

When both apply (a Bear note that was squeezed), L010 wins — the squeeze geometry already encodes the visible frame as the clamp of virtual to screen. L011 only fires when there's no L010 entry to consume.

This duality also resembles older patterns in the codebase: ==🔵[bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua)== already stores realized-past caret + scroll. L011 is the natural sibling — frame is "where the window was reading from," scroll is "where the cursor was reading from" — same axis of memory.

## What gets persisted

For each Bear note (key = note title, normalized via `keyForTitle`):

- ==🔵caret== — `AXSelectedTextRange.location` (already persisted by bear-hud)
- ==🔵scroll== — `AXScrollArea` value (already persisted by bear-hud)
- ==🟢frame== — `{x, y, w, h}` of the Bear window when last seen, in **relative coordinates** (fractions of screen, mirroring [screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua) and L010's persistence). New addition.

Storage extends the existing `data/bear-hud-positions.json` structure:

```json
{
  "positions": {
    "Note Title": {
      "caret": 420,
      "scroll": 0.1191,
      "frame": {"x": 0.05, "y": 0.04, "w": 0.4, "h": 0.7}
    }
  }
}
```

## Lifecycle

| Trigger | Action |
|---------|--------|
| Bear window loses focus / closes | Save `{caret, scroll, frame}` for that note's title |
| Bear window appears with a known title | Apply saved frame, then caret + scroll (in that order — caret/scroll within text area) |
| Note title changes (rename) | Migrate persisted entry to new key (mirrors L010 + screenmemory pattern) |
| L010 already restored a squeeze on this window | Skip frame restore — squeeze visible frame already correct |

## Coordination with L010

The interaction between L010's eager restore and L011's frame restore needs to be deterministic. The rule:

==🟢L010's eager restore runs first==. If it fires (i.e., the persistent map had a virtual frame for this app+title), it has already called `setFrame` to the correct squeezed visible frame. L011 should detect this and **not** apply its own frame.

Two implementation options:

1. **Order-based**: L010's `windowCreated` handler fires before L011's. L011 checks `ofsr.getVirtual(win)` — if non-nil, L010 just seeded a session entry and we skip frame restore.
2. **Tag-based**: L010 marks the window's session entry as "I just restored." L011 reads that tag and defers if set.

Option 1 is simpler and avoids cross-module state. Use it.

## Implementation sketch

L011 lives **inside** [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua), extending the existing per-note persistence.

**Adds:**

- `frame` field on each `positions[key]` entry
- `saveFrameForTitle(winTitle)` — captures current frame, stores in relative coords
- Frame application in `restoreForNote` — after frame is set, then caret + scroll
- L010 deference check (skip if `ofsr.getVirtual(win)` is set)
- Hook into existing window-focus / window-closed events to trigger save

**Touches:**

- `lua/bear-hud.lua` — extend positions schema + add frame save/restore
- `lua/stepper.lua` — possibly wire `ofsr.getVirtual` reference into `bear_hud.init` so L011 can defer to L010 cleanly

**Doesn't touch:**

- `lua/move-to-resize-on-single-screen.lua` — L010 stays standalone; L011 reads from it but doesn't write to it.

## Edge cases

| # | Case | Resolution |
|---|------|------------|
| EC1 | Two Bear windows with the same title (rare, e.g., orphan duplicates) | Identity collision; same as L010, accept and move on |
| EC2 | Resolution change between save and restore | Relative coords adjust automatically |
| EC3 | Bear window opens at restored frame but a screen no longer exists at those coords | clamp to screen bounds at restore time |
| EC4 | Persistent entry from before this feature existed (no `frame` field) | Treat as `frame = nil`; falls through gracefully |
| EC5 | User manually resizes a Bear window then closes it — should the new size persist? | Yes; save fires on focus-loss / close, captures latest frame |
| EC6 | Bear note opened on a different display than where it was saved | Relative coords mean it'll position proportionally on the new display; might feel off but consistent with screenmemory's behavior |
| EC7 | Pre-existing `bear-hud-positions.json` | Schema is additive; old entries without `frame` keep working |
