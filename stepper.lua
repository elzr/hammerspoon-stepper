hs.loadSpoon("WinWin")

-- Adaptive animation: luxurious by default, snappy when rapidly iterating
local luxuriousDuration = 0.3
local snappyDuration = 0.1
local rapidThreshold = 0.4  -- seconds between operations to trigger snappy mode
local lastOperationTime = 0
local animationLocked = false

local function updateAnimationDuration()
  local now = hs.timer.secondsSinceEpoch()
  local elapsed = now - lastOperationTime
  lastOperationTime = now

  if animationLocked then return end

  if elapsed < rapidThreshold then
    hs.window.animationDuration = snappyDuration
  else
    hs.window.animationDuration = luxuriousDuration
  end
end

-- Helper for instant (non-animated) window operations
local function instant(fn)
  updateAnimationDuration()  -- Track timing even for instant ops
  local original = hs.window.animationDuration
  animationLocked = true
  hs.window.animationDuration = 0
  fn()
  animationLocked = false
  hs.window.animationDuration = original
end

local function stepMove(dir)
  updateAnimationDuration()
  spoon.WinWin:stepMove(dir)
end

local function stepResize(dir)
  updateAnimationDuration()
  spoon.WinWin:stepResize(dir)
end

-- Minimum shrink sizes for specific apps (add more as needed)
local minShrinkSize = {
  kitty = {w = 900, h = 400},
}

-- Default compact size for PiP mode
local defaultCompactSize = {w = 400, h = 300}

-- Track compact windows: {winID = {original = frame, screenID = id}}
local compactWindows = {}

-- Track shrunk windows for toggle behavior: {winID = {width = originalW, height = originalH}}
local shrunkWindows = {}

-- Track last focused window to work around apps that switch focus to wrong window
local lastFocusedByUs = nil

-- Forward declaration for edge highlight (defined later with other visual feedback)
local flashEdgeHighlight

-- Clear existing hotkeys
local existingHotkeys = hs.hotkey.getHotkeys()
for _, hotkey in ipairs(existingHotkeys) do
  hotkey:delete()
end

local function setupWindowOperation(shouldSave)
  local win = hs.window.focusedWindow()
  if not win then return nil end
  
  local frame = win:frame()
  local screen = win:screen():frame()
  
  -- Save original position for WinWin's undo
  -- but only if shouldSave is true
  -- and only for properties that changed
  if shouldSave ~= false then  -- saves by default if no parameter passed
    -- get first position or empty table if nil
    local lastPos = (spoon.WinWin._lastPositions or {})[1] or {}
    local newPos = {}

    for _, prop in ipairs({'x', 'y', 'w', 'h'}) do
          newPos[prop] = (
              frame[prop] ~= lastPos[prop]  -- change?
              and frame[prop]               -- if true: use new value
              or lastPos[prop]              -- if false: keep old value
          )
      end
      
    spoon.WinWin._lastPositions = {newPos}
    spoon.WinWin._lastWins = {win}
  end
  
  return win, frame, screen
end

