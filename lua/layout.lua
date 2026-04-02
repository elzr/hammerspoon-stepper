-- =============================================================================
-- Window layout save / restore / gather
-- =============================================================================
-- layout.save()          — snapshot all visible window positions (+ rotate 1m backup ring)
-- layout.restore()       — restore from latest autosave
-- layout.manualSave()    — pinned save (never overwritten by autosave)
-- layout.manualRestore() — restore from pinned save (fallback to autosave)
-- layout.gather()        — consolidate all windows into one space on the built-in display
--
-- Designed for a 5-display setup with 4 identical LG HDR 4K monitors (no serials).
-- Screens are identified by spatial position name (via screenswitch.buildScreenMap),
-- with origin/resolution fallback for backwards compatibility.

local M = {}

local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local dataFile = scriptPath .. "../data/window-layout.json"
local manualFile = scriptPath .. "../data/window-layout-manual.json"
local backupDir = scriptPath .. "../data/layout-backups/"
local lunarSyncScript = scriptPath .. "../features/sync-display-names-in-Lunar/lunar-sync-names.py"

local TARGET_DISPLAY_COUNT = 5
local DEBOUNCE_DELAY = 2          -- seconds (screens appear sequentially)
local PERIODIC_SAVE_INTERVAL = 60   -- 1 minute
local PERIODIC_10M_INTERVAL = 600   -- 10 minutes
local LUNAR_SYNC_DELAY = 3         -- seconds after screen stabilization

local RING_1M_SIZE = 10             -- keep 10 one-minute backups
local RING_10M_SIZE = 10            -- keep 10 ten-minute backups

local screenWatcher = nil
local debounceTimer = nil
local periodicTimer = nil
local periodic10mTimer = nil
local lunarSyncTimer = nil
local lastScreenCount = 0

local SAVE_TRIGGER_DELAY = 3        -- seconds after last triggered operation
local LOG_RETENTION = 600            -- 10 minutes of log entries

-- Ring buffer indices (1-based, wrap around)
local ring1mIndex = 0
local ring10mIndex = 0

-- Module references (set during init)
local screenswitch = nil
local screenmemory = nil
local triggerTimer = nil

-- Retry state — polls for windows that weren't visible at restore time
local RETRY_INTERVAL = 3          -- seconds between polls
local RETRY_MAX_ATTEMPTS = 10     -- 30 seconds total
local retryTimer = nil
local retryActive = false

