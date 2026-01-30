hs.window.animationDuration = 0  -- Instant window operations, no animation

hs.loadSpoon("WinWin")
local stepMove = function(dir) spoon.WinWin:stepMove(dir) end
local stepResize = function(dir) spoon.WinWin:stepResize(dir) end

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

  win:setFrame(frame)
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

  win:setFrame(frame)
end

local function smartStepResize(dir)
  local win, frame, screen = setupWindowOperation()
  if not win then return end
  local bottom_edge = screen.y + screen.h - frame.h
  local right_edge = screen.x + screen.w - frame.w
  
  if dir == "left" then
    if frame.x <= screen.x and frame.x < right_edge then --REVERT resize to GROW from left edge
      stepResize("right")
      return
    end
    if frame.x >= right_edge then --SHRINK resize as if STUCK at right edge
      stepResize("left")
      stepMove("right")
      return
    end
  elseif dir == "right" then
    if frame.x <= screen.x then --SHRINK resize as if STUCK at left edge
      stepResize("left")
      return
    end
    if frame.x >= right_edge then --REVERT resize to GROW from edge
      stepMove("left")
    end
  elseif dir == "up" then
    if frame.y <= screen.y and frame.y < bottom_edge then --REVERT resize to GROW from top edge
      stepResize("down")
      return
    end
    if frame.y >= bottom_edge then --SHRINK resize as if STUCK at bottom edge
      stepResize("up")
      stepMove("down")
      return
    end
  elseif dir == "down" then
    if frame.y <= screen.y then --SHRINK resize as if STUCK at top edge
      stepResize("up")
      return
    end
    if frame.y >= bottom_edge then --REVERT resize to GROW from edge
      stepMove("up")
    end
  end

  -- Default to WinWin's step resize if no custom logic matches
  stepResize(dir)
end

local function shrink(dir)
  -- Don't save state when unshrinking right or down
  local shouldSave = dir ~= "right" and dir ~= "down"
  local win, frame, screen = setupWindowOperation(shouldSave)
  if not win then return end
  if dir == "left" then -- SHRINK till min width
    local lastWidth = frame.w
    for i = 1, 30 do
        stepResize("left")
        local currentWidth = win:frame().w
        print(string.format("Iteration %d - Width: %d", i, currentWidth))
        if currentWidth == lastWidth then
            print("Minimum width reached after", i, "iterations")
            break  -- Window stopped resizing, we've hit the minimum
        end
        lastWidth = currentWidth
    end
  elseif dir == "right" then -- UNSHRINK to original width
    if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        frame.w = lastPos.w
        frame.x = lastPos.x
        win:setFrame(frame)
    end
  elseif dir == "up" then -- SHRINK till min height
    local lastHeight = frame.h
    for i = 1, 30 do
      stepResize("up")
      local currentHeight = win:frame().h
      print(string.format("Iteration %d - Height: %d", i, currentHeight))
      if currentHeight == lastHeight then
          print("Minimum height reached after", i, "iterations")
          break  -- Window stopped resizing, we've hit the minimum
      end
      lastHeight = currentHeight
    end
  elseif dir == "down" then -- UNSHRINK to original height
    if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        
        frame.h = lastPos.h
        frame.y = lastPos.y
        
        win:setFrame(frame)
        return  -- Add return to prevent default behavior
    else
      for i = 1, 8 do
        stepResize("down")
      end
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

  win:setFrame(frame)
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

  win:setFrame(frame)
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

-- Focus window in direction (on same screen, with wrap-around)
local function focusDirection(dir)
  local win = hs.window.focusedWindow()
  if not win then return end

  local currentScreen = win:screen()
  local currentScreenID = currentScreen:id()
  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the same screen (including current)
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() and w:screen():id() == currentScreenID then
      local frame = w:frame()
      local pos = (dir == "left" or dir == "right") and frame.x or frame.y
      table.insert(screenWindows, {win = w, pos = pos})
    end
  end

  if #screenWindows <= 1 then return end  -- No other windows to focus

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

  if not currentIdx then return end

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
  targetWin:focus()
  flashFocusHighlight(targetWin, dir)
end

-- Focus window on adjacent screen (focusing the window closest to where you came from)
local function focusScreen(dir)
  local win = hs.window.focusedWindow()
  local currentScreen = win and win:screen() or hs.mouse.getCurrentScreen()
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

  local targetScreenID = targetScreen:id()
  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the target screen
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() and w:screen():id() == targetScreenID then
      local frame = w:frame()
      table.insert(screenWindows, {win = w, frame = frame})
    end
  end

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
  targetWin:focus()
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
  [{"option"}]         = {fn = function(dir) shrink(dir) end}
}

-- Bind all operations
for key, dir in pairs(keyMap) do
    for mods, op in pairs(operations) do
        bindWithRepeat(mods, key, function()
            op.fn(dir)
        end)
    end
end

-- Special bindings for ctrl+option (focus direction)
bindWithRepeat({"ctrl", "option"}, "home", function() focusDirection("left") end)
bindWithRepeat({"ctrl", "option"}, "end", function() focusDirection("right") end)
bindWithRepeat({"ctrl", "option"}, "pageup", function() focusDirection("up") end)
bindWithRepeat({"ctrl", "option"}, "pagedown", function() focusDirection("down") end)

-- Special bindings for shift+option (center/maximize)
bindWithRepeat({"shift", "option"}, "pageup", toggleCenter)
bindWithRepeat({"shift", "option"}, "pagedown", toggleMaximize)

-- Special bindings for ctrl+option+cmd (focus across screens)
bindWithRepeat({"ctrl", "option", "cmd"}, "home", function() focusScreen("left") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "end", function() focusScreen("right") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "pageup", function() focusScreen("up") end)
bindWithRepeat({"ctrl", "option", "cmd"}, "pagedown", function() focusScreen("down") end)

-- Show focus highlight on current window (fn+ctrl+option+delete = forwarddelete)
hs.hotkey.bind({"ctrl", "option"}, "forwarddelete", function()
  local win = hs.window.focusedWindow()
  if win then flashFocusHighlight(win, nil) end
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