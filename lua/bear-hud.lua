-- =============================================================================
-- Bear HUD: note hotkeys + caret position persistence
-- =============================================================================
-- Hotkeys to open/summon Bear notes with caret + scroll position persistence.
-- Uses hs.axuielement to read/write AXSelectedTextRange and AXScrollBar value.
--
-- Hotkeys: hyperkey + letter → open/raise/summon/unsummon Bear note
-- URL handler: hammerspoon://open-bear-note?title=<title> or ?id=<id>
-- Auto-save: periodic while Bear is active + on deactivate

local M = {}

-- Module state
local rightOptionHeld = false
local raltWatcher = nil
local positions = {}       -- {key = {caret=N, scroll=F}} where key is id or title
local titleToId = {}        -- {windowTitle = noteId} learned from URL handler
local positionsFile = nil   -- set by init()
local appWatcher = nil
local saveTimer = nil
local focusModule = nil     -- set by init(), provides flashFocusHighlight + focusSingleWindow
local summonedNotes = {}    -- {title = {previousWin=<window>, originalFrame={x,y,w,h}}}
local saveInFlight = false  -- guards against overlapping timer saves
local dirty = false         -- tracks whether positions need writing to disk

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

-- Bear's AX tree is: Window → AXScrollArea → AXTextArea
local function findScrollAreaAndTextArea(axWin)
  local scrollArea = findChildWithRole(axWin, "AXScrollArea")
  if not scrollArea then return nil, nil end
  local textArea = findChildWithRole(scrollArea, "AXTextArea")
  if not textArea then return nil, nil end
  return scrollArea, textArea
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
  local ok, windows = pcall(getBearAXWindows)
  if not ok or not windows then return nil, nil end
  for _, axWin in ipairs(windows) do
    local ok2, title = pcall(function() return axWin:attributeValue("AXTitle") end)
    if ok2 and title == winTitle then
      local ok3, sa, ta = pcall(findScrollAreaAndTextArea, axWin)
      if ok3 then return sa, ta end
      return nil, nil
    end
  end
  return nil, nil
end

-- Get Bear's text area element via the system-wide focused element,
-- with fallback to tree traversal
function M.getBearTextArea()
  local ok, result = pcall(function()
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
      local _, ta = findScrollAreaAndTextArea(windows[1])
      return ta
    end
    return nil
  end)
  if not ok then
    print("[bear-hud] AX error in getBearTextArea: " .. tostring(result))
    return nil
  end
  return result
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
  if not dirty then return end
  local f = io.open(positionsFile, "w")
  if not f then
    print("[bear-hud] Failed to write positions file")
    return
  end
  f:write(hs.json.encode({positions = positions, titleToId = titleToId}, true))
  f:close()
  dirty = false
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Save caret + scroll position for a specific window title
local function savePositionForTitle(winTitle)
  if not winTitle or winTitle == "" then return end
  local ok, err = pcall(function()
    local scrollArea, textArea = getElementsForTitle(winTitle)
    if not textArea then return end
    local caret = M.getCaretPosition(textArea)
    if not caret then return end
    local scroll = getScrollValue(scrollArea)
    local key = keyForTitle(winTitle)
    local old = positions[key]
    if not old or old.caret ~= caret or old.scroll ~= scroll then
      positions[key] = {caret = caret, scroll = scroll}
      dirty = true
    end
    savePositions()
    print(string.format("[bear-hud] Saved caret=%d scroll=%s for '%s'",
      caret, scroll and string.format("%.4f", scroll) or "nil", key))
  end)
  if not ok then
    print("[bear-hud] AX error in savePositionForTitle: " .. tostring(err))
  end
end

-- Save the current caret + scroll position for the active Bear note
function M.saveCurrentPosition()
  local title = M.getCurrentNoteTitle()
  savePositionForTitle(title)
end

