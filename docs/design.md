# Design Principles

## Work with macOS, not against it

Stepper is a macOS-specific tool. We lean on the window server, accessibility APIs, and system behaviors rather than fighting them. If a feature requires disabling SIP or injecting into system processes, we rethink the approach. Hours spent on a dead end is a signal to find a different path, not to escalate privileges.

Examples: we use `win:minimize()` for per-window dismissal because macOS auto-focuses the next window. We dropped z-order capture/replay in favor of this because the window server handles focus transfer better than we can.

**One exception: windows, not apps.** macOS defaults to thinking in terms of applications — Cmd-Tab switches apps, Cmd-H hides all of an app's windows, `app:activate()` raises everything. We almost always prefer to think about *specific windows* instead. With tens of Chrome windows or Bear notes open, acting on all of them at once rarely makes sense. Per-window operations (focus, minimize, summon) are the default.

## Steps, not presets

Each keypress makes a small, reversible change. You build window arrangements through increments, not by snapping to predefined layouts. There are no halves, thirds, or memorized grids — just steps that compound.

- **Piecemeal**: one keypress, one small change. Repeat to continue.
- **Reversible**: every action can be undone by the opposite action.
- **Predictable**: the same key always does the same thing, regardless of window position. No hidden modes, no position-dependent behavior.
- **Instant**: no animations. `hs.window.animationDuration = 0` for all operations.

## Overlapping over tiling

Windows can overlap naturally. No forced tiling grid, no layout engine deciding where things go. Your arrangement emerges from small adjustments — it feels more like sculpting than snapping.

## Inspiration: lowtechguys

[Lowtech guys](https://lowtechguys.com) — especially [rcmd](https://lowtechguys.com/rcmd/) — are a major inspiration. rcmd was itself built in Hammerspoon before becoming a standalone app. When designing new features, look at how lowtechguys solved similar problems and reuse their patterns where possible.
