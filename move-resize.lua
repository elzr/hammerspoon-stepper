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

-- Move window to edge
local function moveToEdge(dir)
  local win, frame, screen = setupWindowOperation()
  if not win then return end
  
  if dir == "left" then
      frame.x = screen.x
  elseif dir == "right" then
      frame.x = screen.x + screen.w - frame.w
  elseif dir == "up" then
      frame.y = screen.y
  elseif dir == "down" then
      frame.y = screen.y + screen.h - frame.h
  end
  
  win:setFrame(frame)
end

-- Resize window to edge
local function resizeToEdge(dir)
  local win, frame, screen = setupWindowOperation()
  if not win then return end
  
  if dir == "left" then
      -- Move to right edge first, then resize left
      frame.x = screen.x + screen.w - frame.w
      win:setFrame(frame)
      frame.w = frame.w + frame.x - screen.x
      frame.x = screen.x
  elseif dir == "right" then
      frame.w = screen.x + screen.w - frame.x
  elseif dir == "up" then
      -- Move to bottom edge first, then resize up
      frame.y = screen.y + screen.h - frame.h
      win:setFrame(frame)
      frame.h = frame.h + frame.y - screen.y
      frame.y = screen.y
  elseif dir == "down" then
      frame.h = screen.y + screen.h - frame.y
  end
  
  win:setFrame(frame)
end

local function smartStepResize(dir)
  local win, frame, screen = setupWindowOperation()
  if not win then return end
  local bottom_edge = screen.y + screen.h - frame.h
  local right_edge = screen.x + screen.w - frame.w
  
  if dir == "left" then
    if frame.x >= right_edge then --SHRINK resize as if STUCK at edge
      stepResize("left")
      stepMove("right")
      return
    end
  elseif dir == "right" then
    if frame.x >= right_edge then --REVERT resize to GROW from edge
      stepMove("left")
    end
  elseif dir == "up" then
    if frame.y >= bottom_edge then --SHRINK resize as if STUCK at edge
      stepResize("up")
      stepMove("down")
      return
    end
  elseif dir == "down" then
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