-- Restore the saved caret + scroll position for the current Bear note
function M.restoreCurrentPosition()
  local ok, err = pcall(function()
    local title = M.getCurrentNoteTitle()
    if not title then return end
    local key = keyForTitle(title)
    local saved = positions[key]
    if not saved then
      print(string.format("[bear-hud] No saved position for '%s'", key))
      return
    end
    local scrollArea, textArea = getElementsForTitle(title)
    if textArea then
      M.setCaretPosition(textArea, saved.caret)
      setScrollValue(scrollArea, saved.scroll)
      print(string.format("[bear-hud] Restored caret=%d scroll=%s for '%s'",
        saved.caret, saved.scroll and string.format("%.4f", saved.scroll) or "nil", key))
    end
  end)
  if not ok then
    print("[bear-hud] AX error in restoreCurrentPosition: " .. tostring(err))
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
    local ok, err = pcall(function()
      local currentTitle = M.getCurrentNoteTitle()

      -- If matchTitle is set, wait for that specific title
      -- If not (id-based open), accept any Bear window that has a text area
      if matchTitle and currentTitle ~= matchTitle then
        if attempts < maxAttempts then
          hs.timer.doAfter(0.1, tryRestore)
        else
          print(string.format("[bear-hud] Gave up waiting for '%s' after %d attempts", matchTitle, attempts))
        end
        return
      end

      local scrollArea, textArea = getElementsForTitle(currentTitle)
      if textArea then
        -- For id-based opens, learn the title→id mapping now
        if not matchTitle and currentTitle and currentTitle ~= "" then
          titleToId[currentTitle] = key
          dirty = true
        end

        local saved = positions[key]
        if saved then
          M.setCaretPosition(textArea, saved.caret)
          setScrollValue(scrollArea, saved.scroll)
          print(string.format("[bear-hud] Restored caret=%d scroll=%s for '%s' (attempt %d)",
            saved.caret, saved.scroll and string.format("%.4f", saved.scroll) or "nil",
            key, attempts))
        end
        savePositions()
        return
      end

      if attempts < maxAttempts then
        hs.timer.doAfter(0.1, tryRestore)
      else
        print(string.format("[bear-hud] Gave up restoring '%s' after %d attempts", key, attempts))
      end
    end)
    if not ok then
      print("[bear-hud] AX error in restoreForNote: " .. tostring(err))
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
    print("[bear-hud] Bear is not running")
    return
  end

  local appEl = hs.axuielement.applicationElement(bear)
  if not appEl then
    print("[bear-hud] Could not get AX application element")
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
  print(string.format("[bear-hud] Window title: %s", title or "nil"))

  local scrollArea, textArea = getElementsForTitle(title or "")
  if textArea then
    local pos = M.getCaretPosition(textArea)
    print(string.format("[bear-hud] Current caret: %s", pos and tostring(pos) or "nil"))
    local charCount = textArea:attributeValue("AXNumberOfCharacters")
    print(string.format("[bear-hud] Document length: %s", charCount and tostring(charCount) or "nil"))
    local scroll = getScrollValue(scrollArea)
    print(string.format("[bear-hud] Scroll value: %s", scroll and string.format("%.4f", scroll) or "nil"))
  else
    print("[bear-hud] No text area found")
  end

  local key = title and keyForTitle(title) or nil
  if key and positions[key] then
    local saved = positions[key]
    print(string.format("[bear-hud] Saved: caret=%s scroll=%s (key: %s)",
      tostring(saved.caret), saved.scroll and string.format("%.4f", saved.scroll) or "nil", key))
  else
    print("[bear-hud] No saved position for this note")
  end
end

-- =============================================================================
-- Note hotkey state machine
-- =============================================================================

-- Find a Bear window by title (using hs.window objects, not AX)
local function findBearWindowByTitle(title)
  local bear = hs.application.get("Bear")
  if not bear then return nil end
  for _, win in ipairs(bear:allWindows()) do
    if win:title() == title then return win end
  end
  return nil
end