-- Move window to edge (or restore if already at edge)
local function moveToEdge(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  -- Check if already at target edge
  local atEdge = (dir == "left" and frame.x <= screen.x) or
                 (dir == "right" and frame.x + frame.w >= screen.x + screen.w) or
                 (dir == "up" and frame.y <= screen.y) or
                 (dir == "down" and frame.y + frame.h >= screen.y + screen.h)

  if atEdge and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous position
    local lastPos = spoon.WinWin._lastPositions[1]
    if dir == "left" or dir == "right" then
      frame.x = lastPos.x or frame.x
    else
      frame.y = lastPos.y or frame.y
    end
  else
    -- Save current position, then move to edge
    setupWindowOperation(true)
    flashEdgeHighlight(screen, dir)
    if dir == "left" then
        frame.x = screen.x
    elseif dir == "right" then
        frame.x = screen.x + screen.w - frame.w
    elseif dir == "up" then
        frame.y = screen.y
    elseif dir == "down" then
        frame.y = screen.y + screen.h - frame.h
    end
  end

  instant(function() win:setFrame(frame) end)
end

-- Resize window to edge (or restore if already at edge)
local function resizeToEdge(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  -- Check if already extends to target edge
  local atEdge = (dir == "left" and frame.x <= screen.x) or
                 (dir == "right" and frame.x + frame.w >= screen.x + screen.w) or
                 (dir == "up" and frame.y <= screen.y) or
                 (dir == "down" and frame.y + frame.h >= screen.y + screen.h)

  if atEdge and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous size/position
    local lastPos = spoon.WinWin._lastPositions[1]
    if dir == "left" or dir == "right" then
      frame.x = lastPos.x or frame.x
      frame.w = lastPos.w or frame.w
    else
      frame.y = lastPos.y or frame.y
      frame.h = lastPos.h or frame.h
    end
  else
    -- Save current position, then resize to edge (single step)
    setupWindowOperation(true)
    flashEdgeHighlight(screen, dir)
    if dir == "left" then
        -- Expand to left edge, keeping right edge fixed
        frame.w = frame.x + frame.w - screen.x
        frame.x = screen.x
    elseif dir == "right" then
        -- Expand to right edge, keeping left edge fixed
        frame.w = screen.x + screen.w - frame.x
    elseif dir == "up" then
        -- Expand to top edge, keeping bottom edge fixed
        frame.h = frame.y + frame.h - screen.y
        frame.y = screen.y
    elseif dir == "down" then
        -- Expand to bottom edge, keeping top edge fixed
        frame.h = screen.y + screen.h - frame.y
    end
  end

  instant(function() win:setFrame(frame) end)
end

local function smartStepResize(dir)
  local win, frame, screen = setupWindowOperation()
  if not win then return end
  local bottom_edge = screen.y + screen.h - frame.h
  local right_edge = screen.x + screen.w - frame.w
  
  if dir == "left" then
    if frame.x <= screen.x and frame.x < right_edge then --REVERT resize to GROW from left edge
      flashEdgeHighlight(screen, "left")
      stepResize("right")
      return
    end
    if frame.x >= right_edge then --SHRINK resize as if STUCK at right edge
      flashEdgeHighlight(screen, "right")
      stepResize("left")
      stepMove("right")
      return
    end
  elseif dir == "right" then
    if frame.x <= screen.x then --SHRINK resize as if STUCK at left edge
      flashEdgeHighlight(screen, "left")
      stepResize("left")
      return
    end
    if frame.x >= right_edge then --REVERT resize to GROW from edge
      flashEdgeHighlight(screen, "right")
      stepMove("left")
    end
  elseif dir == "up" then
    if frame.y <= screen.y and frame.y < bottom_edge then --REVERT resize to GROW from top edge
      flashEdgeHighlight(screen, "up")
      stepResize("down")
      return
    end
    if frame.y >= bottom_edge then --SHRINK resize as if STUCK at bottom edge
      flashEdgeHighlight(screen, "down")
      stepResize("up")
      stepMove("down")
      return
    end
  elseif dir == "down" then
    if frame.y <= screen.y then --SHRINK resize as if STUCK at top edge
      flashEdgeHighlight(screen, "up")
      stepResize("up")
      return
    end
    if frame.y >= bottom_edge then --REVERT resize to GROW from edge
      flashEdgeHighlight(screen, "down")
      stepMove("up")
    end
  end

  -- Default to WinWin's step resize if no custom logic matches
  stepResize(dir)
end

-- Toggle shrink width (left) or height (up)
local function toggleShrink(dir)
  instant(function()
    local win, frame, screen = setupWindowOperation(false)
    if not win then return end
    local winID = win:id()

    -- Get app-specific minimum size (if any)
    local appName = win:application():name():lower()
    local minSize = minShrinkSize[appName] or {w = 0, h = 0}

    -- Initialize tracking for this window if needed
    if not shrunkWindows[winID] then
      shrunkWindows[winID] = {}
    end

    if dir == "left" then
      -- Toggle width shrink
      if shrunkWindows[winID].width then
        -- Restore original width
        frame.w = shrunkWindows[winID].width
        frame.x = shrunkWindows[winID].x
        win:setFrame(frame)
        shrunkWindows[winID].width = nil
        shrunkWindows[winID].x = nil
      else
        -- Save current width and shrink
        shrunkWindows[winID].width = frame.w
        shrunkWindows[winID].x = frame.x
        local lastWidth = frame.w
        for i = 1, 30 do
          stepResize("left")
          local currentWidth = win:frame().w
          if currentWidth == lastWidth or currentWidth <= minSize.w then
            break
          end
          lastWidth = currentWidth
        end
      end
    elseif dir == "up" then
      -- Toggle height shrink
      if shrunkWindows[winID].height then
        -- Restore original height
        frame.h = shrunkWindows[winID].height
        frame.y = shrunkWindows[winID].y
        win:setFrame(frame)
        shrunkWindows[winID].height = nil
        shrunkWindows[winID].y = nil
      else
        -- Save current height and shrink
        shrunkWindows[winID].height = frame.h
        shrunkWindows[winID].y = frame.y
        local lastHeight = frame.h
        for i = 1, 30 do
          stepResize("up")
          local currentHeight = win:frame().h
          if currentHeight == lastHeight or currentHeight <= minSize.h then
            break
          end
          lastHeight = currentHeight
        end
      end
    end

    -- Clean up empty entries
    if not shrunkWindows[winID].width and not shrunkWindows[winID].height then
      shrunkWindows[winID] = nil
    end
  end)
end

-- Restore shrunk dimension, or grow to edge if not shrunk (toggle)
local function restoreOrGrow(dir)
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end
  local winID = win:id()

  if dir == "right" then
    -- Check if width is shrunk
    if shrunkWindows[winID] and shrunkWindows[winID].width then
      -- Restore shrunk width
      instant(function()
        frame.w = shrunkWindows[winID].width
        frame.x = shrunkWindows[winID].x
        win:setFrame(frame)
      end)
      shrunkWindows[winID].width = nil
      shrunkWindows[winID].x = nil
      if not shrunkWindows[winID].height then
        shrunkWindows[winID] = nil
      end
    else
      -- Not shrunk - resize to right edge (toggle)
      resizeToEdge("right")
    end
  elseif dir == "down" then
    -- Check if height is shrunk
    if shrunkWindows[winID] and shrunkWindows[winID].height then
      -- Restore shrunk height
      instant(function()
        frame.h = shrunkWindows[winID].height
        frame.y = shrunkWindows[winID].y
        win:setFrame(frame)
      end)
      shrunkWindows[winID].height = nil
      shrunkWindows[winID].y = nil
      if not shrunkWindows[winID].width then
        shrunkWindows[winID] = nil
      end
    else
      -- Not shrunk - resize to bottom edge (toggle)
      resizeToEdge("down")
    end
  end
end

-- Toggle maximize/restore
local function toggleMaximize()
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  -- Check if already maximized (within 10px tolerance)
  local isMaximized = math.abs(frame.x - screen.x) < 10 and
                      math.abs(frame.y - screen.y) < 10 and
                      math.abs(frame.w - screen.w) < 10 and
                      math.abs(frame.h - screen.h) < 10

  if isMaximized and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous position
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.x = lastPos.x or frame.x
    frame.y = lastPos.y or frame.y
    frame.w = lastPos.w or frame.w
    frame.h = lastPos.h or frame.h
  else
    -- Save current position, then maximize
    setupWindowOperation(true)
    frame.x = screen.x
    frame.y = screen.y
    frame.w = screen.w
    frame.h = screen.h
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle center: vertical first, then horizontal, then restore
local function toggleCenter()
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  local centerX = screen.x + (screen.w - frame.w) / 2
  local centerY = screen.y + (screen.h - frame.h) / 2
  local isCenteredH = math.abs(frame.x - centerX) < 10
  local isCenteredV = math.abs(frame.y - centerY) < 10

  if not isCenteredV then
    -- First: center vertically
    setupWindowOperation(true)
    frame.y = centerY
  elseif not isCenteredH then
    -- Second: center horizontally
    frame.x = centerX
  elseif spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Third: restore previous position
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.x = lastPos.x or frame.x
    frame.y = lastPos.y or frame.y
  end

  instant(function() win:setFrame(frame) end)
end

-- Cycle through half/third width aligned to edge (or restore)
local function cycleHalfThird(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  local halfW = screen.w / 2
  local thirdW = screen.w / 3
  local tolerance = 10

  local atLeft = math.abs(frame.x - screen.x) < tolerance
  local atRight = math.abs((frame.x + frame.w) - (screen.x + screen.w)) < tolerance
  local isHalf = math.abs(frame.w - halfW) < tolerance
  local isThird = math.abs(frame.w - thirdW) < tolerance
  local isFullHeight = math.abs(frame.h - screen.h) < tolerance

  if dir == "left" then
    if atLeft and isHalf and isFullHeight then
      -- Half → Third (stay full height)
      frame.w = thirdW
      frame.x = screen.x
    elseif atLeft and isThird and isFullHeight then
      -- Third → Restore
      if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        frame.x = lastPos.x or frame.x
        frame.y = lastPos.y or frame.y
        frame.w = lastPos.w or frame.w
        frame.h = lastPos.h or frame.h
      end
    else
      -- Any other state → Half + full height (save first)
      setupWindowOperation(true)
      frame.x = screen.x
      frame.y = screen.y
      frame.w = halfW
      frame.h = screen.h
    end
  else  -- right
    if atRight and isHalf and isFullHeight then
      -- Half → Third (stay full height)
      frame.w = thirdW
      frame.x = screen.x + screen.w - frame.w
    elseif atRight and isThird and isFullHeight then
      -- Third → Restore
      if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        frame.x = lastPos.x or frame.x
        frame.y = lastPos.y or frame.y
        frame.w = lastPos.w or frame.w
        frame.h = lastPos.h or frame.h
      end
    else
      -- Any other state → Half + full height (save first)
      setupWindowOperation(true)
      frame.y = screen.y
      frame.w = halfW
      frame.h = screen.h
      frame.x = screen.x + screen.w - frame.w
    end
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle max height (keep width/x, expand height to full screen)
local function toggleMaxHeight()
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end

  local tolerance = 10
  local isMaxHeight = math.abs(frame.y - screen.y) < tolerance and
                      math.abs(frame.h - screen.h) < tolerance

  if isMaxHeight and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous height/y
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.y = lastPos.y or frame.y
    frame.h = lastPos.h or frame.h
  else
    -- Save current position, then maximize height
    setupWindowOperation(true)
    flashEdgeHighlight(screen, {"up", "down"})
    frame.y = screen.y
    frame.h = screen.h
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle native macOS fullscreen
local function toggleFullScreen()
  local win = hs.window.focusedWindow()
  if win then win:toggleFullScreen() end
end

-- Toggle max width (keep height/y, expand width to full screen)
local function toggleMaxWidth()
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end

  local tolerance = 10
  local isMaxWidth = math.abs(frame.x - screen.x) < tolerance and
                     math.abs(frame.w - screen.w) < tolerance

  if isMaxWidth and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous width/x
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.x = lastPos.x or frame.x
    frame.w = lastPos.w or frame.w
  else
    -- Save current position, then maximize width
    setupWindowOperation(true)
    flashEdgeHighlight(screen, {"left", "right"})
    frame.x = screen.x
    frame.w = screen.w
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle compact/PiP mode (shrink to min size, stack at bottom of screen)
-- Works like a dock: compacted windows line up from left to right at screen bottom
local function toggleCompact()
  local win = hs.window.focusedWindow()
  if not win then return end

  local winID = win:id()
  local frame = win:frame()
  local screenObj = win:screen()
  local screen = screenObj:frame()
  local currentScreenID = screenObj:id()

  -- Check if this window is already compact (has saved original frame)
  if compactWindows[winID] then
    -- Restore original frame
    instant(function() win:setFrame(compactWindows[winID].original) end)
    compactWindows[winID] = nil
    return
  end

  -- Get compact size (app-specific or default)
  local appName = win:application():name():lower()
  local compactSize = minShrinkSize[appName] or defaultCompactSize
  local compactW = compactSize.w
  local compactH = compactSize.h

  -- Clean up stale entries and collect valid compact windows on this screen by row
  -- Row 0 = bottom, Row 1 = one up, etc.
  local rows = {}  -- rows[rowNum] = sorted list of {x, rightEdge}
  local staleIDs = {}

  for otherWinID, info in pairs(compactWindows) do
    local otherWin = hs.window.get(otherWinID)
    if not otherWin or not otherWin:isVisible() then
      -- Window no longer exists or is hidden - mark for cleanup
      table.insert(staleIDs, otherWinID)
    elseif info.screenID == currentScreenID then
      -- Valid compact window on this screen
      local otherFrame = otherWin:frame()
      -- Determine row based on y position (bottom of screen = row 0)
      local bottomY = screen.y + screen.h
      local rowNum = math.floor((bottomY - otherFrame.y - otherFrame.h + compactH/2) / compactH)
      if rowNum < 0 then rowNum = 0 end

      if not rows[rowNum] then rows[rowNum] = {} end
      table.insert(rows[rowNum], {
        x = otherFrame.x,
        rightEdge = otherFrame.x + otherFrame.w
      })
    end
  end

  -- Remove stale entries
  for _, id in ipairs(staleIDs) do
    compactWindows[id] = nil
  end

  -- Sort each row by x position
  for rowNum, rowWindows in pairs(rows) do
    table.sort(rowWindows, function(a, b) return a.x < b.x end)
  end

  -- Find placement: start at row 0, find the rightmost edge, place after it
  -- If row is full, go to next row
  local maxX = screen.x + screen.w - compactW
  local slotX = screen.x
  local slotRow = 0

  for rowNum = 0, 10 do  -- Check up to 10 rows
    local rowWindows = rows[rowNum]
    if not rowWindows or #rowWindows == 0 then
      -- Empty row - start at left edge
      slotX = screen.x
      slotRow = rowNum
      break
    else
      -- Find rightmost edge in this row
      local rightmost = screen.x
      for _, w in ipairs(rowWindows) do
        if w.rightEdge > rightmost then
          rightmost = w.rightEdge
        end
      end
      -- Check if there's room for another window
      if rightmost <= maxX then
        slotX = rightmost
        slotRow = rowNum
        break
      end
      -- Row is full, try next row
    end
  end

  -- Calculate final position
  local newFrame = {
    x = slotX,
    y = screen.y + screen.h - compactH - (slotRow * compactH),
    w = compactW,
    h = compactH
  }

  -- Save original frame and screen before compacting
  compactWindows[winID] = {
    original = {x = frame.x, y = frame.y, w = frame.w, h = frame.h},
    screenID = currentScreenID
  }

  flashEdgeHighlight(screen, {"down", "left"})
  instant(function() win:setFrame(newFrame) end)
end

-- Flash a thick blue border on the screen edge(s)
-- dir can be a single direction ("left") or a table of directions ({"left", "right"})
local edgeHighlight = nil
flashEdgeHighlight = function(screen, dir)
  if edgeHighlight then
    edgeHighlight:delete()
    edgeHighlight = nil
  end

  local thick = 12
  local color = {red = 0.4, green = 0.7, blue = 1.0, alpha = 0.9}

  -- Normalize to table of directions
  local dirs = type(dir) == "table" and dir or {dir}

  -- Create full-screen canvas to hold all edge lines
  edgeHighlight = hs.canvas.new({x = screen.x, y = screen.y, w = screen.w, h = screen.h})

  for _, d in ipairs(dirs) do
    local lineCoords
    if d == "left" then
      lineCoords = {
        {x = thick / 2, y = 0},
        {x = thick / 2, y = screen.h}
      }
    elseif d == "right" then
      lineCoords = {
        {x = screen.w - thick / 2, y = 0},
        {x = screen.w - thick / 2, y = screen.h}
      }
    elseif d == "up" then
      lineCoords = {
        {x = 0, y = thick / 2},
        {x = screen.w, y = thick / 2}
      }
    elseif d == "down" then
      lineCoords = {
        {x = 0, y = screen.h - thick / 2},
        {x = screen.w, y = screen.h - thick / 2}
      }
    end

    if lineCoords then
      edgeHighlight:appendElements({
        type = "segments",
        action = "stroke",
        strokeColor = color,
        strokeWidth = thick,
        strokeCapStyle = "butt",
        coordinates = lineCoords
      })
    end
  end

  edgeHighlight:show()

  hs.timer.doAfter(0.3, function()
    if edgeHighlight then
      edgeHighlight:delete()
      edgeHighlight = nil
    end
  end)
end

-- Flash a border around a window to highlight it (thicker on the focus direction side)
local focusHighlight = nil
local function flashFocusHighlight(win, dir)
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
    for _, af in ipairs(framesAbove) do
      if point.x >= af.x and point.x <= af.x + af.w and
         point.y >= af.y and point.y <= af.y + af.h then
        covered = true
        break
      end
    end
    if not covered then return true end  -- At least one point visible
  end
  return false  -- All points covered
end

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

-- Focus window in direction (on same screen, with wrap-around)
local function focusDirection(dir)
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
  for i, entry in ipairs(screenWindows) do
    local framesAbove = {}
    for j = 1, i - 1 do  -- All windows earlier in z-order = above
      table.insert(framesAbove, screenWindows[j].frame)
    end
    if entry.win:id() == win:id() or isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
  end
  screenWindows = visibleWindows

  if #screenWindows <= 1 then
    print("[focusDirection] Only 1 or 0 windows after occlusion, returning")
    return
  end

  -- Sort by position (ascending)
  table.sort(screenWindows, function(a, b) return a.pos < b.pos end)

  -- Find current window's index
  local currentIdx = nil
  for i, w in ipairs(screenWindows) do
    if w.win:id() == win:id() then
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
    if nextIdx < 1 then nextIdx = #screenWindows end  -- Wrap to end
  else
    nextIdx = currentIdx + 1
    if nextIdx > #screenWindows then nextIdx = 1 end  -- Wrap to start
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
  flashFocusHighlight(targetWin, dir)
end

-- Focus window on adjacent screen (focusing the window closest to where you came from)
local function focusScreen(dir)
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

  -- Filter to only visible (unoccluded) windows using cached frames
  local visibleWindows = {}
  for i, entry in ipairs(screenWindows) do
    local framesAbove = {}
    for j = 1, i - 1 do  -- All windows earlier in z-order = above
      table.insert(framesAbove, screenWindows[j].frame)
    end
    if isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
  end
  screenWindows = visibleWindows

  if #screenWindows == 0 then return end  -- No windows on target screen

  -- Sort by "closeness to where we came from"
  -- left: want rightmost right edge (frame.x + frame.w, descending)
  -- right: want leftmost left edge (frame.x, ascending)
  -- up: want bottommost bottom edge (frame.y + frame.h, descending)
  -- down: want topmost top edge (frame.y, ascending)
  table.sort(screenWindows, function(a, b)
    if dir == "left" then
      return (a.frame.x + a.frame.w) > (b.frame.x + b.frame.w)
    elseif dir == "right" then
      return a.frame.x < b.frame.x
    elseif dir == "up" then
      return (a.frame.y + a.frame.h) > (b.frame.y + b.frame.h)
    elseif dir == "down" then
      return a.frame.y < b.frame.y
    end
  end)

  local targetWin = screenWindows[1].win
  focusSingleWindow(targetWin)
  lastFocusedByUs = targetWin:id()  -- Track so we can detect if focus jumps unexpectedly
  flashFocusHighlight(targetWin, dir)
end

local function bindWithRepeat(mods, key, fn)
    hs.hotkey.bind(mods, key, fn, nil, fn)
end

-- Define mappings of keys to dirs
local keyMap = {
  home = "left",
  ["end"] = "right",
  pageup = "up",
  pagedown = "down"
}

-- Define operations with modifiers
local operations = {
  [{} ]                = {fn = function(dir) stepMove(dir) end},
  [{"shift"}]          = {fn = function(dir) smartStepResize(dir) end},
  [{"ctrl"}]           = {fn = function(dir) moveToEdge(dir) end},
  [{"ctrl", "shift"}]  = {fn = function(dir) resizeToEdge(dir) end},
  -- option is handled separately below for toggle shrink behavior
}

-- Bind all operations
for key, dir in pairs(keyMap) do
    for mods, op in pairs(operations) do
        bindWithRepeat(mods, key, function()
            op.fn(dir)
        end)
    end
end

-- Special bindings for option (shrink/grow)
bindWithRepeat({"option"}, "home", function() toggleShrink("left") end)
bindWithRepeat({"option"}, "pageup", function() toggleShrink("up") end)
bindWithRepeat({"option"}, "end", function() restoreOrGrow("right") end)
bindWithRepeat({"option"}, "pagedown", function() restoreOrGrow("down") end)

-- Special bindings for ctrl+option (focus direction)
bindWithRepeat({"ctrl", "option"}, "home", function() focusDirection("left") end)
bindWithRepeat({"ctrl", "option"}, "end", function() focusDirection("right") end)
bindWithRepeat({"ctrl", "option"}, "pageup", function() focusDirection("up") end)
bindWithRepeat({"ctrl", "option"}, "pagedown", function() focusDirection("down") end)

-- Special bindings for shift+option (center/maximize/half-third)
bindWithRepeat({"shift", "option"}, "home", function() cycleHalfThird("left") end)
bindWithRepeat({"shift", "option"}, "end", function() cycleHalfThird("right") end)
bindWithRepeat({"shift", "option"}, "pageup", toggleCenter)
bindWithRepeat({"shift", "option"}, "pagedown", toggleMaximize)

-- Special bindings for ctrl+option+cmd (focus across screens)
bindWithRepeat({"ctrl", "option", "cmd"}, "home", function() focusScreen("left") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "end", function() focusScreen("right") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "pageup", function() focusScreen("up") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "pagedown", function() focusScreen("down") end)

-- Special bindings for cmd (max height/width, fullscreen, compact)
hs.hotkey.bind({"cmd"}, "pageup", toggleMaxHeight)
hs.hotkey.bind({"cmd"}, "pagedown", toggleFullScreen)
hs.hotkey.bind({"cmd"}, "end", toggleMaxWidth)
hs.hotkey.bind({"cmd"}, "home", toggleCompact)

-- Show focus highlight on current window (fn+ctrl+option+delete = forwarddelete)
hs.hotkey.bind({"ctrl", "option"}, "forwarddelete", function()
  local win = hs.window.focusedWindow()
  if win then
    local frame = win:frame()
    local screen = win:screen():name()
    local app = win:application():name()
    print(string.format("[confirmFocus] %s at x=%d on %s (tracked: %s)",
      app, frame.x, screen, lastFocusedByUs and tostring(lastFocusedByUs) or "none"))
    flashFocusHighlight(win, nil)
  end
end)

-- =============================================================================
-- Mouse drag to move window under cursor (Cmd+Option+Ctrl + mouse move)
-- =============================================================================
-- Useful for apps like Kitty and Bear where Better Touch Tool doesn't work
--
-- Uses global _G.windowDrag table to prevent garbage collection of eventtaps
-- and includes zombie detection (eventtaps that report enabled but don't fire)

-- Global state to prevent garbage collection
_G.windowDrag = _G.windowDrag or {}
_G.windowDrag.dragState = {
    dragging = false,
    window = nil,
    windowStartX = 0,
    windowStartY = 0,
    mouseStartX = 0,
    mouseStartY = 0
}
_G.windowDrag.mouseMoveHandler = nil
_G.windowDrag.flagsHandler = nil
_G.windowDrag.watchdog = nil
_G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()

local function getWindowUnderMouse()
    local mousePos = hs.mouse.absolutePosition()
    local windows = hs.window.orderedWindows()

    for _, win in ipairs(windows) do
        if win:isStandard() then
            local frame = win:frame()
            if mousePos.x >= frame.x and mousePos.x <= frame.x + frame.w and
               mousePos.y >= frame.y and mousePos.y <= frame.y + frame.h then
                return win
            end
        end
    end
    return nil
end

local function createMouseMoveHandler()
    return hs.eventtap.new({hs.eventtap.event.types.mouseMoved}, function(event)
        -- Track callback time for zombie detection
        _G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local requiredMods = flags.cmd and flags.alt and flags.ctrl
        local dragState = _G.windowDrag.dragState

        if requiredMods then
            if not dragState.dragging then
                -- Start dragging: capture window and initial positions
                local win = getWindowUnderMouse()
                if win then
                    local frame = win:frame()
                    dragState.dragging = true
                    dragState.window = win
                    dragState.windowStartX = frame.x
                    dragState.windowStartY = frame.y
                    local mousePos = hs.mouse.absolutePosition()
                    dragState.mouseStartX = mousePos.x
                    dragState.mouseStartY = mousePos.y
                end
            else
                -- Continue dragging: use event deltas for smoother movement
                if dragState.window and dragState.window:isVisible() then
                    local dx = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaX)
                    local dy = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaY)

                    local frame = dragState.window:frame()
                    dragState.window:setTopLeft({x = frame.x + dx, y = frame.y + dy})
                end
            end
        else
            -- Modifiers released, stop dragging
            if dragState.dragging then
                dragState.dragging = false
                dragState.window = nil
            end
        end

        return false  -- Don't consume the event
    end)
end

local function createFlagsHandler()
    return hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
        -- Track callback time for zombie detection
        _G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local requiredMods = flags.cmd and flags.alt and flags.ctrl
        local dragState = _G.windowDrag.dragState

        if not requiredMods and dragState.dragging then
            dragState.dragging = false
            dragState.window = nil
        end

        return false
    end)
end

local function startEventTaps()
    -- Stop existing handlers if any
    if _G.windowDrag.mouseMoveHandler then
        _G.windowDrag.mouseMoveHandler:stop()
    end
    if _G.windowDrag.flagsHandler then
        _G.windowDrag.flagsHandler:stop()
    end

    -- Create and start new handlers
    _G.windowDrag.mouseMoveHandler = createMouseMoveHandler()
    _G.windowDrag.flagsHandler = createFlagsHandler()

    _G.windowDrag.mouseMoveHandler:start()
    _G.windowDrag.flagsHandler:start()

    -- Reset callback time
    _G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()
end

-- Start the eventtaps
startEventTaps()

-- Stop existing watchdog if reloading
if _G.windowDrag.watchdog then
    _G.windowDrag.watchdog:stop()
end

-- Enhanced watchdog: detect both disabled eventtaps AND zombie state
_G.windowDrag.watchdog = hs.timer.new(3, function()
    local handler = _G.windowDrag.mouseMoveHandler
    if not handler then
        startEventTaps()
        return
    end

    local enabled = handler:isEnabled()
    local timeSinceCallback = hs.timer.secondsSinceEpoch() - _G.windowDrag.lastCallbackTime

    -- Restart if:
    -- 1. Handler reports disabled, OR
    -- 2. No callbacks for 10+ seconds while mouse is visible (zombie state)
    --    (mouse not visible = screensaver/lock, so no events expected)
    if not enabled or (timeSinceCallback > 10 and hs.mouse.absolutePosition()) then
        startEventTaps()
    end
end)
_G.windowDrag.watchdog:start()