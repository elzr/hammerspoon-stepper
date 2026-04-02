-- =============================================================================
-- Move window to specific named display
-- =============================================================================
-- Provides direct keyboard shortcuts to move the focused window to a specific
-- screen identified by spatial position (auto-detected from built-in display).
-- Uses screenmemory for per-screen position recall; falls back to proportional
-- mapping with edge snapping on first visit.

local M = {}

-- Optional module references (set during init)
local screenmemory = nil
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

  -- Determine departure screen position name (reverse lookup)
  local departurePos = nil
  for pos, scr in pairs(map) do
    if scr:id() == currentScreen:id() then
      departurePos = pos
      break
    end
  end

  -- Save departure memory BEFORE anything changes
  if screenmemory and departurePos then
    screenmemory.saveDeparture(win, departurePos)
  end

  setupWindowOperation(true)

  local winFrame = win:frame()
  local sourceFrame = currentScreen:frame()
  local targetFrame = targetScreen:frame()

  -- Check for remembered position at target screen
  local remembered = screenmemory and screenmemory.lookupArrival(win, position)
  local newFrame

  if remembered then
    -- Apply remembered relative frame to target screen
    local targetX = targetFrame.x + remembered.x * targetFrame.w
    local targetY = targetFrame.y + remembered.y * targetFrame.h
    local targetW = remembered.w * targetFrame.w
    local targetH = remembered.h * targetFrame.h

    -- Clamp to screen bounds (screen may have changed resolution)
    if targetW > targetFrame.w then targetW = targetFrame.w end
    if targetH > targetFrame.h then targetH = targetFrame.h end
    if targetX + targetW > targetFrame.x + targetFrame.w then
      targetX = targetFrame.x + targetFrame.w - targetW
    end
    if targetX < targetFrame.x then targetX = targetFrame.x end
    if targetY + targetH > targetFrame.y + targetFrame.h then
      targetY = targetFrame.y + targetFrame.h - targetH
    end
    if targetY < targetFrame.y then targetY = targetFrame.y end

    newFrame = {
      x = math.floor(targetX + 0.5),
      y = math.floor(targetY + 0.5),
      w = math.floor(targetW + 0.5),
      h = math.floor(targetH + 0.5),
    }
  else
    -- First visit: proportional mapping with edge snapping
    local targetW = winFrame.w
    local targetH = winFrame.h
    if targetW > targetFrame.w then targetW = targetFrame.w end
    if targetH > targetFrame.h then targetH = targetFrame.h end

    local snap = 5
    local offsetX = winFrame.x - sourceFrame.x
    local offsetY = winFrame.y - sourceFrame.y

    -- X axis: snap right edge, or proportional
    local targetX
    local atRight = (winFrame.x + winFrame.w >= sourceFrame.x + sourceFrame.w - snap)
        and (offsetX > snap)
    if atRight then
      targetX = targetFrame.x + targetFrame.w - targetW
    else
      targetX = targetFrame.x + (offsetX / sourceFrame.w) * targetFrame.w
    end

    -- Y axis: snap bottom edge, or proportional
    local targetY
    local atBottom = (winFrame.y + winFrame.h >= sourceFrame.y + sourceFrame.h - snap)
        and (offsetY > snap)
    if atBottom then
      targetY = targetFrame.y + targetFrame.h - targetH
    else
      targetY = targetFrame.y + (offsetY / sourceFrame.h) * targetFrame.h
    end

    -- Clamp to target screen bounds
    if targetX + targetW > targetFrame.x + targetFrame.w then
      targetX = targetFrame.x + targetFrame.w - targetW
    end
    if targetX < targetFrame.x then targetX = targetFrame.x end
    if targetY + targetH > targetFrame.y + targetFrame.h then
      targetY = targetFrame.y + targetFrame.h - targetH
    end
    if targetY < targetFrame.y then targetY = targetFrame.y end

    newFrame = {x = targetX, y = targetY, w = targetW, h = targetH}
  end

  instant(function() win:setFrame(newFrame) end)

  -- Flash focus highlight so user can see where the window landed
  if flashFocusHighlight then
    flashFocusHighlight(win, nil)
  end
end

function M.setScreenMemory(mod)
  screenmemory = mod
end

function M.setNameOverrides(overrides)
  nameOverrides = overrides or {}
end

return M
