# L008 Dev Guide — how paste-and-shrink actually works

Implementation deep-dive for [L008-Bear-image-thumbnails](https://stepper.internal/features/L008-Bear-image-thumbnails/). The [README](README.md) is the entry point; this doc is for when you come back to change something.

## Contents

- [The user flow](#the-user-flow)
- [Architecture in one picture](#architecture-in-one-picture)
- [Why an observer, not an event tap](#why-an-observer-not-an-event-tap)
- [The ￼ placeholder, and why AXValue lies](#the--placeholder-and-why-axvalue-lies)
- [How to verify a change is working](#how-to-verify-a-change-is-working)
- [Dead ends we explored](#dead-ends-we-explored)
- [Gotchas & edge cases](#gotchas--edge-cases)
- [Skill stack we're building with AX](#skill-stack-were-building-with-ax)

## The user flow

1. User copies an image (screenshot, Finder, web).
2. User pastes with ⌘V into any Bear note.
3. Bear inserts the image as a full-width embed (its default).
4. ==🟢Within ~50ms, [bear-paste.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-paste.lua) attaches `<!-- {"width":150} -->` to the embed's markdown==. Bear re-renders it as a 150px thumbnail.
5. If the user wants the full size back, one ⌘z removes the comment (image stays). A second ⌘z removes the whole paste.

Plain-text pastes, or any paste where the clipboard isn't an image, passthrough untouched — the module's filter bails on `hs.pasteboard.readImage() == nil`.

## Architecture in one picture

```
 ┌────────────────────────────────────────────────────────────┐
 │  Bear (app, pid=NNNN)                                      │
 │                                                            │
 │   AXApplication ── AXWindow ── AXScrollArea ── AXTextArea  │
 │                                                            │
 │   AXValue = "...text... ￼ ...more text..."                │
 │            (￼ = one U+FFFC char per embed, 3 UTF-8 bytes) │
 └────────────────────────────────────────────────────────────┘
           ▲                              ▲
           │ 1. AXSelectedTextChanged      │ 2. setAttributeValue(
           │    notification on paste      │    "AXSelectedText",
           │                               │    '<!-- {"width":150} -->')
           │                               │
 ┌─────────┴──────────────────────────────┴────────────────────┐
 │  Hammerspoon / bear-paste.lua                               │
 │                                                             │
 │   hs.axuielement.observer.new(bear:pid())                   │
 │     :callback(onObserverFire)                               │
 │     :addWatcher(bearAppEl, "AXSelectedTextChanged")         │
 │                                                             │
 │   Filter in callback: role=AXTextArea, delta=+3 bytes,      │
 │     tail char == ￼, clipboard has an image                │
 └─────────────────────────────────────────────────────────────┘
```

==🔵Key move==: the observer is attached at the ==**application**== element, not a specific AXTextArea. Notifications from descendant elements (any note's textarea) bubble up to the app-level observer. This avoids the "which textarea is focused *right now*" problem at startup.

## Why an observer, not an event tap

The first design used [hs.eventtap](https://www.hammerspoon.org/docs/hs.eventtap.html) to catch ⌘V. It looked clean on paper: intercept the keystroke, let it through, schedule the AX write. ==🔴In practice, it was a rabbit hole== (see [dead ends](#dead-ends-we-explored)). The observer approach has several concrete advantages:

- ==🟢Works with any paste mechanism==. ⌘V, right-click-paste, Edit→Paste menu — all fire AXSelectedTextChanged, all get handled.
- ==🟢No input-layer involvement==. No debate about event taps poisoning app state, no modifier-flag edge cases, no double-fire issues.
- ==🟢Fires on real paste completion==. The observer sees AXSelectedTextChanged *after* Bear has inserted the ￼, which is the only moment we can target the caret correctly.
- ==🔵Filter cheaply== — most fires are typing/clicking, rejected in microseconds by the `delta==3 and readImage ~= nil` gate.

## The ￼ placeholder, and why AXValue lies

Bear represents every embed (image, PDF attachment) in its AX text layer as exactly ==one `￼` character== — U+FFFC, "Object Replacement Character," 3 bytes in UTF-8. The embed's real markdown (`![](image.png)<!-- {"width":150} -->`) lives in Bear's SQLite store, not in the AX tree.

This has massive consequences for testing:

- ==🔴Adding a width comment to an embed does NOT grow AXValue==. The `￼` is still one character; the comment is metadata attached to the same embed.
- `setAttributeValue("AXSelectedText", '<!-- ... -->')` at the caret *does* write the bytes — Bear's input handler sees the text, attaches it to the preceding embed, and folds it back into the single `￼` in AXValue.
- ==🔴Checking `lenBefore == lenAfter` to verify success will always report failure==. It's the wrong proxy.

Corollary: ⌘C from inside Bear has a *different* string representation than AXValue. A multi-character selection that includes an embed gets exported as raw markdown, with `![](path)<!-- {...} -->` fully spelled out. That's how BTT's ⌥R round-trips work, and how you can verify a write by hand (⌘A + ⌘C + paste into any other app).

## How to verify a change is working

Three tiers, in order of increasing trust:

1. ==🟢Visual==: paste an image into any Bear note. Does it render small (150px-ish, thumbnail size)? Yes → the comment was attached. No → something else is wrong.
2. ==🔵Clipboard roundtrip==: in a test note with a pasted image, ⌘A + ⌘C, paste into a plain text editor. Is `<!-- {"width":150} -->` in the markdown? Yes → confirmed at the markdown layer.
3. ==🟣Log inspection==: `~/bin/hs-console.sh 30 | grep bear-paste`. Look for `paste→shrink applied`. This is the cheapest check for "did the module's code path fire."

==🔴What NOT to do==: don't check `AXValue` length for growth, and don't search `AXValue` for "width":150". Both are blind to embed-attached metadata.

## Dead ends we explored

Documented so the next person doesn't retrace them. All of these were implemented in this session (see [scripts/bear-ax-probe.lua](scripts/bear-ax-probe.lua) for the probe that generated the data and the F027 case study at [case-2026-04-19-silent-wins-bear-ax-embeds.md](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds/) for the full post-mortem).

### 1. Event tap at keyDown + deferred AX write

Registered [hs.eventtap.new](https://www.hammerspoon.org/docs/hs.eventtap.html) for `keyDown`, filtered for cmd-only V, returned false (passthrough), scheduled `hs.timer.doAfter(0.05, function() ta:setAttributeValue(...) end)`. ==🔴Looked like it failed==: `writeOk=true` but AXValue length unchanged. Was actually succeeding — we couldn't see it through AXValue.

### 2. Consume + repost via app-targeted event

Same tap, but returned `true` (consume) and re-fired via `event:post(bearApp)` in a timer. Same apparent failure, same actual success.

### 3. `hs.eventtap.keyStrokes` typing the comment char-by-char

Skipped AX entirely, typed `<!-- {"width":150} -->` as a sequence of keystrokes. Also "failed" by AXValue metric — would have worked if we'd looked at Bear visually. But ==🔴fragile== even if it had: types each char, sensitive to focus changes mid-type.

### 4. AppleScript System Events keystroke

`osascript` calling `tell application "System Events" to keystroke "..."`. Different channel from hs.eventtap, hoped it'd bypass whatever was "blocking" the write. Also "failed" by AXValue metric, actually succeeding. ==🔴Also blocks HS runloop briefly== — `hs.osascript.applescript` is synchronous — so it's a bad path anyway.

### 5. Textarea-scoped observer (first observer attempt)

Attached the observer to the currently-focused AXTextArea at startup. Silently bailed when the focused element wasn't the textarea (sidebar, search field, tag editor). Fixed by moving to app-level attachment.

==🟣The meta-lesson==: six attempts, six identical "failure" signatures, ==all six were actually succeeding==. The instrument was broken, not the system. See the [case study](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds/).

## Gotchas & edge cases

- ==🔵False-positive risk==: if the clipboard has an image *and* the user types a 3-UTF-8-byte character (some CJK characters, some emoji), the delta filter triggers. Mitigation in the current code: we additionally check that the added bytes end in U+FFFC. Not bulletproof but covers ~99%.
- ==🔵Bear window switching==: the module tracks `lastLen` per-textarea (keyed by element reference). Switching to a different note resets the baseline so we don't report a spurious large delta.
- ==🔵`inserting` flag==: the AX write itself triggers AXSelectedTextChanged (the caret moves past the inserted comment). We guard against self-induced fires with a one-shot flag.
- ==🔴Undo is 2× ⌘z==: one to remove the comment, one to remove the paste. Arguably a feature (you can un-shrink without losing the image), but document it for users.
- ==🔴Bear must be running at HS init==. If Bear launches later, the observer won't attach. Future improvement: re-attach on `hs.application.watcher.launched`.

## Skill stack we're building with AX

Stepper now uses [hs.axuielement](https://www.hammerspoon.org/docs/hs.axuielement.html) in three distinct ways, and the patterns are transferable:

- [lua/bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua) — ==🔵reads + writes==: persists per-note caret position and scroll offset. Classic state-preservation use of AX.
- [lua/bear-paste.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-paste.lua) (this feature) — ==🔵observer + writes==: reacts to app-level notifications and modifies state in response.
- [features/L008-Bear-image-thumbnails/scripts/bear-ax-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-ax-probe.lua) — ==🔵diagnostic probes==: dumps AX state for ad-hoc investigation.

The "app-level observer with descendant-filtering callback" pattern in particular is reusable for any app where you want to react to internal state changes without plumbing through the input layer.
