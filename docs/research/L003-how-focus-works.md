# Window Focus Architecture in Hammerspoon

## The Problem

Reliably focusing a window in macOS without moving the mouse is surprisingly difficult. The naive approach of just calling `win:focus()` often fails to bring the window visually to the front, even though macOS may consider it "focused" (border highlight appears).

## What We Tried

### Approach 1: Just `win:focus()`
**Result**: Inconsistent. Sometimes the window gets keyboard focus but doesn't raise visually.

### Approach 2: Click simulation
```lua
local center = win:frame().center
hs.eventtap.leftClick(center)
```
**Result**: Works but moves the mouse cursor, which is disruptive.

### Approach 3: AXUIElement APIs
```lua
local axWin = hs.axuielement.windowElement(win)
axWin:performAction("AXRaise")
axWin:setAttributeValue("AXMain", true)
win:focus()
```
**Result**: Unreliable. The window gets the focus border but doesn't raise visually.

### Approach 4: raise() + focus() (no delay)
```lua
win:raise()
win:focus()
```
**Result**: Still unreliable. Same symptoms as AXUIElement approach.

### Approach 5: raise() + delay + focus() ✓
```lua
win:raise()
hs.timer.usleep(10000)  -- 10ms delay
win:focus()
```
**Result**: Works reliably! Window raises visually AND gets keyboard focus.

## Why Timing Matters

macOS window management is asynchronous. When you call `raise()`, it sends a message to the window server, but the operation may not complete immediately. If `focus()` is called before `raise()` completes, the focus operation may target the window at its old z-order position.

The 10ms delay gives the window server time to:
1. Process the raise request
2. Update the window's z-order
3. Complete any internal bookkeeping

Only then can `focus()` reliably give keyboard focus to the now-frontmost window.

## Key Insights

1. **`raise()` vs `AXRaise`**: Both bring the window to the front visually, but `win:raise()` (Hammerspoon native) is simpler and works just as well.

2. **`AXMain` is useless here**: Setting `AXMain = true` just marks a flag; it doesn't actually focus the window or affect z-order.

3. **`focus()` needs the window already raised**: The focus operation works best when the target window is already at the front of the z-order.

4. **Synchronous delays work**: `hs.timer.usleep()` blocks the Lua thread but 10ms is imperceptible to users and ensures proper sequencing.

5. **Border != Focus**: macOS can show a focus border on a window that isn't visually in front. The border indicates keyboard focus intent, not z-order.

## The Solution

```lua
local function focusSingleWindow(win)
  if win:isMinimized() then win:unminimize() end
  win:raise()
  hs.timer.usleep(10000)  -- 10ms delay - critical for reliability
  win:focus()
end
```

## Testing Checklist

When testing focus behavior:
- [ ] Window behind another window on same screen
- [ ] Window on different screen
- [ ] Window from different application
- [ ] Window from same application (e.g., multiple Chrome windows)
- [ ] Minimized window (`focusSingleWindow` calls `unminimize()` automatically)
- [ ] Full-screen window (special handling needed)

## Related Hammerspoon APIs

| Method | What it does |
|--------|--------------|
| `win:raise()` | Brings window to front visually (z-order) |
| `win:focus()` | Gives window keyboard focus + activates app |
| `win:becomeMain()` | Makes window the main window of its app |
| `app:activate()` | Brings app to front, focuses its main window |
| `hs.window.focusedWindow()` | Returns the currently focused window |

## Debug Logging

When debugging focus issues, log:
1. Target window (app + title)
2. Return values of `raise()` and `focus()`
3. What's actually focused 100ms later (async check)

```lua
hs.timer.doAfter(0.1, function()
  local focused = hs.window.focusedWindow()
  print("Actually focused:", focused and focused:title())
end)
```
