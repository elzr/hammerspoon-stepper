-- =============================================================================
-- Window focus navigation (same screen + cross-screen)
-- =============================================================================
-- Provides directional focus switching with:
-- - Occlusion detection (skip fully hidden windows)
-- - Center-point screen detection (reliable for edge-spanning windows)
-- - Visual highlight feedback
-- - Chrome-style app focus jump workaround

local M = {}

-- Module state
local focusHighlight = nil
local lastFocusedByUs = nil

-- =============================================================================
-- Helper functions
-- =============================================================================

-- Check if a window's center point is within a screen's frame
local function isWindowCenteredOnScreen(winFrame, screenFrame)
  local centerX = winFrame.x + winFrame.w / 2
  local centerY = winFrame.y + winFrame.h / 2
  return centerX >= screenFrame.x and centerX < screenFrame.x + screenFrame.w and
         centerY >= screenFrame.y and centerY < screenFrame.y + screenFrame.h
end

-- Find the screen containing a point (more reliable than win:screen() for edge cases)
local function getScreenAtPoint(x, y)
  for _, screen in ipairs(hs.screen.allScreens()) do
    local sf = screen:frame()
    if x >= sf.x and x < sf.x + sf.w and
       y >= sf.y and y < sf.y + sf.h then
      return screen
    end
  end
  return nil
end

-- Check if a window frame has at least some visible portion (not fully occluded by frames above it)
-- Takes pre-cached frames to avoid repeated API calls
local function isFrameVisible(frame, framesAbove)
  -- Check 5 points: 4 corners (inset by 5px) + center
  local checkPoints = {
    {x = frame.x + 5, y = frame.y + 5},                           -- top-left
    {x = frame.x + frame.w - 5, y = frame.y + 5},                 -- top-right
    {x = frame.x + 5, y = frame.y + frame.h - 5},                 -- bottom-left
    {x = frame.x + frame.w - 5, y = frame.y + frame.h - 5},       -- bottom-right
    {x = frame.x + frame.w / 2, y = frame.y + frame.h / 2},       -- center
  }

  for _, point in ipairs(checkPoints) do
    local covered = false
    for _, aboveFrame in ipairs(framesAbove) do
      if point.x >= aboveFrame.x and point.x < aboveFrame.x + aboveFrame.w and
         point.y >= aboveFrame.y and point.y < aboveFrame.y + aboveFrame.h then
        covered = true
        break
      end
    end
    if not covered then
      return true  -- At least one point is visible
    end
  end

  return false  -- All points covered
end

-- Focus a single window without moving mouse
-- raise() brings to front visually, focus() gives keyboard focus
local function focusSingleWindow(win)
  local app = win:application()
  local appName = app and app:name() or "unknown"
  local winTitle = win:title() or "untitled"
  print(string.format("[focusSingleWindow] Targeting: %s - %s", appName, winTitle))

  local raiseResult = win:raise()
  print(string.format("[focusSingleWindow] raise() returned: %s", tostring(raiseResult)))

  hs.timer.usleep(10000)  -- 10ms delay

  local focusResult = win:focus()
  print(string.format("[focusSingleWindow] focus() returned: %s", tostring(focusResult)))

  -- Check what actually got focused
  hs.timer.doAfter(0.1, function()
    local focused = hs.window.focusedWindow()
    if focused then
      local focusedApp = focused:application()
      print(string.format("[focusSingleWindow] After 100ms, focused: %s - %s",
        focusedApp and focusedApp:name() or "unknown",
        focused:title() or "untitled"))
    else
      print("[focusSingleWindow] After 100ms, no focused window!")
    end
  end)
end

-- =============================================================================
-- Visual feedback
-- =============================================================================