-- Open a note in Bear via bear:// URL
local function openNoteInBear(title)
  local bearURL = "bear://x-callback-url/open-note?title=" .. title:gsub(" ", "%%20")
    .. "&edit=yes&new_window=yes&show_window=no"
  hs.urlevent.openURL(bearURL)
end

-- Center a window on the mouse cursor, clamped to screen bounds
local function centerOnCursor(win)
  local mouse = hs.mouse.absolutePosition()
  local frame = win:frame()
  local screen = hs.mouse.getCurrentScreen():frame()
  local newX = math.max(screen.x, math.min(mouse.x - frame.w/2, screen.x + screen.w - frame.w))
  local newY = math.max(screen.y, math.min(mouse.y - frame.h/2, screen.y + screen.h - frame.h))
  hs.window.animationDuration = 0
  win:setFrame({x = newX, y = newY, w = frame.w, h = frame.h})
  hs.window.animationDuration = 0.3
end

-- Handle a note hotkey press (implements the state machine)
local function handleNoteHotkey(noteTitle)
  print(string.format("[bear-hud] Hotkey for '%s'", noteTitle))

  local state = summonedNotes[noteTitle]
  local noteWin = findBearWindowByTitle(noteTitle)

  -- Summoned → refocus previous window, then restore original position behind it
  if state and state.originalFrame then
    print(string.format("[bear-hud] Unsummoning '%s'", noteTitle))
    if state.previousWin and state.previousWin:isVisible() then
      focusModule.focusSingleWindow(state.previousWin)
      focusModule.flashFocusHighlight(state.previousWin, nil)
    end
    local orig = state.originalFrame
    hs.window.animationDuration = 0
    noteWin:setFrame(orig)
    hs.window.animationDuration = 0.3
    summonedNotes[noteTitle] = nil
    return
  end

  -- Not open → open via bear:// URL
  if not noteWin then
    print(string.format("[bear-hud] Opening '%s'", noteTitle))
    M.saveCurrentPosition()
    openNoteInBear(noteTitle)
    -- Poll for the window to appear, then highlight it
    local attempts = 0
    local function waitForWindow()
      attempts = attempts + 1
      local win = findBearWindowByTitle(noteTitle)
      if win then
        focusModule.focusSingleWindow(win)
        focusModule.flashFocusHighlight(win, nil)
        summonedNotes[noteTitle] = {previousWin = nil}
        M.restoreForNote(noteTitle, noteTitle)
      elseif attempts < 30 then
        hs.timer.doAfter(0.1, waitForWindow)
      else
        print(string.format("[bear-hud] Gave up waiting for window '%s'", noteTitle))
      end
    end
    hs.timer.doAfter(0.2, waitForWindow)
    return
  end

  local focusedWin = hs.window.focusedWindow()

  -- Already focused → summon to cursor (for different-screen or re-summon cases)
  if focusedWin and focusedWin:id() == noteWin:id() then
    print(string.format("[bear-hud] Summoning '%s' to cursor", noteTitle))
    if not state then
      state = {previousWin = nil}
    end
    local frame = noteWin:frame()
    state.originalFrame = {x = frame.x, y = frame.y, w = frame.w, h = frame.h}
    summonedNotes[noteTitle] = state
    centerOnCursor(noteWin)
    focusModule.flashFocusHighlight(noteWin, nil)
    return
  end

  -- Open, not focused, same screen → focus + summon to cursor in one step
  local noteScreen = noteWin:screen()
  local cursorScreen = hs.mouse.getCurrentScreen()
  if noteScreen and cursorScreen and noteScreen:id() == cursorScreen:id() then
    print(string.format("[bear-hud] Summoning '%s' (same screen)", noteTitle))
    M.saveCurrentPosition()
    local frame = noteWin:frame()
    summonedNotes[noteTitle] = {
      previousWin = focusedWin,
      originalFrame = {x = frame.x, y = frame.y, w = frame.w, h = frame.h},
    }
    centerOnCursor(noteWin)
    focusModule.focusSingleWindow(noteWin)
    focusModule.flashFocusHighlight(noteWin, nil)
    return
  end

  -- Open, not focused, different screen → just raise + focus
  print(string.format("[bear-hud] Raising '%s'", noteTitle))
  M.saveCurrentPosition()
  summonedNotes[noteTitle] = {previousWin = focusedWin}
  focusModule.focusSingleWindow(noteWin)
  focusModule.flashFocusHighlight(noteWin, nil)
