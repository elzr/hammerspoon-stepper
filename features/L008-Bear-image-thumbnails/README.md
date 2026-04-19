## L008 — Bear image thumbnails

> Auto-shrink images pasted into [Bear](https://bear.app/) to 150px thumbnails; plus a selection-wide resize for cleaning up old notes (via [BetterTouchTool](https://folivora.ai/)).

==🟢Status==: ==🟢shipped==. Hammerspoon paste-and-shrink working; BTT `⌥R` / `⇧⌥R` bugs fixed.

## The twist worth knowing

The implementation works — we just spent an hour thinking it didn't because our success check was wrong. See the [F027 case study](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds.md) on "silent wins." Short version: Bear summarizes every embed as a single `￼` in the AX layer, so adding a width comment doesn't grow `AXValue` — we kept reporting failure on writes that were actually landing. Verify visually, not by length delta. Full details and other paths we tried in the [dev-guide](dev-guide.md).

## Contents
- [The twist worth knowing](#the-twist-worth-knowing)
- [Commands](#commands)
- [BTT JS bugs (fixed — two of them)](#btt-js-bugs-fixed--two-of-them)
- [Bear "select-just-the-embed" anomaly](#bear-select-just-the-embed-anomaly)
- [Design decisions](#design-decisions)
- [Undo cheat sheet](#undo-cheat-sheet)
- [Key files](#key-files)

See [dev-guide.md](dev-guide.md) for the implementation deep-dive.

## Commands

| Shortcut | Where it lives | Scope | Size |
|----------|----------------|-------|------|
| `⌘V` (Bear only, auto) | Hammerspoon — [bear-paste.lua](../../lua/bear-paste.lua) | just-pasted image | 150px |
| `⌥R` | BetterTouchTool — [btt-resize-thumbnails.js](btt-resize-thumbnails.js) | selection | 150px |
| `⇧⌥R` | BetterTouchTool — [btt-resize-thumbnails.js](btt-resize-thumbnails.js) | selection | 300px |

The `⌥R` pair is retained — different workflow ("I'm cleaning up an old note, make everything small"). `⌘V` works only for image pastes; plain-text pastes pass through unchanged.

## BTT JS bugs (fixed — two of them)

==🔴Bug 1: duplicate image width comment.== The original `resizeThumbnails` ran `imgAdd` after `imgChange`. But `imgChange`'s regex has groups 2 and 3 both optional, so it ==🟢already handles both== "no existing comment" AND "existing width comment" cases. After `imgChange` adds a fresh width comment, `imgAdd` then sees `![](path)<` where `<` is the start of the just-added comment, matches, and appends a duplicate comment.

Net effect: every image ends up as `![](x.png)<!-- {"width":150} --><!-- {"width":150} -->` after the first run, stable at 2 comments per image from then on.

==🟢Fix==: drop `imgAdd` entirely.

==🔴Bug 2: `pdfAdd` appends link text, not tail character.== The `pdfAdd` regex is `(\[([^\]<]+)\]\([^\)<]+pdf\))([^<]|$)` — nested captures where `$1` = the whole link, `$2` = link text (inner group), `$3` = the tail character. The replacement was `$1<!-- ... -->$2`, which puts the ==🔴link text back== where the tail character should go.

Observed effects:
- `[doc](foo.pdf)` → `[doc](foo.pdf)<!-- {"width":150} -->doc` (spurious "doc" appended)
- `[doc](foo.pdf) rest` → `[doc](foo.pdf)<!-- {"width":150} -->docrest` (separator space lost, "doc" inserted in its place)
- `[doc](foo.pdf)\nnext` → `[doc](foo.pdf)<!-- {"width":150} -->docnext` (newline eaten — this one is particularly ugly)

==🟢Fix==: change `$2` → `$3` in the `pdfAdd` replacement so the tail character round-trips.

==🟢Patched JS==: [btt-resize-thumbnails.js](btt-resize-thumbnails.js) — paste this into the BetterTouchTool action to replace the current one. Side-by-side verification in [test-btt-versions.js](test-btt-versions.js) (run with `node test-btt-versions.js`) — shows what the original produced vs the fix across each edge case.

## Bear "select-just-the-embed" anomaly

When you select ==🟣only== an image in Bear (no surrounding text) and run `⌥R`, the embed gets replaced with the raw file URL — something like `file:///Users/sara/Library/Group%20Containers/.../image%2036.png`.

==🔵Root cause==: when the selection is exactly an atomic embed, Bear returns the resolved file URL as the selection's text — not the source markdown `![](path)`. BTT's JS regex doesn't match a bare URL, so it returns the string unchanged. BTT then writes that unchanged URL back as plain text, which destroys the embed.

==🟣Why this matters for our Hammerspoon paste flow==: if `AXTextArea.value` (or a subrange of it) returns the same "rendered" representation for embeds, our regex won't match freshly-pasted images either. This is ==🔴the first thing to validate empirically== before building.

## Design decisions

==🟣Paste scope = just-pasted content, not whole note==. Reason: 95% of the time the user wants 150px, but occasionally they set a deliberate 300px "medium" on a specific image. Paste-and-shrink shouldn't silently flatten that. `⌥R` with whole-note selection is the explicit "normalize this note" tool.

==🟣Override `⌘V` in Bear, don't add `⇧⌘V`==. Reason: zero-friction — no new muscle memory. Risk: we're intercepting the user's most-used shortcut, so this must be rock-solid. Mitigations: tight timeout, graceful fallback to native paste on any error, quick kill-switch.

==🟣Hammerspoon over BTT for the paste flow==. Reason: AX text-range writes can sidestep the embed-atomicity selection issue, and we already have Bear AX infrastructure in [lua/bear-hud.lua](../../lua/bear-hud.lua).

==🟣Attachment types in scope==: ==🟢images and PDFs only==. Other Bear attachments are rendered as fixed-size mini-cards (no width knob), so they're out of scope.

## Undo cheat sheet

==🟢One `⌘z` after a paste removes just the width comment==, leaving the image at full size. A ==🟣second `⌘z`== removes the image entirely. Useful: if you pasted something you want at full size, one `⌘z` gives you that without re-pasting.

## Key files

- [dev-guide.md](dev-guide.md) — how the implementation works, other paths we tried, gotchas, and the AX skill stack
- [bear-paste.lua](../../lua/bear-paste.lua) — the Hammerspoon module (observer-based, ~100 lines)
- [btt-resize-thumbnails.js](btt-resize-thumbnails.js) — the patched JS for BetterTouchTool (drop-in replacement for the current action)
- [test-btt-versions.js](test-btt-versions.js) — original vs fixed side-by-side; `node test-btt-versions.js`
- [scripts/bear-ax-probe.lua](scripts/bear-ax-probe.lua) — diagnostic probe for exploring Bear's AX tree (load in HS console via `dofile(...)`)
- [F027 case study](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds.md) — the debugging post-mortem on silent wins
