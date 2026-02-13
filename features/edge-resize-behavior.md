# Resize Mental Models

Decision record for the step resize behavior in Stepper.

## Background: WinWin's `stepResize`

WinWin's `stepResize` calls `setSize()`, which only changes width/height. The top-left corner stays fixed. So:

- **left/up** = shrink (right/bottom edge moves inward)
- **right/down** = grow (right/bottom edge moves outward)

This is simple and predictable: arrow keys move the bottom-right corner.

## The Problem With Edge-Snapped Windows

When a window is snapped to the right edge of the screen, pressing "resize left" (shrink) pulls the right edge inward, detaching the window from the edge. This feels wrong if you think of the window as "stuck" to that edge.

## Model A: Edge-Aware (removed)

The original `smartStepResize` reversed the arrow key directions when the window was touching a screen edge. Eight branches (4 directions x shrink/grow) detected edge contact and flipped the resize behavior to keep the window stuck.

**Pros**: Windows stay glued to edges during resize.

**Cons**: The same key does different things depending on position. "Resize left" sometimes shrinks, sometimes grows. Hard to build muscle memory. The code was ~90 lines of edge detection, re-snapping (for Retina subpixel rounding), and visual feedback.

## Model B: Bottom-Right Corner (adopted)

Arrow keys always move the bottom-right corner. Left/up shrink, right/down grow. No edge awareness, no reversal.

**Pros**: Completely predictable. Same key always does the same thing. Trivial code (one-line pass-through to WinWin).

**Cons**: Resizing detaches windows from right/bottom edges. You need to re-snap with ctrl+arrow after resizing if you want to stay at an edge.

## Decision

Adopted Model B. The predictability outweighs the convenience of edge-sticking. The ctrl+arrow (move to edge) binding makes re-snapping easy when needed.