-- Zero-window detection — tracks consecutive autosave cycles with 0 visible windows
-- Used to detect screen lock/display sleep (where screensDidWake doesn't fire)
local zeroWindowStreak = 0

-- Position protection — prevents autosave from recording macOS-placed positions
local protectedEntries = {}       -- "App\nTitle" → saved entry (ground truth)
local protectionExpiry = 0        -- timestamp when protection expires
local PROTECTION_DURATION = 300   -- 5 minutes after reconnection

-- ---------------------------------------------------------------------------
-- Ring buffer log — keeps last 10 minutes of layout events for debugging
-- ---------------------------------------------------------------------------
local logBuffer = {}  -- {timestamp, event, detail}

local function logEvent(event, detail)
  local now = hs.timer.secondsSinceEpoch()
  table.insert(logBuffer, {timestamp = now, event = event, detail = detail})
  -- Prune entries older than LOG_RETENTION
  local cutoff = now - LOG_RETENTION
  while #logBuffer > 0 and logBuffer[1].timestamp < cutoff do
    table.remove(logBuffer, 1)
  end
  print(string.format("[layout.log] %s: %s", event, detail or ""))
end

function M.dumpLog()
  if #logBuffer == 0 then
    print("[layout.log] (empty)")
    return
  end
  local now = hs.timer.secondsSinceEpoch()
  for _, entry in ipairs(logBuffer) do
    local ago = now - entry.timestamp
    print(string.format("[layout.log] -%ds  %s: %s",
      math.floor(ago), entry.event, entry.detail or ""))
  end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function roundFrame(f)
  return {
    x = math.floor(f.x + 0.5),
    y = math.floor(f.y + 0.5),
    w = math.floor(f.w + 0.5),
    h = math.floor(f.h + 0.5),
  }
end

-- Minimum dimensions for a real window — anything smaller is a tooltip/popover/toolbar
local MIN_WINDOW_WIDTH = 100
local MIN_WINDOW_HEIGHT = 100

local function isGhostWindow(win)
  if not win:isStandard() then return true end
  local f = win:frame()
  if f.w < MIN_WINDOW_WIDTH or f.h < MIN_WINDOW_HEIGHT then return true end
  local title = win:title()
  if title and title:find("\n") then return true end
  return false
end

-- Reverse lookup: screen ID -> position name using screenswitch.buildScreenMap()
local function buildScreenIdToPosition()
  if not screenswitch then return {} end
  local map = screenswitch.buildScreenMap()
  local idToPos = {}
  for position, screen in pairs(map) do
    idToPos[screen:id()] = position
  end
  return idToPos
end

-- Find the live screen matching a saved entry.
-- Pass 1: position name match (stable across reconnections)
-- Pass 2: origin match (for backwards compat with old save files)
-- Pass 3: resolution match
-- Pass 4: mainScreen fallback
local function findScreen(entry)
  local savedSF = entry.screenFrame
  local savedPos = entry.screenPosition
  local tol = 2
  local allScreens = hs.screen.allScreens()

  -- Pass 1: position name match via screenswitch
  if savedPos and screenswitch then
    local map = screenswitch.buildScreenMap()
    if map[savedPos] then
      return map[savedPos], "position"
    end
  end

  -- Pass 2: exact origin match
  for _, s in ipairs(allScreens) do
    local sf = s:frame()
    if math.abs(sf.x - savedSF.x) <= tol and math.abs(sf.y - savedSF.y) <= tol then
      return s, "exact"
    end
  end

  -- Pass 3: resolution match
  for _, s in ipairs(allScreens) do
    local sf = s:frame()
    if math.abs(sf.w - savedSF.w) <= tol and math.abs(sf.h - savedSF.h) <= tol then
      return s, "resolution"
    end
  end

  return hs.screen.mainScreen(), "fallback"
end

-- Compute the target frame for a saved entry on the current screen layout
local function computeTargetFrame(entry)
  local screen, matchType = findScreen(entry)
  local sf = screen:frame()
  if matchType == "exact" or matchType == "position" then
    local sf_saved = entry.screenFrame
    if math.abs(sf.x - sf_saved.x) > 2 or math.abs(sf.y - sf_saved.y) > 2 then
      local rel = entry.frameRel
      return {
        x = math.floor(sf.x + rel.x * sf.w + 0.5),
        y = math.floor(sf.y + rel.y * sf.h + 0.5),
        w = math.floor(rel.w * sf.w + 0.5),
        h = math.floor(rel.h * sf.h + 0.5),
      }, screen, matchType .. "+rel"
    end
    return entry.frame, screen, matchType
  end
  local rel = entry.frameRel
  return {
    x = math.floor(sf.x + rel.x * sf.w + 0.5),
    y = math.floor(sf.y + rel.y * sf.h + 0.5),
    w = math.floor(rel.w * sf.w + 0.5),
    h = math.floor(rel.h * sf.h + 0.5),
  }, screen, matchType
end

-- Key for protectedEntries lookup
local function protectionKey(appName, title)
  return appName .. "\n" .. title
end

-- Cancel any active retry
local function cancelRetry(reason)
  if retryTimer then
    retryTimer:stop()
    retryTimer = nil
  end
  if retryActive then
    retryActive = false
    logEvent("retry-cancelled", reason or "unknown")
  end
end

-- Clear all position protection
local function clearProtection(reason)
  if next(protectedEntries) then
    protectedEntries = {}
    protectionExpiry = 0
    logEvent("protection-cleared", reason or "unknown")
  end
end

local function showRestoreHint()
  print("[layout] Restore available — fn+ctrl+alt+shift+delete to restore layout")
end

-- ---------------------------------------------------------------------------
-- Backup ring rotation
-- ---------------------------------------------------------------------------

local function ensureBackupDir()
  os.execute("mkdir -p '" .. backupDir .. "'")
end

local function copyFile(src, dst)
  local fh = io.open(src, "r")
  if not fh then return false end
  local data = fh:read("*a")
  fh:close()
  local out = io.open(dst, "w")
  if not out then return false end
  out:write(data)
  out:close()
  return true
end

local function rotateRing1m()
  ensureBackupDir()
  ring1mIndex = (ring1mIndex % RING_1M_SIZE) + 1
  local dst = backupDir .. string.format("layout-1m-%02d.json", ring1mIndex)
  if copyFile(dataFile, dst) then
    logEvent("backup-1m", string.format("slot %d/%d", ring1mIndex, RING_1M_SIZE))
  end
end

local function rotateRing10m()
  ensureBackupDir()
  ring10mIndex = (ring10mIndex % RING_10M_SIZE) + 1
  local dst = backupDir .. string.format("layout-10m-%02d.json", ring10mIndex)
  if copyFile(dataFile, dst) then
    logEvent("backup-10m", string.format("slot %d/%d", ring10mIndex, RING_10M_SIZE))
  end
end

-- ---------------------------------------------------------------------------
-- macOS placement detection — populate protection after display reconnection
-- ---------------------------------------------------------------------------

local function detectMacOSPlacements(savedEntries)
  protectedEntries = {}
  protectionExpiry = hs.timer.secondsSinceEpoch() + PROTECTION_DURATION

  -- Build live window lookup: app+title → screen position
  local idToPos = buildScreenIdToPosition()
  local livePositions = {}  -- "App\nTitle" → current screenPosition
  for _, win in ipairs(hs.window.orderedWindows()) do
    local app = win:application()
    if app then
      local screen = win:screen()
      local pos = idToPos[screen:id()]
      livePositions[protectionKey(app:name(), win:title())] = pos
    end
  end

  local misplacedCount = 0
  local missingCount = 0
  for _, entry in ipairs(savedEntries) do
    local key = protectionKey(entry.app, entry.title)
    protectedEntries[key] = entry

    local livePos = livePositions[key]
    if livePos and entry.screenPosition and livePos ~= entry.screenPosition then
      misplacedCount = misplacedCount + 1
      logEvent("detect-macOS", string.format(
        "%s '%s' on %s (saved: %s)", entry.app, entry.title, livePos, entry.screenPosition))
    elseif not livePos then
      missingCount = missingCount + 1
    end
  end

  logEvent("protection-start", string.format(
    "%d entries protected, %d macOS-misplaced, %d not yet visible, expires in %ds",
    #savedEntries, misplacedCount, missingCount, PROTECTION_DURATION))
end

-- ---------------------------------------------------------------------------
-- Lunar display name sync
-- ---------------------------------------------------------------------------
-- Position names displayed in Lunar's UI (matches user's existing naming)
local positionNames = {
  bottom = "↓Bottom Center",
  center = "⊙Middle Center",
  top    = "↑Top Center",
  left   = "←Left",
  right  = "Right→",
}

local function syncLunarNames()
  if not screenswitch then
    print("[layout.lunar] screenswitch not available, skipping sync")
    return
  end

  local map = screenswitch.buildScreenMap()
  local uuidToName = {}

  for position, screen in pairs(map) do
    local uuid = screen:getUUID()
    local name = positionNames[position]
    if uuid and name then
      uuidToName[uuid] = name
    end
  end

  if not next(uuidToName) then
    print("[layout.lunar] No screens mapped, skipping sync")
    return
  end

  local jsonArg = hs.json.encode(uuidToName)
  -- Escape single quotes in JSON for shell
  jsonArg = jsonArg:gsub("'", "'\\''")

  -- Quit Lunar, update plist, relaunch (only if names changed)
  local cmd = string.format(
    "python3 '%s' '%s'\n" ..
    "rc=$?\n" ..
    "if [ $rc -eq 0 ]; then\n" ..
    "  osascript -e 'tell application \"Lunar\" to quit' 2>/dev/null\n" ..
    "  sleep 2\n" ..
    "  open -a Lunar\n" ..
    "  echo 'RESTARTED'\n" ..
    "fi\n" ..
    "exit $rc",
    lunarSyncScript, jsonArg
  )

  hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    if stdout and #stdout > 0 then
      for line in stdout:gmatch("[^\n]+") do
        print("[layout.lunar] " .. line)
      end
    end
    if exitCode == 0 then
      print("[layout.lunar] Lunar display names synced and relaunched")
    elseif exitCode == 1 then
      print("[layout.lunar] Names already correct")
    else
      print("[layout.lunar] Error: " .. tostring(stderr))
    end
  end, {"-c", cmd}):start()
end

function M.syncLunarNames()
  syncLunarNames()
end

-- ---------------------------------------------------------------------------
-- M.save()
-- ---------------------------------------------------------------------------

function M.save()
  local windows = hs.window.orderedWindows()
  local entries = {}
  local idToPos = buildScreenIdToPosition()

  for _, win in ipairs(windows) do
    local app = win:application()
    if not app then goto continue end

    if isGhostWindow(win) then
      logEvent("save-skip-ghost", string.format(
        "%s '%s' %dx%d", app:name(), win:title(), win:frame().w, win:frame().h))
      goto continue
    end

    local screen = win:screen()
    local sf = screen:frame()
    local f  = win:frame()
    local rf = roundFrame(f)
    local rsf = roundFrame(sf)

    table.insert(entries, {
      app            = app:name(),
      title          = win:title(),
      screenPosition = idToPos[screen:id()],
      screenFrame    = rsf,
      frame          = rf,
      frameRel       = {
        x = (f.x - sf.x) / sf.w,
        y = (f.y - sf.y) / sf.h,
        w = f.w / sf.w,
        h = f.h / sf.h,
      },
    })

    ::continue::
  end

  if #entries == 0 then
    print("[layout.save] Skipping save — 0 windows found (display may still be waking)")
    return
  end

  -- Position protection: substitute saved positions for unverified windows
  local protectedCount = 0
  local now = hs.timer.secondsSinceEpoch()
  if now < protectionExpiry and next(protectedEntries) then
    for i, e in ipairs(entries) do
      local key = protectionKey(e.app, e.title)
      local saved = protectedEntries[key]
      if saved and saved.screenPosition and e.screenPosition ~= saved.screenPosition then
        logEvent("save-protected", string.format(
          "%s '%s' kept at %s (currently on %s)",
          e.app, e.title, saved.screenPosition, e.screenPosition or "?"))
        entries[i] = saved
        protectedCount = protectedCount + 1
      end
    end
  end

  -- Build log summary: Bear windows and their screens
  local summary = {}
  for _, e in ipairs(entries) do
    if e.app == "Bear" then
      table.insert(summary, string.format("%s@%s", e.title, e.screenPosition or "?"))
    end
  end

  local json = hs.json.encode(entries, true)
  local fh, err = io.open(dataFile, "w")
  if not fh then
    print("[layout.save] ERROR: could not write " .. dataFile .. ": " .. tostring(err))
    return
  end
  fh:write(json)
  fh:close()

  logEvent("save", string.format("%d windows; Bear: %s", #entries, table.concat(summary, ", ")))
  print(string.format("[layout.save] Saved %d windows to %s", #entries, dataFile))

  -- Rotate into 1-minute backup ring
  rotateRing1m()

  -- Update per-screen position memory from saved entries
  if screenmemory then
    screenmemory.updateFromLayout(entries)
  end
end

-- ---------------------------------------------------------------------------
-- M.restore()
-- ---------------------------------------------------------------------------

function M.restore()
  local fh = io.open(dataFile, "r")
  if not fh then
    print("[layout.restore] No saved layout found at " .. dataFile)
    return {}
  end
  local json = fh:read("*a")
  fh:close()
  return M.restoreFromJSON(json, dataFile) or {}
end

-- ---------------------------------------------------------------------------
-- M.manualSave() — pinned save, never overwritten by autosave
-- ---------------------------------------------------------------------------

function M.manualSave()
  clearProtection("manual save")
  M.save()  -- writes to main dataFile + 1m ring as usual
  if copyFile(dataFile, manualFile) then
    logEvent("manual-save", manualFile)
    print("[layout] Manual layout saved (pinned)")
    hs.alert.show("Layout saved")
  else
    print("[layout] ERROR: could not write manual save")
  end
end

-- ---------------------------------------------------------------------------
-- M.manualRestore() — restore from pinned save, fallback to latest autosave
-- ---------------------------------------------------------------------------

function M.manualRestore()
  cancelRetry("manual restore")
  clearProtection("manual restore")
  -- Try manual save first
  local fh = io.open(manualFile, "r")
  local source = manualFile
  if not fh then
    -- Fallback to latest autosave
    fh = io.open(dataFile, "r")
    source = dataFile
    if not fh then
      print("[layout.restore] No saved layout found (checked manual + auto)")
      hs.alert.show("No saved layout found")
      return
    end
  end
  local json = fh:read("*a")
  fh:close()

  logEvent("manual-restore", "from " .. source)
  M.restoreFromJSON(json, source)
end

-- ---------------------------------------------------------------------------
-- M.restoreFromJSON(json, label) — shared restore logic
-- ---------------------------------------------------------------------------

function M.restoreFromJSON(json, label)
  local ok, entries = pcall(hs.json.decode, json)
  if not ok or type(entries) ~= "table" then
    print("[layout.restore] ERROR: could not parse layout JSON from " .. (label or "?"))
    return {}
  end

  -- Build per-app window list
  local appWindows = {}
  for _, win in ipairs(hs.window.orderedWindows()) do
    local app = win:application()
    if app then
      local name = app:name()
      if not appWindows[name] then appWindows[name] = {} end
      table.insert(appWindows[name], win)
    end
  end

  local matched = {}
  local pairs_list = {}
  local misses = {}
  local entryMatched = {}  -- idx → true when an entry has been paired

  -- Multi-pass matching: exact-title first, then prefix, then index-fallback.
  -- This prevents a stale entry's index-fallback from stealing a window that
  -- a later entry would match by exact title. (See F027 case study:
  -- case-layout-greedy-matching-steals-windows.md)

  -- Pass 1: exact title match only
  for idx, entry in ipairs(entries) do
    local candidates = appWindows[entry.app] or {}
    for _, win in ipairs(candidates) do
      if not matched[win:id()] and win:title() == entry.title then
        matched[win:id()] = true
        entryMatched[idx] = true
        table.insert(pairs_list, { win = win, entry = entry, idx = idx, matchTier = "exact-title" })
        break
      end
    end
  end

  -- Pass 2: 40-char prefix match for unmatched entries
  for idx, entry in ipairs(entries) do
    if not entryMatched[idx] then
      local candidates = appWindows[entry.app] or {}
      local savedPrefix = entry.title:sub(1, 40)
      for _, win in ipairs(candidates) do
        if not matched[win:id()] and win:title():sub(1, 40) == savedPrefix then
          matched[win:id()] = true
          entryMatched[idx] = true
          table.insert(pairs_list, { win = win, entry = entry, idx = idx, matchTier = "prefix-40" })
          break
        end
      end
    end
  end

  -- Pass 3: index fallback for remaining unmatched entries
  for idx, entry in ipairs(entries) do
    if not entryMatched[idx] then
      local candidates = appWindows[entry.app] or {}
      local sf = entry.frame
      if sf.w >= MIN_WINDOW_WIDTH and sf.h >= MIN_WINDOW_HEIGHT then
        for _, win in ipairs(candidates) do
          if not matched[win:id()] then
            matched[win:id()] = true
            entryMatched[idx] = true
            table.insert(pairs_list, { win = win, entry = entry, idx = idx, matchTier = "index-fallback" })
            break
          end
        end
      else
        logEvent("restore-skip-tier3", string.format(
          "%s '%s' saved frame %dx%d too small for fallback",
          entry.app, entry.title, sf.w, sf.h))
      end

      if not entryMatched[idx] then
        table.insert(misses, entry)
        logEvent("restore-miss", string.format("%s '%s' → no live window", entry.app, entry.title))
      end
    end
  end

  -- Phase 1: restore frames (skip windows already in position)
  local movedCount = 0
  local unchangedCount = 0
  local skippedCount = #entries - #pairs_list
  local origDuration = hs.window.animationDuration
  hs.window.animationDuration = 0
  local restoreDetails = {}
  local movedPairs = {}  -- only windows that actually moved (for z-order replay)
  local FRAME_TOL = 3    -- pixels — accounts for Retina subpixel rounding

  for _, p in ipairs(pairs_list) do
    local win, entry = p.win, p.entry
    local targetFrame, screen, matchType = computeTargetFrame(entry)

    if entry.app == "Bear" then
      table.insert(restoreDetails, string.format(
        "%s: saved@%s → screen:%s (win-match:%s, scr-match:%s) %dx%d",
        entry.title, entry.screenPosition or "?",
        screen:name(), p.matchTier, matchType,
        targetFrame.w, targetFrame.h))
    end

    -- Check if window is already where it should be
    local cf = win:frame()
    local alreadyCorrect =
      math.abs(cf.x - targetFrame.x) <= FRAME_TOL and
      math.abs(cf.y - targetFrame.y) <= FRAME_TOL and
      math.abs(cf.w - targetFrame.w) <= FRAME_TOL and
      math.abs(cf.h - targetFrame.h) <= FRAME_TOL

    if alreadyCorrect then
      unchangedCount = unchangedCount + 1
    else
      win:setFrame(targetFrame)
      movedCount = movedCount + 1
      table.insert(movedPairs, p)
    end

    -- Seed per-screen memory from restored position
    if screenmemory and entry.screenPosition then
      screenmemory.seedFromRestore(win, entry.screenPosition, entry.frameRel)
    end

    -- Mark as verified in position protection (only for reliable matches).
    -- Index-fallback matches may have grabbed the wrong window — keep
    -- protection active so autosave can substitute the correct position.
    if p.matchTier ~= "index-fallback" then
      local key = protectionKey(entry.app, entry.title)
      protectedEntries[key] = nil
    end
  end

  hs.window.animationDuration = origDuration

  -- Phase 2: restore z-order only for windows that actually moved
  for i = #movedPairs, 1, -1 do
    movedPairs[i].win:focus()
  end

  logEvent("restore", string.format(
    "%d moved, %d already correct, %d unmatched (from %s)",
    movedCount, unchangedCount, skippedCount, label or "?"))
  for _, detail in ipairs(restoreDetails) do
    logEvent("restore-bear", detail)
  end
  print(string.format("[layout.restore] %d moved, %d already correct, %d unmatched (from %s)",
    movedCount, unchangedCount, skippedCount, label or "?"))

  return misses
end

-- ---------------------------------------------------------------------------
-- retryMisses — poll for windows that weren't visible at restore time
-- ---------------------------------------------------------------------------

local function retryMisses(misses, label, attempt)
  attempt = attempt or 1

  if #misses == 0 then
    retryActive = false
    retryTimer = nil
    logEvent("retry-done", string.format(
      "all missed windows found after %d attempts", attempt - 1))
    -- Heal: save the now-correct layout
    hs.timer.doAfter(1, function() M.save() end)
    return
  end

  if attempt > RETRY_MAX_ATTEMPTS then
    for _, entry in ipairs(misses) do
      logEvent("retry-gave-up", string.format("%s '%s'", entry.app, entry.title))
    end
    retryActive = false
    retryTimer = nil
    logEvent("retry-done", string.format(
      "%d still missing after %d attempts (protection still active)",
      #misses, RETRY_MAX_ATTEMPTS))
    return
  end

  retryTimer = hs.timer.doAfter(RETRY_INTERVAL, function()
    -- Build fresh window list
    local appWindows = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
      local app = win:application()
      if app then
        local name = app:name()
        if not appWindows[name] then appWindows[name] = {} end
        table.insert(appWindows[name], win)
      end
    end

    local stillMissing = {}
    local found = 0
    local origDuration = hs.window.animationDuration
    hs.window.animationDuration = 0

    for _, entry in ipairs(misses) do
      local candidates = appWindows[entry.app] or {}
      local win = nil

      -- Tier 1: exact title match
      for _, w in ipairs(candidates) do
        if w:title() == entry.title then win = w; break end
      end

      -- Tier 2: 40-char prefix (no index fallback — too risky during retry)
      if not win then
        local prefix = entry.title:sub(1, 40)
        for _, w in ipairs(candidates) do
          if w:title():sub(1, 40) == prefix then win = w; break end
        end
      end

      if win then
        local targetFrame = computeTargetFrame(entry)
        win:setFrame(targetFrame)
        found = found + 1
        -- Seed per-screen memory from retry-restored position
        if screenmemory and entry.screenPosition then
          screenmemory.seedFromRestore(win, entry.screenPosition, entry.frameRel)
        end
        -- Remove from protection (verified)
        protectedEntries[protectionKey(entry.app, entry.title)] = nil
        logEvent("retry-restored", string.format(
          "%s '%s' → %s (attempt %d)", entry.app, entry.title,
          entry.screenPosition or "?", attempt))
      else
        table.insert(stillMissing, entry)
      end
    end

    hs.window.animationDuration = origDuration

    logEvent("retry-poll", string.format(
      "attempt %d/%d: found %d, still missing %d",
      attempt, RETRY_MAX_ATTEMPTS, found, #stillMissing))

    retryMisses(stillMissing, label, attempt + 1)
  end)
end

-- ---------------------------------------------------------------------------
-- M.gather()
-- ---------------------------------------------------------------------------

function M.gather()
  local mainScreen = hs.screen.mainScreen()
  local mainFrame  = mainScreen:frame()
  local closedSpaces = 0
  local movedWindows = 0

  -- Phase 1: close extra Mission Control spaces on built-in display
  local ok, spaces = pcall(function() return hs.spaces.allSpaces() end)
  if ok and spaces then
    local uuid = mainScreen:getUUID()
    local screenSpaces = spaces[uuid]
    if screenSpaces and #screenSpaces > 1 then
      -- Keep the first space; remove the rest (macOS migrates windows automatically)
      local activeSpace = hs.spaces.activeSpaceOnScreen(mainScreen)
      local keepID = activeSpace or screenSpaces[1]

      for _, sid in ipairs(screenSpaces) do
        if sid ~= keepID then
          local removeOk, err = pcall(hs.spaces.removeSpace, sid)
          if removeOk then
            closedSpaces = closedSpaces + 1
          else
            print(string.format("[layout.gather] Could not remove space %s: %s", tostring(sid), tostring(err)))
          end
        end
      end
    end
  else
    print("[layout.gather] hs.spaces not available (requires Accessibility permission)")
  end

  -- Phase 2: move windows on external displays to built-in (if externals are present)
  local allScreens = hs.screen.allScreens()
  if #allScreens > 1 then
    local origDuration = hs.window.animationDuration
    hs.window.animationDuration = 0

    for _, win in ipairs(hs.window.orderedWindows()) do
      local winScreen = win:screen()
      if winScreen and winScreen:id() ~= mainScreen:id() then
        local sf  = winScreen:frame()
        local f   = win:frame()

        -- Compute screen-relative position, scale onto built-in
        local relX = (f.x - sf.x) / sf.w
        local relY = (f.y - sf.y) / sf.h
        local relW = f.w / sf.w
        local relH = f.h / sf.h

        local newFrame = {
          x = math.floor(mainFrame.x + relX * mainFrame.w + 0.5),
          y = math.floor(mainFrame.y + relY * mainFrame.h + 0.5),
          w = math.floor(relW * mainFrame.w + 0.5),
          h = math.floor(relH * mainFrame.h + 0.5),
        }

        -- Clamp to built-in bounds
        newFrame.x = math.max(mainFrame.x, math.min(newFrame.x, mainFrame.x + mainFrame.w - newFrame.w))
        newFrame.y = math.max(mainFrame.y, math.min(newFrame.y, mainFrame.y + mainFrame.h - newFrame.h))

        win:setFrame(newFrame)
        movedWindows = movedWindows + 1
      end
    end

    hs.window.animationDuration = origDuration
  end

  print(string.format("[layout.gather] Closed %d spaces, moved %d windows to built-in", closedSpaces, movedWindows))
end

-- ---------------------------------------------------------------------------
-- M.autoSave() — guarded: only saves when at TARGET_DISPLAY_COUNT
-- ---------------------------------------------------------------------------

function M.autoSave()
  local count = #hs.screen.allScreens()
  if count ~= TARGET_DISPLAY_COUNT then
    return
  end
  if retryActive then
    logEvent("autosave-suppressed", "retry in progress")
    return
  end

  -- Pre-check: are windows visible? (screen lock / display sleep → 0 windows)
  local windows = hs.window.orderedWindows()
  if #windows == 0 then
    zeroWindowStreak = zeroWindowStreak + 1
    print("[layout.save] Skipping save — 0 windows found (display may still be waking)")
    return
  end

  -- Windows reappeared after zero-window streak (screen lock/wake, display sleep)
  -- Treat as wake: check for drift and auto-restore instead of saving shuffled positions
  if zeroWindowStreak > 0 then
    logEvent("windows-reappeared", string.format(
      "%d windows visible after %d zero-window cycles (~%ds)",
      #windows, zeroWindowStreak, zeroWindowStreak * PERIODIC_SAVE_INTERVAL))
    zeroWindowStreak = 0
    M.onWake()
    return
  end

  M.save()
end

-- ---------------------------------------------------------------------------
-- M.triggerSave(reason) — debounced save after a window operation
-- ---------------------------------------------------------------------------
-- Called by stepper/bear-hud after cross-display moves, summons, etc.
-- Collapses rapid consecutive triggers into a single save.

function M.triggerSave(reason)
  if triggerTimer then triggerTimer:stop() end
  if retryActive then
    logEvent("trigger-suppressed", reason or "unknown")
    return
  end
  -- Stepper-initiated move: clear protection for the moved window
  -- (reason format is "move-to-display:position 'title'" from stepper.lua)
  logEvent("trigger", reason or "unknown")
  triggerTimer = hs.timer.doAfter(SAVE_TRIGGER_DELAY, function()
    triggerTimer = nil
    M.autoSave()
  end)
end

-- ---------------------------------------------------------------------------
-- Screen watcher — detect display changes, prompt for restore
-- ---------------------------------------------------------------------------

local function startPeriodicSave()
  if periodicTimer then periodicTimer:stop() end
  periodicTimer = hs.timer.doEvery(PERIODIC_SAVE_INTERVAL, function()
    M.autoSave()
  end)
  if periodic10mTimer then periodic10mTimer:stop() end
  periodic10mTimer = hs.timer.doEvery(PERIODIC_10M_INTERVAL, function()
    if #hs.screen.allScreens() == TARGET_DISPLAY_COUNT then
      rotateRing10m()
    end
  end)
  print("[layout] Periodic auto-save started (1m + 10m rings)")
end

local function stopPeriodicSave()
  if periodicTimer then
    periodicTimer:stop()
    periodicTimer = nil
  end
  if periodic10mTimer then
    periodic10mTimer:stop()
    periodic10mTimer = nil
  end
  print("[layout] Periodic auto-save stopped")
end

local function onScreenChange()
  -- Reset debounce timer on every callback (collapses rapid sequential detections)
  if debounceTimer then debounceTimer:stop() end
  debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
    local count = #hs.screen.allScreens()
    logEvent("screens", string.format("%d → %d", lastScreenCount, count))

    if count == TARGET_DISPLAY_COUNT and lastScreenCount ~= TARGET_DISPLAY_COUNT then
      -- Transitioning TO 5 displays
      -- Cancel any stale retry from a previous reconnection
      cancelRetry("new screen change")

      hs.timer.doAfter(1, function()
        print("[layout] Auto-restoring layout for " .. TARGET_DISPLAY_COUNT .. " displays")

        -- Load saved layout for detection before restore
        local fh = io.open(dataFile, "r")
        if fh then
          local json = fh:read("*a")
          fh:close()
          local ok, savedEntries = pcall(hs.json.decode, json)
          if ok and type(savedEntries) == "table" then
            detectMacOSPlacements(savedEntries)
          end
        end

        local misses = M.restore()
        if misses and #misses > 0 then
          retryActive = true
          logEvent("retry-start", string.format("%d missed windows", #misses))
          retryMisses(misses, "auto-restore")
        end
      end)
      startPeriodicSave()
      -- Sync Lunar display names after a short delay for Lunar to detect screens
      if lunarSyncTimer then lunarSyncTimer:stop() end
      lunarSyncTimer = hs.timer.doAfter(LUNAR_SYNC_DELAY, syncLunarNames)
    elseif count ~= TARGET_DISPLAY_COUNT and lastScreenCount == TARGET_DISPLAY_COUNT then
      -- Transitioning FROM 5 displays
      cancelRetry("displays disconnected")
      clearProtection("displays disconnected")
      stopPeriodicSave()
    end

    lastScreenCount = count
  end)
end

-- ---------------------------------------------------------------------------
-- M.onWake() — compare layout after wake, auto-restore if windows drifted
-- ---------------------------------------------------------------------------

local WAKE_SETTLE_DELAY = 1  -- seconds for displays/windows to stabilize after wake

function M.onWake()
  if #hs.screen.allScreens() ~= TARGET_DISPLAY_COUNT then
    showRestoreHint()
    return
  end

  hs.timer.doAfter(WAKE_SETTLE_DELAY, function()
    -- Bail if displays changed during settle delay
    if #hs.screen.allScreens() ~= TARGET_DISPLAY_COUNT then return end

    -- Load saved layout
    local fh = io.open(dataFile, "r")
    if not fh then return end
    local json = fh:read("*a")
    fh:close()
    local ok, savedEntries = pcall(hs.json.decode, json)
    if not ok or type(savedEntries) ~= "table" then return end

    -- Build live window positions
    local idToPos = buildScreenIdToPosition()
    local livePositions = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
      local app = win:application()
      if app then
        local pos = idToPos[win:screen():id()]
        livePositions[protectionKey(app:name(), win:title())] = pos
      end
    end

    -- Compare: count windows that moved to a different display
    local driftCount = 0
    local driftDetails = {}
    for _, entry in ipairs(savedEntries) do
      local key = protectionKey(entry.app, entry.title)
      local livePos = livePositions[key]
      if livePos and entry.screenPosition and livePos ~= entry.screenPosition then
        driftCount = driftCount + 1
        table.insert(driftDetails, string.format(
          "%s '%s' on %s (saved: %s)", entry.app, entry.title, livePos, entry.screenPosition))
      end
    end

    if driftCount == 0 then
      logEvent("wake-check", "no drift detected")
      return
    end

    -- Windows drifted — restore
    for _, detail in ipairs(driftDetails) do
      logEvent("wake-drift", detail)
    end
    logEvent("wake-restore", string.format("%d windows drifted, restoring", driftCount))
    print(string.format("[layout] Wake: %d windows drifted — auto-restoring", driftCount))

    detectMacOSPlacements(savedEntries)
    local misses = M.restore()
    if misses and #misses > 0 then
      retryActive = true
      logEvent("retry-start", string.format("%d missed windows", #misses))
      retryMisses(misses, "wake-restore")
    end
  end)
end

-- ---------------------------------------------------------------------------
-- M.init() — start screen watcher and periodic save if already at 5
-- ---------------------------------------------------------------------------

function M.init(opts)
  opts = opts or {}
  screenswitch = opts.screenswitch
  screenmemory = opts.screenmemory

  lastScreenCount = #hs.screen.allScreens()

  screenWatcher = hs.screen.watcher.new(onScreenChange)
  screenWatcher:start()
  print("[layout] Screen watcher started")

  if lastScreenCount == TARGET_DISPLAY_COUNT then
    startPeriodicSave()
  end
end

return M