-- Flash a border around a window to highlight it (thicker on the focus direction side)
function M.flashFocusHighlight(win, dir)
  if focusHighlight then
    focusHighlight:delete()
    focusHighlight = nil
  end

  local frame = win:frame()
  local thin = 4
  local thick = 12
  local radius = 10  -- macOS-style rounded corners
  local color = {red = 0.4, green = 0.7, blue = 1.0, alpha = 0.9}
  local padding = thick / 2 + 2

  focusHighlight = hs.canvas.new({
    x = frame.x - padding,
    y = frame.y - padding,
    w = frame.w + padding * 2,
    h = frame.h + padding * 2
  })

  -- Base rounded rectangle border (thin)
  focusHighlight:appendElements({
    type = "rectangle",
    action = "stroke",
    strokeColor = color,
    strokeWidth = thin,
    roundedRectRadii = {xRadius = radius, yRadius = radius},
    frame = {x = padding - thin/2, y = padding - thin/2, w = frame.w + thin, h = frame.h + thin}
  })

  -- Thick emphasis line on the directional side
  local emphasisLine = nil
  if dir == "left" then
    emphasisLine = {
      type = "segments",
      action = "stroke",
      strokeColor = color,
      strokeWidth = thick,
      strokeCapStyle = "round",
      coordinates = {
        {x = padding, y = padding + radius},
        {x = padding, y = padding + frame.h - radius}
      }
    }
  elseif dir == "right" then
    emphasisLine = {
      type = "segments",
      action = "stroke",
      strokeColor = color,
      strokeWidth = thick,
      strokeCapStyle = "round",
      coordinates = {
        {x = padding + frame.w, y = padding + radius},
        {x = padding + frame.w, y = padding + frame.h - radius}
      }
    }
  elseif dir == "up" then
    emphasisLine = {
      type = "segments",
      action = "stroke",
      strokeColor = color,
      strokeWidth = thick,
      strokeCapStyle = "round",
      coordinates = {
        {x = padding + radius, y = padding},
        {x = padding + frame.w - radius, y = padding}
      }
    }
  elseif dir == "down" then
    emphasisLine = {
      type = "segments",
      action = "stroke",
      strokeColor = color,
      strokeWidth = thick,
      strokeCapStyle = "round",
      coordinates = {
        {x = padding + radius, y = padding + frame.h},
        {x = padding + frame.w - radius, y = padding + frame.h}
      }
    }
  end

  if emphasisLine then
    focusHighlight:appendElements(emphasisLine)
  end

  focusHighlight:show()

  -- Fade out after a brief moment
  hs.timer.doAfter(0.3, function()
    if focusHighlight then
      focusHighlight:delete()
      focusHighlight = nil
    end
  end)
end

-- =============================================================================
-- Focus navigation
-- =============================================================================

