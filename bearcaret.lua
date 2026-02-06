-- =============================================================================
-- Bear caret position persistence
-- =============================================================================
-- Tracks caret + scroll positions in Bear notes and restores them on reopen.
-- Uses hs.axuielement to read/write AXSelectedTextRange and AXScrollBar value.
--
-- URL handler: hammerspoon://open-bear-note?title=<title> or ?id=<id>
-- Auto-save: periodic while Bear is active + on deactivate

local M = {}

-- Module state
local positions = {}       -- {key = {caret=N, scroll=F}} where key is id or title
local titleToId = {}        -- {windowTitle = noteId} learned from URL handler
local positionsFile = nil   -- set by init()
local appWatcher = nil
local saveTimer = nil

-- =============================================================================
-- Accessibility helpers
-- =============================================================================

-- Find first child with a given AXRole in an element's direct children
local function findChildWithRole(element, role)
  local children = element:attributeValue("AXChildren")
  if not children then return nil end
  for _, child in ipairs(children) do
    if child:attributeValue("AXRole") == role then
      return child
    end
  end
  return nil
end

-- Find AXTextArea in an AX element subtree
local function findTextArea(element)
  local role = element:attributeValue("AXRole")
  if role == "AXTextArea" then return element end
  local children = element:attributeValue("AXChildren")
  if children then
    for _, child in ipairs(children) do
      local result = findTextArea(child)
      if result then return result end
    end
  end
  return nil
end

-- Find the AXScrollArea containing the text area, and return both
local function findScrollAreaAndTextArea(axWin)
  local function search(element)
    local role = element:attributeValue("AXRole")
    if role == "AXScrollArea" then
      local ta = findChildWithRole(element, "AXTextArea")
      if ta then return element, ta end
    end
    local children = element:attributeValue("AXChildren")
    if children then
      for _, child in ipairs(children) do
        local sa, ta = search(child)
        if sa then return sa, ta end
      end
    end
    return nil, nil
  end
  return search(axWin)
end

-- Get the vertical scrollbar value (0.0-1.0) from a scroll area
local function getScrollValue(scrollArea)
  if not scrollArea then return nil end
  local scrollBar = findChildWithRole(scrollArea, "AXScrollBar")
  if not scrollBar then return nil end
  return scrollBar:attributeValue("AXValue")
end

-- Set the vertical scrollbar value (0.0-1.0) on a scroll area
local function setScrollValue(scrollArea, value)
  if not scrollArea or not value then return end
  local scrollBar = findChildWithRole(scrollArea, "AXScrollBar")
  if not scrollBar then return end
  scrollBar:setAttributeValue("AXValue", value)
end

-- Get Bear's AX windows list
local function getBearAXWindows()
  local bear = hs.application.get("Bear")
  if not bear then return nil, nil end
  local appEl = hs.axuielement.applicationElement(bear)
  if not appEl then return nil, bear end
  local windows = appEl:attributeValue("AXWindows")
  return windows, bear
end

-- Find scroll area + text area for a specific window title via AX tree
local function getElementsForTitle(winTitle)
  local windows = getBearAXWindows()
  if not windows then return nil, nil end
  for _, axWin in ipairs(windows) do
    if axWin:attributeValue("AXTitle") == winTitle then
      return findScrollAreaAndTextArea(axWin)
    end
  end
  return nil, nil
end

-- Get Bear's text area element via the system-wide focused element,
-- with fallback to tree traversal
function M.getBearTextArea()
  local bear = hs.application.get("Bear")
  if not bear then return nil end

  -- Try focused element first (fast path)
  local syswide = hs.axuielement.systemWideElement()
  local focused = syswide:attributeValue("AXFocusedUIElement")
  if focused then
    local role = focused:attributeValue("AXRole")
    if role == "AXTextArea" then
      return focused
    end
  end

  -- Fallback: match Bear's focused window by title
  local focusedWin = bear:focusedWindow()
  local focusedTitle = focusedWin and focusedWin:title()
  if focusedTitle then
    local _, ta = getElementsForTitle(focusedTitle)
    if ta then return ta end
  end

  -- Last resort: try first AX window
  local windows = getBearAXWindows()
  if windows and #windows > 0 then
    return findTextArea(windows[1])
  end
  return nil
end

-- Read caret position from a text area
function M.getCaretPosition(textArea)
  if not textArea then return nil end
  local range = textArea:attributeValue("AXSelectedTextRange")
  if range then
    return range.loc or range.location
  end
  return nil
end

-- Write caret position to a text area (clamped to document length)
function M.setCaretPosition(textArea, pos)
  if not textArea then return false end
  local charCount = textArea:attributeValue("AXNumberOfCharacters") or 0
  if pos > charCount then pos = charCount end
  if pos < 0 then pos = 0 end
  textArea:setAttributeValue("AXSelectedTextRange", {location = pos, length = 0})
  return true
