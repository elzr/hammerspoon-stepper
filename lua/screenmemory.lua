-- =============================================================================
-- Per-screen window position memory
-- =============================================================================
-- Remembers where each window was on each screen, so cross-screen moves
-- restore the window's previous position on the target screen.
--
-- Two-tier storage:
--   Session memory (winID key)      — in-memory, all windows, lost on reload
--   Persistent memory (app+title)   — on disk, survives reload, 30-day expiry
--
-- screenmemory.saveDeparture(win, screenPos)   — record frame before moving away
-- screenmemory.lookupArrival(win, screenPos)   — returns frameRel or nil
-- screenmemory.updateFromLayout(entries)       — bulk update from layout autosave
-- screenmemory.seedFromRestore(win, pos, rel)  — seed session after layout restore

local M = {}

local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local dataFile = scriptPath .. "../data/screen-memory.json"

local PRUNE_AGE = 30 * 24 * 3600  -- 30 days in seconds
local WRITE_DEBOUNCE = 5          -- seconds after last change

-- Session memory: winID → screenPos → {frameRel={x,y,w,h}, ts=epoch}
local sessionMemory = {}

-- Persistent memory: "app\ntitle" → screenPos → {frameRel={x,y,w,h}, ts=epoch}
local persistentMemory = {}

-- Rename tracking: winID → {app=str, title=str}
local lastKnownTitle = {}

-- Debounced disk write
local writeTimer = nil
local dirty = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function persistKey(appName, title)
  return appName .. "\n" .. title
end

local function now()
  return hs.timer.secondsSinceEpoch()
end

-- ---------------------------------------------------------------------------
-- Disk I/O
-- ---------------------------------------------------------------------------

local function writeToDisk()
  local json = hs.json.encode(persistentMemory, true)
  local fh, err = io.open(dataFile, "w")
  if not fh then
    print("[screenmemory] ERROR: could not write " .. dataFile .. ": " .. tostring(err))
    return
  end
  fh:write(json)
  fh:close()
  dirty = false
end

local function scheduleDiskWrite()
  dirty = true
  if writeTimer then writeTimer:stop() end
  writeTimer = hs.timer.doAfter(WRITE_DEBOUNCE, function()
    writeTimer = nil
    writeToDisk()
  end)
end

local function loadFromDisk()
  local fh = io.open(dataFile, "r")
  if not fh then return end
  local json = fh:read("*a")
  fh:close()
  local ok, data = pcall(hs.json.decode, json)
  if ok and type(data) == "table" then
    persistentMemory = data
  end
end

local function pruneOldEntries()
  local cutoff = now() - PRUNE_AGE
  local pruned = 0
  for key, screens in pairs(persistentMemory) do
    for pos, entry in pairs(screens) do
      if entry.ts and entry.ts < cutoff then
        screens[pos] = nil
        pruned = pruned + 1
      end
    end
    if not next(screens) then
      persistentMemory[key] = nil
    end
  end
  if pruned > 0 then
    print(string.format("[screenmemory] Pruned %d entries older than 30 days", pruned))
    scheduleDiskWrite()
  end
end

-- ---------------------------------------------------------------------------
-- M.init()
-- ---------------------------------------------------------------------------

function M.init()
  loadFromDisk()
  pruneOldEntries()
  local count = 0
  for _ in pairs(persistentMemory) do count = count + 1 end
  print(string.format("[screenmemory] Loaded %d persistent entries from disk", count))
end

-- ---------------------------------------------------------------------------
-- M.saveDeparture(win, screenPos)
-- ---------------------------------------------------------------------------
-- Called BEFORE a window moves away from a screen. Records current frame.

