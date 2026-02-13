-- =============================================================================
-- Move window to specific named display
-- =============================================================================
-- Provides direct keyboard shortcuts to move the focused window to a specific
-- screen identified by spatial position (auto-detected from built-in display).
-- Preserves window position offset, shrinks to fit smaller screens, and
-- remembers "natural size" to restore when moving to a screen where it fits.

local M = {}

-- Natural size memory: winID -> {w, h}
-- Stores original dimensions before cross-screen shrinking.
-- Write-once per window: set on first shrink, preserved until restored.
local naturalSize = {}

-- Natural position memory: winID -> {offsetX, offsetY}
-- Stores original screen-relative offset before cross-screen clamping.
-- Write-once per window: set on first clamp, preserved until restored.
local naturalPosition = {}

-- Optional name overrides: role -> Lua pattern matching screen name
-- e.g., {center = "DELL U2723QE"}
local nameOverrides = {}

-- =========================================================================
-- Screen discovery
-- =========================================================================

local function findBuiltIn()
  for _, screen in ipairs(hs.screen.allScreens()) do
    local name = screen:name() or ""
    if name:find("Built%-in") then
      return screen
    end
  end
  return nil
end

-- Build screen map by spatial position relative to built-in display.
-- Returns: {bottom=screen, center=screen, top=screen, left=screen, right=screen}
-- Any position may be nil if no screen exists there.
--
-- Classification: screens whose center X falls within the built-in's x range
-- are "center column" (sorted by y to get center vs top). Others are sides.
function M.buildScreenMap()
  local map = {}
  local allScreens = hs.screen.allScreens()

  -- Apply name overrides first
  for role, pattern in pairs(nameOverrides) do
    for _, screen in ipairs(allScreens) do
      local name = screen:name() or ""
      if name:find(pattern) then
        map[role] = screen
        break
      end
    end
  end

  -- Find built-in display as anchor (bottom center)
  if not map.bottom then
    map.bottom = findBuiltIn() or hs.screen.primaryScreen()
  end
  if not map.bottom then return map end

  local bf = map.bottom:frame()

  -- Classify unassigned screens by position relative to built-in
  local centerColumn = {}
  local sides = {}

  for _, screen in ipairs(allScreens) do
    -- Skip screens already assigned
    local skip = false
    for _, assigned in pairs(map) do
      if screen:id() == assigned:id() then skip = true; break end
    end
    if skip then goto continue end

    local sf = screen:frame()
    local screenCenterX = sf.x + sf.w / 2

    -- Center column: screen's center X is within built-in's x range
    if screenCenterX >= bf.x and screenCenterX <= bf.x + bf.w then
      table.insert(centerColumn, {screen = screen, y = sf.y})
    else
      table.insert(sides, {screen = screen, centerX = screenCenterX})
    end

    ::continue::
  end

  -- Center column: sort by descending y (closest to bottom first)
  table.sort(centerColumn, function(a, b) return a.y > b.y end)
  if #centerColumn >= 1 and not map.center then
    map.center = centerColumn[1].screen
  end
  if #centerColumn >= 2 and not map.top then
    map.top = centerColumn[2].screen
  elseif #centerColumn == 1 and not map.top then
    -- Only one screen above built-in: reachable as both center and top
    -- (e.g., laptop + single TV above)
    map.top = centerColumn[1].screen
  end

  -- Sides: sort by x (leftmost first)
  table.sort(sides, function(a, b) return a.centerX < b.centerX end)
  if #sides >= 1 and not map.left then
    map.left = sides[1].screen
  end
  if #sides >= 2 and not map.right then
    map.right = sides[#sides].screen
  end

  return map
end

-- =========================================================================
-- Move window to target screen
-- =========================================================================

function M.moveToScreen(position, setupWindowOperation, instant, flashFocusHighlight)
  local win = hs.window.focusedWindow()
  if not win then return end

  local map = M.buildScreenMap()
  local targetScreen = map[position]
  if not targetScreen then return end

  local currentScreen = win:screen()
  if currentScreen:id() == targetScreen:id() then return end

  setupWindowOperation(true)

  local winFrame = win:frame()
  local sourceFrame = currentScreen:frame()
  local targetFrame = targetScreen:frame()
  local winID = win:id()

  -- Step 1: Determine target dimensions
  local targetW, targetH

  if naturalSize[winID]
     and naturalSize[winID].w <= targetFrame.w
     and naturalSize[winID].h <= targetFrame.h then
    -- Natural size fits: restore it
    targetW = naturalSize[winID].w
    targetH = naturalSize[winID].h
    naturalSize[winID] = nil
  else
    targetW = winFrame.w
    targetH = winFrame.h

    local needsShrink = targetW > targetFrame.w or targetH > targetFrame.h

    if needsShrink and not naturalSize[winID] then
      naturalSize[winID] = {w = winFrame.w, h = winFrame.h}
    end

    if targetW > targetFrame.w then targetW = targetFrame.w end
    if targetH > targetFrame.h then targetH = targetFrame.h end
  end

  -- Step 2: Position mapping
  local snap = 5
  local offsetX = winFrame.x - sourceFrame.x
  local offsetY = winFrame.y - sourceFrame.y
  local targetX, targetY

  -- Try to restore natural position if it fits on target screen
  local natPos = naturalPosition[winID]
  if natPos
     and natPos.offsetX >= 0 and natPos.offsetX + targetW <= targetFrame.w
     and natPos.offsetY >= 0 and natPos.offsetY + targetH <= targetFrame.h then
    targetX = targetFrame.x + natPos.offsetX
    targetY = targetFrame.y + natPos.offsetY
    naturalPosition[winID] = nil
  else
    -- Proportional mapping with edge snapping

    -- X axis: snap right edge, or proportional
    local atRight = (winFrame.x + winFrame.w >= sourceFrame.x + sourceFrame.w - snap)
        and (offsetX > snap)  -- not also touching left
    if atRight then
      targetX = targetFrame.x + targetFrame.w - targetW
    else
      targetX = targetFrame.x + (offsetX / sourceFrame.w) * targetFrame.w
    end

    -- Y axis: snap bottom edge, or proportional
    local atBottom = (winFrame.y + winFrame.h >= sourceFrame.y + sourceFrame.h - snap)
        and (offsetY > snap)  -- not also touching top
    if atBottom then
      targetY = targetFrame.y + targetFrame.h - targetH
    else
      targetY = targetFrame.y + (offsetY / sourceFrame.h) * targetFrame.h
    end

    -- Step 3: Clamp to target screen bounds (store natural position first)
    local needsClamp = (targetX + targetW > targetFrame.x + targetFrame.w)
        or (targetX < targetFrame.x)
        or (targetY + targetH > targetFrame.y + targetFrame.h)
        or (targetY < targetFrame.y)

    if needsClamp and not naturalPosition[winID] then
      naturalPosition[winID] = {offsetX = offsetX, offsetY = offsetY}
    end

    if targetX + targetW > targetFrame.x + targetFrame.w then
      targetX = targetFrame.x + targetFrame.w - targetW
    end
    if targetX < targetFrame.x then
      targetX = targetFrame.x
    end
    if targetY + targetH > targetFrame.y + targetFrame.h then
      targetY = targetFrame.y + targetFrame.h - targetH
    end
    if targetY < targetFrame.y then
      targetY = targetFrame.y
    end
  end

  -- Step 4: Apply
  local newFrame = {x = targetX, y = targetY, w = targetW, h = targetH}
  instant(function() win:setFrame(newFrame) end)

  -- Flash focus highlight so user can see where the window landed
  if flashFocusHighlight then
    flashFocusHighlight(win, nil)
  end
end

function M.setNameOverrides(overrides)
  nameOverrides = overrides or {}
end

return M