end

-- Get the title of Bear's focused window
function M.getCurrentNoteTitle()
  local bear = hs.application.get("Bear")
  if not bear then return nil end
  local win = bear:focusedWindow()
  if not win then return nil end
  return win:title()
end

-- Get the storage key for the current note (id if known, else title)
local function keyForTitle(title)
  return titleToId[title] or title
end

-- =============================================================================
-- Persistence
-- =============================================================================

local function loadPositions()
  if not positionsFile then return end
  local f = io.open(positionsFile, "r")
  if not f then
    positions = {}
    titleToId = {}
    return
  end
  local content = f:read("*a")
  f:close()
  if content and #content > 0 then
    local data = hs.json.decode(content) or {}
    positions = data.positions or {}
    titleToId = data.titleToId or {}
  else
    positions = {}
    titleToId = {}
  end
end

local function savePositions()
  if not positionsFile then return end
  local f = io.open(positionsFile, "w")
  if not f then
    print("[bearcaret] Failed to write positions file")
    return
  end
  f:write(hs.json.encode({positions = positions, titleToId = titleToId}, true))
  f:close()
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Save caret + scroll position for a specific window title
local function savePositionForTitle(winTitle)
  if not winTitle or winTitle == "" then return end
  local scrollArea, textArea = getElementsForTitle(winTitle)
  if not textArea then return end
  local caret = M.getCaretPosition(textArea)
  if not caret then return end
  local scroll = getScrollValue(scrollArea)
  local key = keyForTitle(winTitle)
  positions[key] = {caret = caret, scroll = scroll}
  savePositions()
  print(string.format("[bearcaret] Saved caret=%d scroll=%s for '%s'",
    caret, scroll and string.format("%.4f", scroll) or "nil", key))
end

-- Save the current caret + scroll position for the active Bear note
function M.saveCurrentPosition()
  local title = M.getCurrentNoteTitle()
  savePositionForTitle(title)
end

-- Restore the saved caret + scroll position for the current Bear note
function M.restoreCurrentPosition()
  local title = M.getCurrentNoteTitle()
  if not title then return end
  local key = keyForTitle(title)
  local saved = positions[key]
  if not saved then
    print(string.format("[bearcaret] No saved position for '%s'", key))
    return
  end
  local scrollArea, textArea = getElementsForTitle(title)
  if textArea then
    M.setCaretPosition(textArea, saved.caret)
    setScrollValue(scrollArea, saved.scroll)
    print(string.format("[bearcaret] Restored caret=%d scroll=%s for '%s'",
      saved.caret, saved.scroll and string.format("%.4f", saved.scroll) or "nil", key))
  end
end

-- Poll until the note loads, then restore caret + scroll position
-- key: the storage key (id or title) to look up the saved position
-- matchTitle: if provided, wait until the window title matches (for title-based opens)
function M.restoreForNote(key, matchTitle)
  local attempts = 0
  local maxAttempts = 30

  local function tryRestore()
    attempts = attempts + 1
    local currentTitle = M.getCurrentNoteTitle()

    -- If matchTitle is set, wait for that specific title
    -- If not (id-based open), accept any Bear window that has a text area
    if matchTitle and currentTitle ~= matchTitle then
      if attempts < maxAttempts then
        hs.timer.doAfter(0.1, tryRestore)
      else
        print(string.format("[bearcaret] Gave up waiting for '%s' after %d attempts", matchTitle, attempts))
      end
      return
    end

    local scrollArea, textArea = getElementsForTitle(currentTitle)
    if textArea then
      -- For id-based opens, learn the title→id mapping now
      if not matchTitle and currentTitle and currentTitle ~= "" then
        titleToId[currentTitle] = key
      end

      local saved = positions[key]
      if saved then
        M.setCaretPosition(textArea, saved.caret)
        setScrollValue(scrollArea, saved.scroll)
        print(string.format("[bearcaret] Restored caret=%d scroll=%s for '%s' (attempt %d)",
          saved.caret, saved.scroll and string.format("%.4f", saved.scroll) or "nil",
          key, attempts))
      end
      savePositions()
      return
    end

    if attempts < maxAttempts then
      hs.timer.doAfter(0.1, tryRestore)
    else
      print(string.format("[bearcaret] Gave up restoring '%s' after %d attempts", key, attempts))
    end
  end

  tryRestore()
end

-- =============================================================================
-- Discovery / debug
-- =============================================================================