-- Focus window in direction (on same screen, with wrap-around)
function M.focusDirection(dir)
  local win = hs.window.focusedWindow()
  if not win then return end

  -- Work around apps (like Chrome) that switch focus to a different window on another screen
  -- Only intervene if: same app, different screen (user clicking different app = intentional)
  if lastFocusedByUs then
    local lastWin = hs.window.get(lastFocusedByUs)
    if lastWin and lastWin:isVisible() then
      local sameApp = win:application():pid() == lastWin:application():pid()
      if sameApp then
        local lastFrame = lastWin:frame()
        local lastCenterX = lastFrame.x + lastFrame.w / 2
        local lastCenterY = lastFrame.y + lastFrame.h / 2
        local lastScreen = getScreenAtPoint(lastCenterX, lastCenterY)

        local winFrame = win:frame()
        local winCenterX = winFrame.x + winFrame.w / 2
        local winCenterY = winFrame.y + winFrame.h / 2
        local winScreen = getScreenAtPoint(winCenterX, winCenterY)

        -- Same app jumped to different screen = likely Chrome-style bug
        if lastScreen and winScreen and lastScreen:id() ~= winScreen:id() then
          print(string.format("[focusDirection] Same app jumped screens! Using tracked window instead"))
          win = lastWin
        end
      else
        -- Different app = user intentionally switched, clear tracking
        lastFocusedByUs = nil
      end
    end
  end

  -- Use the screen containing the window's center (consistent with our filtering logic)
  local winFrame = win:frame()
  local centerX = winFrame.x + winFrame.w / 2
  local centerY = winFrame.y + winFrame.h / 2
  local currentScreen = getScreenAtPoint(centerX, centerY) or win:screen()
  local screenFrame = currentScreen:frame()

  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the same screen (in z-order, front to back)
  -- Use center-point check instead of w:screen() for reliability with edge-spanning windows
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() then
      local frame = w:frame()
      if isWindowCenteredOnScreen(frame, screenFrame) then
        local pos = (dir == "left" or dir == "right") and frame.x or frame.y
        table.insert(screenWindows, {win = w, frame = frame, pos = pos})
      end
    end
  end

  -- DEBUG: Log screen info and all windows before occlusion filter
  print(string.format("[focusDirection] dir=%s, screen: x=%d w=%d, from: %s",
    dir, screenFrame.x, screenFrame.w, win:application():name()))
  print(string.format("[focusDirection] Before occlusion (%d windows):", #screenWindows))
  for i, entry in ipairs(screenWindows) do
    local appName = entry.win:application():name()
    local winScreen = entry.win:screen():name()
    print(string.format("  %d. %s (x=%d, screen=%s)", i, appName, entry.frame.x, winScreen))
  end

  -- Filter to only visible (unoccluded) windows using cached frames
  -- Always include current window so user can navigate away from it
  local visibleWindows = {}
  local framesAbove = {}
  for _, entry in ipairs(screenWindows) do
    if entry.win:id() == win:id() or isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
    -- Add this window's frame to the "above" list for subsequent checks
    table.insert(framesAbove, entry.frame)
  end
  screenWindows = visibleWindows

  if #screenWindows <= 1 then
    print("[focusDirection] Only 1 or 0 windows after occlusion, returning")
    return
  end

  -- Sort by position (ascending)
  table.sort(screenWindows, function(a, b) return a.pos < b.pos end)

  -- Find current window index in sorted list
  local currentIdx = nil
  for i, entry in ipairs(screenWindows) do
    if entry.win:id() == win:id() then
      currentIdx = i
      break
    end
  end

  if not currentIdx then
    print("[focusDirection] Current window not found in list!")
    return
  end

  -- Calculate next index with wrap-around
  local nextIdx
  if dir == "left" or dir == "up" then
    nextIdx = currentIdx - 1
    if nextIdx < 1 then nextIdx = #screenWindows end
  else
    nextIdx = currentIdx + 1
    if nextIdx > #screenWindows then nextIdx = 1 end
  end

  local targetWin = screenWindows[nextIdx].win
  local targetApp = targetWin:application():name()
  local targetScreen = targetWin:screen():name()
  local currentApp = win:application():name()

  -- DEBUG: Log final decision
  print(string.format("[focusDirection] After occlusion & sort (%d windows):", #screenWindows))
  for i, entry in ipairs(screenWindows) do
    local marker = ""
    if i == currentIdx then marker = " <-- CURRENT"
    elseif i == nextIdx then marker = " <-- TARGET"
    end
    print(string.format("  %d. %s (x=%d)%s", i, entry.win:application():name(), entry.pos, marker))
  end
  print(string.format("[focusDirection] FOCUS: %s -> %s (screen: %s)", currentApp, targetApp, targetScreen))

  focusSingleWindow(targetWin)
  lastFocusedByUs = targetWin:id()  -- Track so we can detect if focus jumps unexpectedly
  M.flashFocusHighlight(targetWin, dir)
end

-- Focus window on adjacent screen (focusing the window closest to where you came from)
function M.focusScreen(dir)
  local win = hs.window.focusedWindow()
  local currentScreen
  if win then
    -- Use the screen containing the window's center (consistent with focusDirection)
    local winFrame = win:frame()
    local centerX = winFrame.x + winFrame.w / 2
    local centerY = winFrame.y + winFrame.h / 2
    currentScreen = getScreenAtPoint(centerX, centerY) or win:screen()
  else
    currentScreen = hs.mouse.getCurrentScreen()
  end
  if not currentScreen then return end

  -- Find the screen in the given direction
  local targetScreen
  if dir == "left" then
    targetScreen = currentScreen:toWest()
  elseif dir == "right" then
    targetScreen = currentScreen:toEast()
  elseif dir == "up" then
    targetScreen = currentScreen:toNorth()
  elseif dir == "down" then
    targetScreen = currentScreen:toSouth()
  end

  if not targetScreen then return end  -- No screen in that direction

  local targetScreenFrame = targetScreen:frame()
  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the target screen (in z-order, front to back)
  -- Use center-point check instead of w:screen() for reliability with edge-spanning windows
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() then
      local frame = w:frame()
      if isWindowCenteredOnScreen(frame, targetScreenFrame) then
        table.insert(screenWindows, {win = w, frame = frame})
      end
    end
  end

  if #screenWindows == 0 then return end  -- No windows on target screen

  -- Filter to only visible (unoccluded) windows
  local visibleWindows = {}
  local framesAbove = {}
  for _, entry in ipairs(screenWindows) do
    if isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
    table.insert(framesAbove, entry.frame)
  end
  screenWindows = visibleWindows

  if #screenWindows == 0 then return end

  -- Sort by proximity to current window's position on the shared edge
  local currentFrame = win and win:frame() or nil
  table.sort(screenWindows, function(a, b)
    if not currentFrame then return false end
    -- Calculate distance from current window's center to each window's center
    local distA = math.abs(a.frame.y + a.frame.h/2 - (currentFrame.y + currentFrame.h/2))
    local distB = math.abs(b.frame.y + b.frame.h/2 - (currentFrame.y + currentFrame.h/2))
    return distA < distB
  end)

  local targetWin = screenWindows[1].win
  focusSingleWindow(targetWin)
  lastFocusedByUs = targetWin:id()  -- Track so we can detect if focus jumps unexpectedly
  M.flashFocusHighlight(targetWin, dir)
end

-- Get debug info about tracking state (for the confirm focus hotkey)
function M.getTrackingInfo()
  return lastFocusedByUs
end

return M