end

-- =============================================================================
-- URL handler + auto-save watcher + note hotkeys
-- =============================================================================

function M.init(projectRoot, focus)
  focusModule = focus
  positionsFile = projectRoot .. "data/bear-hud-positions.json"
  loadPositions()

  -- URL handler: hammerspoon://open-bear-note?title=<title> or ?id=<id>
  -- Defers work via timer so the handler returns immediately (avoids blocking)
  hs.urlevent.bind("open-bear-note", function(eventName, params)
    local title = params.title
    local id = params.id
    if not title and not id then
      print("[bear-hud] open-bear-note called without title or id")
      return
    end

    hs.timer.doAfter(0, function()
      print(string.format("[bear-hud] Opening note: %s", id or title))

      -- Save current position before switching notes
      M.saveCurrentPosition()

      -- Learn title→id mapping if both are provided
      if title and id then
        titleToId[title] = id
        dirty = true
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
  local function guardedSave()
    if saveInFlight then return end
    saveInFlight = true
    M.saveCurrentPosition()
    saveInFlight = false
  end

  appWatcher = hs.application.watcher.new(function(appName, eventType, app)
    if appName ~= "Bear" then return end
    if eventType == hs.application.watcher.activated then
      if not saveTimer then
        saveTimer = hs.timer.doEvery(1800, guardedSave)
      end
    elseif eventType == hs.application.watcher.deactivated then
      if saveTimer then saveTimer:stop(); saveTimer = nil end
      guardedSave()
    end
  end)
  appWatcher:start()

  -- If Bear is already active at init time, start the timer
  local bear = hs.application.get("Bear")
  if bear and bear:isFrontmost() then
    saveTimer = hs.timer.doEvery(1800, guardedSave)
  end

  -- Track physical right-option key via device-specific flag bit
  raltWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    rightOptionHeld = (event:rawFlags() & 0x40) ~= 0
    return false
  end)
  raltWatcher:start()

  -- Load note hotkeys from bear-notes.json
  local notesFile = projectRoot .. "data/bear-notes.json"
  local nf = io.open(notesFile, "r")
  if nf then
    local content = nf:read("*a")
    nf:close()
    local config = hs.json.decode(content)
    if config then
      local vars = config.vars or {}
      local mods = config.mods or {}
      for _, note in ipairs(config.notes or {}) do
        -- Expand template vars in title
        local title = note.title
        for varName, varValue in pairs(vars) do
          title = title:gsub("%${" .. varName .. "}", varValue)
        end
        -- Expand template vars in pastTitle (if present)
        local pastTitle = note.pastTitle
        if pastTitle then
          for varName, varValue in pairs(vars) do
            pastTitle = pastTitle:gsub("%${" .. varName .. "}", varValue)
          end
        end
        hs.hotkey.bind(mods, note.key, function()
          if rightOptionHeld and pastTitle then
            handleNoteHotkey(pastTitle)
          else
            handleNoteHotkey(title)
          end
        end)
        if pastTitle then
          print(string.format("[bear-hud] Bound %s → '%s' (past: '%s')", note.key, title, pastTitle))
        else
          print(string.format("[bear-hud] Bound %s → '%s'", note.key, title))
        end
      end
    end
  else
    print("[bear-hud] No bear-notes.json found, skipping hotkeys")
  end

  print("[bear-hud] Initialized")
end

return M