-- Dump Bear's accessibility hierarchy (for Phase 1 testing)
function M.dumpTree()
  local bear = hs.application.get("Bear")
  if not bear then
    print("[bearcaret] Bear is not running")
    return
  end

  local appEl = hs.axuielement.applicationElement(bear)
  if not appEl then
    print("[bearcaret] Could not get AX application element")
    return
  end

  local function dump(el, indent)
    indent = indent or ""
    local role = el:attributeValue("AXRole") or "?"
    local title = el:attributeValue("AXTitle") or ""
    local desc = el:attributeValue("AXDescription") or ""
    local label = title ~= "" and title or desc
    print(string.format("%s%s%s", indent, role, label ~= "" and (" (" .. label .. ")") or ""))

    -- Show text range info for text areas, then stop recursing
    if role == "AXTextArea" then
      local range = el:attributeValue("AXSelectedTextRange")
      local charCount = el:attributeValue("AXNumberOfCharacters")
      if range then
        print(string.format("%s  AXSelectedTextRange: %s", indent, hs.inspect(range)))
      else
        print(string.format("%s  AXSelectedTextRange: nil", indent))
      end
      print(string.format("%s  AXNumberOfCharacters: %s", indent,
        charCount and tostring(charCount) or "nil"))
      return
    end

    -- Show scrollbar value
    if role == "AXScrollBar" then
      local val = el:attributeValue("AXValue")
      print(string.format("%s  AXValue: %s", indent, val and tostring(val) or "nil"))
      return
    end

    if role == "AXMenuBar" then return end

    local children = el:attributeValue("AXChildren")
    if children then
      for _, child in ipairs(children) do
        dump(child, indent .. "  ")
      end
    end
  end

  dump(appEl)
end

-- Print current status
function M.status()
  local title = M.getCurrentNoteTitle()
  print(string.format("[bearcaret] Window title: %s", title or "nil"))

  local scrollArea, textArea = getElementsForTitle(title or "")
  if textArea then
    local pos = M.getCaretPosition(textArea)
    print(string.format("[bearcaret] Current caret: %s", pos and tostring(pos) or "nil"))
    local charCount = textArea:attributeValue("AXNumberOfCharacters")
    print(string.format("[bearcaret] Document length: %s", charCount and tostring(charCount) or "nil"))
    local scroll = getScrollValue(scrollArea)
    print(string.format("[bearcaret] Scroll value: %s", scroll and string.format("%.4f", scroll) or "nil"))
  else
    print("[bearcaret] No text area found")
  end

  local key = title and keyForTitle(title) or nil
  if key and positions[key] then
    local saved = positions[key]
    print(string.format("[bearcaret] Saved: caret=%s scroll=%s (key: %s)",
      tostring(saved.caret), saved.scroll and string.format("%.4f", saved.scroll) or "nil", key))
  else
    print("[bearcaret] No saved position for this note")
  end
end

-- =============================================================================
-- URL handler + auto-save watcher
-- =============================================================================

function M.init(scriptPath)
  positionsFile = scriptPath .. "bearcaret-positions.json"
  loadPositions()

  -- URL handler: hammerspoon://open-bear-note?title=<title> or ?id=<id>
  -- Defers work via timer so the handler returns immediately (avoids blocking)
  hs.urlevent.bind("open-bear-note", function(eventName, params)
    local title = params.title
    local id = params.id
    if not title and not id then
      print("[bearcaret] open-bear-note called without title or id")
      return
    end

    hs.timer.doAfter(0, function()
      print(string.format("[bearcaret] Opening note: %s", id or title))

      -- Save current position before switching notes
      M.saveCurrentPosition()

      -- Learn title→id mapping if both are provided
      if title and id then
        titleToId[title] = id
      end

      -- Open the note in Bear
      local bearURL
      if id then
        bearURL = "bear://x-callback-url/open-note?id=" .. id
          .. "&edit=yes&new_window=yes&show_window=no"
      else
        bearURL = "bear://x-callback-url/open-note?title=" .. title:gsub(" ", "%%20")
          .. "&edit=yes&new_window=yes&show_window=no"
      end
      hs.urlevent.openURL(bearURL)

      -- Poll and restore caret + scroll position
      local key = id or title
      local matchTitle = title  -- nil when opening by id (we don't know the title yet)
      M.restoreForNote(key, matchTitle)
    end)
  end)

  -- Auto-save: periodic timer while Bear is active, plus save on deactivate
  appWatcher = hs.application.watcher.new(function(appName, eventType, app)
    if appName ~= "Bear" then return end
    if eventType == hs.application.watcher.activated then
      if not saveTimer then
        saveTimer = hs.timer.doEvery(3, function()
          M.saveCurrentPosition()
        end)
      end
    elseif eventType == hs.application.watcher.deactivated then
      if saveTimer then saveTimer:stop(); saveTimer = nil end
      M.saveCurrentPosition()
    end
  end)
  appWatcher:start()

  -- If Bear is already active at init time, start the timer
  local bear = hs.application.get("Bear")
  if bear and bear:isFrontmost() then
    saveTimer = hs.timer.doEvery(3, function()
      M.saveCurrentPosition()
    end)
  end

  print("[bearcaret] Initialized")
end

return M