function M.saveDeparture(win, screenPos)
  if not win or not screenPos then return end

  local app = win:application()
  if not app then return end
  local winID = win:id()
  local appName = app:name()
  local title = win:title()
  local f = win:frame()
  local sf = win:screen():frame()

  local frameRel = {
    x = (f.x - sf.x) / sf.w,
    y = (f.y - sf.y) / sf.h,
    w = f.w / sf.w,
    h = f.h / sf.h,
  }

  local ts = now()

  -- Session memory
  if not sessionMemory[winID] then sessionMemory[winID] = {} end
  sessionMemory[winID][screenPos] = {frameRel = frameRel, ts = ts}

  -- Rename detection: if title changed, migrate persistent entries
  local curKey = persistKey(appName, title)
  local prev = lastKnownTitle[winID]
  if prev then
    local prevKey = persistKey(prev.app, prev.title)
    if prevKey ~= curKey then
      -- Merge old entries into new key (keep newer timestamps)
      local oldEntries = persistentMemory[prevKey]
      if oldEntries then
        if not persistentMemory[curKey] then persistentMemory[curKey] = {} end
        for pos, entry in pairs(oldEntries) do
          local existing = persistentMemory[curKey][pos]
          if not existing or existing.ts < entry.ts then
            persistentMemory[curKey][pos] = entry
          end
        end
        persistentMemory[prevKey] = nil
        print(string.format("[screenmemory] Renamed: '%s' → '%s'", prev.title, title))
      end
    end
  end
  lastKnownTitle[winID] = {app = appName, title = title}

  -- Persistent memory
  if not persistentMemory[curKey] then persistentMemory[curKey] = {} end
  persistentMemory[curKey][screenPos] = {frameRel = frameRel, ts = ts}

  scheduleDiskWrite()
end

-- ---------------------------------------------------------------------------
-- M.lookupArrival(win, screenPos)
-- ---------------------------------------------------------------------------
-- Returns frameRel table {x, y, w, h} or nil.

function M.lookupArrival(win, screenPos)
  if not win or not screenPos then return nil end

  local winID = win:id()

  -- Tier 1: session memory (exact winID)
  local session = sessionMemory[winID]
  if session and session[screenPos] then
    return session[screenPos].frameRel
  end

  -- Tier 2: persistent memory (app+title)
  local app = win:application()
  if app then
    local key = persistKey(app:name(), win:title())
    local persist = persistentMemory[key]
    if persist and persist[screenPos] then
      return persist[screenPos].frameRel
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- M.updateFromLayout(entries)
-- ---------------------------------------------------------------------------
-- Bulk update from layout.save() data. Each entry has app, title,
-- screenPosition, frameRel. Called after position-protection substitution,
-- so entries reflect correct (not macOS-shuffled) positions.

function M.updateFromLayout(entries)
  if not entries then return end

  local ts = now()

  -- Build live winID lookup for session memory updates
  local titleToWinID = {}
  for _, win in ipairs(hs.window.orderedWindows()) do
    local app = win:application()
    if app then
      local key = persistKey(app:name(), win:title())
      titleToWinID[key] = win:id()
    end
  end

  for _, entry in ipairs(entries) do
    if entry.screenPosition and entry.frameRel then
      local key = persistKey(entry.app, entry.title)

      -- Update persistent memory
      if not persistentMemory[key] then persistentMemory[key] = {} end
      persistentMemory[key][entry.screenPosition] = {
        frameRel = entry.frameRel,
        ts = ts,
      }

      -- Update session memory if we can find the live window
      local winID = titleToWinID[key]
      if winID then
        if not sessionMemory[winID] then sessionMemory[winID] = {} end
        sessionMemory[winID][entry.screenPosition] = {
          frameRel = entry.frameRel,
          ts = ts,
        }
      end
    end
  end

  scheduleDiskWrite()
end

-- ---------------------------------------------------------------------------
-- M.seedFromRestore(win, screenPos, frameRel)
-- ---------------------------------------------------------------------------
-- Called after layout restore places a window. Seeds session memory only.

function M.seedFromRestore(win, screenPos, frameRel)
  if not win or not screenPos or not frameRel then return end
  local winID = win:id()
  if not sessionMemory[winID] then sessionMemory[winID] = {} end
  sessionMemory[winID][screenPos] = {
    frameRel = frameRel,
    ts = now(),
  }
end

return M
