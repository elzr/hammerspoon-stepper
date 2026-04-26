-- =============================================================================
-- L010 — move-to-resize-on-single-screen ("shove and stretch")
-- =============================================================================
-- On single-screen mode, fuses move and shrink: shoving a window past a screen
-- edge squeezes the visible frame while the virtual frame extends past the
-- edge; pulling back stretches the visible frame as the absorbed offset
-- contracts. Bottoms out at a per-app floor.
--
-- This module is gated at the call site by stepper.lua via layout.activeCount.
-- Multi-screen transition handling lands in v0.4 (see plan.md).
--
-- Design:  features/L010-move-to-resize-on-single-screen/design.md
-- Plan:    features/L010-move-to-resize-on-single-screen/plan.md

local M = {}

local PROJECT_FLOOR = 200
local DIVERGENCE_TOLERANCE = 5  -- px; > this on any axis means external tool moved the window
local PRUNE_AGE = 30 * 24 * 3600  -- 30 days
local WRITE_DEBOUNCE = 5  -- seconds after last change

local SQUEEZE_RED  = {red = 0.9, green = 0.2, blue = 0.2, alpha = 0.95}
local STRETCH_GREEN = {red = 0.2, green = 0.85, blue = 0.4, alpha = 0.95}

-- Apps where window identity reliably matches document identity (one note per
-- window, title = note name). For these, persistent virtual frames are
-- restored verbatim on close-reopen; the fresh-window heuristic is bypassed.
local APP_PRESERVE_ON_CLOSE = {
  ["Bear"] = true,
}

local minShrinkSize = {}
local flashEdge = nil    -- (screen, dir, color) — screen-edge flash for squeeze/stretch
local flashWindow = nil  -- (win, dir, opts)     — window-border flash for divergence-reset
local dataFile = nil     -- absolute path; set in init

-- [winID] = { virtualFrame, expectedVisible, ts }
M.sessionVirtual = {}

-- ["app\ntitle"] = { virtualFrameRel, ts } — survives reload/relaunch
M.persistentMap = {}

-- [winID] = "app\ntitle" — for detecting title rename mid-session
local lastKnownTitle = {}

local writeTimer = nil

local function now()
  return hs.timer.secondsSinceEpoch()
end

-- ---------------------------------------------------------------------------
-- Persistence (debounced disk writes, 30-day prune, app+title key)
-- ---------------------------------------------------------------------------

local function persistKey(win)
  if not win then return nil end
  local app = (win:application() and win:application():name()) or ""
  local title = win:title() or ""
  return app .. "\n" .. title
end

local function frameToRel(frame, screen)
  return {
    x = (frame.x - screen.x) / screen.w,
    y = (frame.y - screen.y) / screen.h,
    w = frame.w / screen.w,
    h = frame.h / screen.h,
  }
end

local function frameFromRel(rel, screen)
  return {
    x = screen.x + rel.x * screen.w,
    y = screen.y + rel.y * screen.h,
    w = rel.w * screen.w,
    h = rel.h * screen.h,
  }
end

local function writeToDisk()
  if not dataFile then return end
  local fh, err = io.open(dataFile, "w")
  if not fh then
    print("[ofsr] ERROR writing " .. dataFile .. ": " .. tostring(err))
    return
  end
  fh:write(hs.json.encode(M.persistentMap, true))
  fh:close()
end

local function scheduleWrite()
  if writeTimer then writeTimer:stop() end
  writeTimer = hs.timer.doAfter(WRITE_DEBOUNCE, function()
    writeTimer = nil
    writeToDisk()
  end)
end

local function loadFromDisk()
  if not dataFile then return 0 end
  local fh = io.open(dataFile, "r")
  if not fh then return 0 end
  local json = fh:read("*a"); fh:close()
  local ok, data = pcall(hs.json.decode, json)
  if not ok or type(data) ~= "table" then return 0 end
  local ts_now, kept, pruned = now(), 0, 0
  for k, v in pairs(data) do
    if v.ts and (ts_now - v.ts) < PRUNE_AGE then
      M.persistentMap[k] = v; kept = kept + 1
    else
      pruned = pruned + 1
    end
  end
  if pruned > 0 then scheduleWrite() end
  return kept
end

-- Mirror screenmemory's title-rename pattern: when we notice a window's title
-- has changed, copy the persistent entry from old key to new key so the
-- squeeze follows the rename instead of getting orphaned.
local function migrateRenamedTitle(win, currentKey)
  local prevKey = lastKnownTitle[win:id()]
  if prevKey and prevKey ~= currentKey and M.persistentMap[prevKey] then
    M.persistentMap[currentKey] = M.persistentMap[prevKey]
    M.persistentMap[prevKey] = nil
    print(string.format("[ofsr] migrated rename %q → %q",
      prevKey:gsub("\n", ":"), currentKey:gsub("\n", ":")))
    scheduleWrite()
  end
  lastKnownTitle[win:id()] = currentKey
end

local function persistVirtual(win, virtualFrame, screen, hasAbs)
  local key = persistKey(win)
  if not key then return end
  migrateRenamedTitle(win, key)
  if hasAbs then
    M.persistentMap[key] = {
      virtualFrameRel = frameToRel(virtualFrame, screen),
      ts = now(),
    }
    scheduleWrite()
  elseif M.persistentMap[key] then
    M.persistentMap[key] = nil
    scheduleWrite()
  end
end

-- Try to revive a virtual frame for `win` from the persistent map. Returns
-- the virtual frame if revived (and applies it to the window if needed),
-- or nil if no persistent entry exists or it was treated as stale.
local function tryRestore(win, screen)
  local key = persistKey(win)
  local persisted = key and M.persistentMap[key]
  if not persisted then return nil end

  local restoredVirtual = frameFromRel(persisted.virtualFrameRel, screen)
  local restoredVisible = M.clampToScreen(restoredVirtual, screen)
  local live = win:frame()
  local liveLooksSqueezed = math.abs(live.w - restoredVisible.w) < 10
                        and math.abs(live.h - restoredVisible.h) < 10

  -- Persistent entry has absorption if rel coords extend past [0,1].
  local rel = persisted.virtualFrameRel
  local hasPersistedAbs = rel.x < -0.001 or rel.y < -0.001
                       or rel.x + rel.w > 1.001 or rel.y + rel.h > 1.001

  local app = (win:application() and win:application():name()) or ""
  local preserveOnClose = APP_PRESERVE_ON_CLOSE[app]

  if hasPersistedAbs and not liveLooksSqueezed and not preserveOnClose then
    print(string.format(
      "[ofsr-restore] %q dropped — live=%dx%d differs from restored=%dx%d (looks fresh, app not preserved)",
      key:gsub("\n", ":"),
      math.floor(live.w + 0.5), math.floor(live.h + 0.5),
      math.floor(restoredVisible.w + 0.5), math.floor(restoredVisible.h + 0.5)))
    M.persistentMap[key] = nil
    scheduleWrite()
    return nil
  end

  if not liveLooksSqueezed then
    win:setFrame(restoredVisible)
    print(string.format(
      "[ofsr-restore] %q applied (re-squeezing) — live=%dx%d → restored=%dx%d",
      key:gsub("\n", ":"),
      math.floor(live.w + 0.5), math.floor(live.h + 0.5),
      math.floor(restoredVisible.w + 0.5), math.floor(restoredVisible.h + 0.5)))
  else
    print(string.format("[ofsr-restore] %q seeded (live already squeezed at %dx%d)",
      key:gsub("\n", ":"),
      math.floor(live.w + 0.5), math.floor(live.h + 0.5)))
  end
  lastKnownTitle[win:id()] = key
  return restoredVirtual
end

-- ---------------------------------------------------------------------------
-- Pure helpers — testable without a window handle
-- ---------------------------------------------------------------------------

function M.clampToScreen(virtual, screen)
  local x = math.max(virtual.x, screen.x)
  local y = math.max(virtual.y, screen.y)
  local right = math.min(virtual.x + virtual.w, screen.x + screen.w)
  local bottom = math.min(virtual.y + virtual.h, screen.y + screen.h)
  return { x = x, y = y, w = right - x, h = bottom - y }
end

function M.getStep(screen)
  local gp = (spoon and spoon.WinWin and spoon.WinWin.gridparts) or 30
  return { w = screen.w / gp, h = screen.h / gp }
end

function M.getFloor(appName)
  local appKey = (appName or ""):lower()
  local appMin = minShrinkSize[appKey] or {}
  return {
    w = math.max(PROJECT_FLOOR, appMin.w or 0),
    h = math.max(PROJECT_FLOOR, appMin.h or 0),
  }
end

function M.computeMove(virtual, dir, step, screen, floor)
  local nv = { x = virtual.x, y = virtual.y, w = virtual.w, h = virtual.h }
  if dir == "left" then
    nv.x = math.max(virtual.x - step.w, screen.x + floor.w - nv.w)
  elseif dir == "right" then
    nv.x = math.min(virtual.x + step.w, screen.x + screen.w - floor.w)
  elseif dir == "up" then
    nv.y = math.max(virtual.y - step.h, screen.y + floor.h - nv.h)
  elseif dir == "down" then
    nv.y = math.min(virtual.y + step.h, screen.y + screen.h - floor.h)
  end
  return nv
end

local function absorbed(virtual, screen)
  return {
    L = math.max(0, screen.x - virtual.x),
    R = math.max(0, (virtual.x + virtual.w) - (screen.x + screen.w)),
    T = math.max(0, screen.y - virtual.y),
    B = math.max(0, (virtual.y + virtual.h) - (screen.y + screen.h)),
  }
end
M._absorbed = absorbed

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------

function M.getVirtual(win)
  if not win then return nil end
  local entry = M.sessionVirtual[win:id()]
  return entry and entry.virtualFrame or nil
end

function M.reset(win)
  if not win then return end
  local hadEntry = M.sessionVirtual[win:id()] ~= nil
  M.sessionVirtual[win:id()] = nil
  -- Drop the persistent entry too — explicit resets (snap-to-edge, maximize,
  -- etc.) take direct control of size/position, so the cross-session squeeze
  -- shouldn't haunt this window after the user said "no, I want this size."
  local key = persistKey(win)
  if key and M.persistentMap[key] then
    M.persistentMap[key] = nil
    scheduleWrite()
  end
  if hadEntry then print(string.format("[reset] win=%q", (win:title() or "?"))) end
end

-- Drop the virtual frame for `win` if one exists, with a red window-border
-- flash to communicate the drop to the user. No-op (no flash) if the window
-- has no virtual frame. Used by mousemove.lua to proactively notify when
-- fn-drag is about to invalidate a squeeze.
function M.resetWithNotice(win)
  if not win then return false end
  local entry = M.sessionVirtual[win:id()]
  if not entry then return false end
  M.sessionVirtual[win:id()] = nil
  if flashWindow then flashWindow(win, nil, {color = SQUEEZE_RED}) end
  print(string.format("[ofsr-reset] win=%q (drag will invalidate virtual frame)",
    win:title() or "?"))
  return true
end

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

-- True if live frame has diverged from what we last applied (external tool
-- moved/resized between operations). Tolerance absorbs Retina rounding.
local function hasDiverged(win)
  local entry = M.sessionVirtual[win:id()]
  if not entry then return false end
  local live = win:frame()
  local e = entry.expectedVisible
  return math.abs(live.x - e.x) > DIVERGENCE_TOLERANCE
      or math.abs(live.y - e.y) > DIVERGENCE_TOLERANCE
      or math.abs(live.w - e.w) > DIVERGENCE_TOLERANCE
      or math.abs(live.h - e.h) > DIVERGENCE_TOLERANCE
end
M._hasDiverged = hasDiverged

-- Returns the screen-edge whose absorbed offset changed most this op, plus the
-- signed delta. Positive delta = squeezing (more absorbed), negative = stretching.
local function changedEdge(prev, new)
  local d = {left = new.L - prev.L, right = new.R - prev.R,
             up = new.T - prev.T, down = new.B - prev.B}
  local bestEdge, bestDelta, bestMag = nil, 0, 0.5  -- threshold to ignore Retina noise
  for edge, delta in pairs(d) do
    if math.abs(delta) > bestMag then
      bestMag = math.abs(delta); bestDelta = delta; bestEdge = edge
    end
  end
  return bestEdge, bestDelta
end

function M.shove(win, dir)
  if not win then return end
  local appName = (win:application() and win:application():name()) or ""
  local screen = win:screen():frame()

  if hasDiverged(win) then
    -- Silent reset: fn-drag's onDragStart already flashed (proactive). For
    -- non-fn-drag external moves (BTT, system shortcuts, etc.) we still
    -- self-heal here, but without a flash since the user wasn't watching for it.
    print(string.format("[ofsr-divergence] win=%q — external move detected, silent reset",
      win:title() or "?"))
    M.sessionVirtual[win:id()] = nil
  end

  -- Lazy restore from persistent map if no session entry yet.
  -- Survives reload, app-relaunch (with Bear opt-out), title rename.
  local virtual = M.getVirtual(win)
  if not virtual then
    virtual = tryRestore(win, screen)
  end
  virtual = virtual or win:frame()
  local prevAbs = absorbed(virtual, screen)
  local step = M.getStep(screen)
  local floor = M.getFloor(appName)

  local newVirtual = M.computeMove(virtual, dir, step, screen, floor)
  local newVisible = M.clampToScreen(newVirtual, screen)
  local newAbs = absorbed(newVirtual, screen)

  win:setFrame(newVisible)

  -- Only keep an entry when there's actual absorption to track. Pure slides
  -- (no absorbed offset on any edge) leave the window in a clean state, so
  -- a subsequent fn-drag should NOT flash red — there was nothing to lose.
  local hasAbs = newAbs.L > 0.5 or newAbs.R > 0.5 or newAbs.T > 0.5 or newAbs.B > 0.5
  if hasAbs then
    M.sessionVirtual[win:id()] = {
      virtualFrame = newVirtual,
      expectedVisible = newVisible,
      ts = now(),
    }
  else
    M.sessionVirtual[win:id()] = nil
  end

  -- Persist to disk (debounced) for cross-reload survival.
  persistVirtual(win, newVirtual, screen, hasAbs)

  -- Visual feedback at the screen edge being absorbed-into / released-from.
  -- Red on squeeze (more absorbed), green on stretch (less). Pure slides skip.
  local edge, delta = changedEdge(prevAbs, newAbs)
  if flashEdge and edge then
    flashEdge(screen, edge, delta > 0 and SQUEEZE_RED or STRETCH_GREEN)
  end

  -- Trace only when something interesting happened — i.e., absorption changed
  -- this op, or the window was already in a non-trivial absorbed state. Pure
  -- slides (no absorbed offset before or after) stay silent.
  local prevHasAbs = prevAbs.L > 0.5 or prevAbs.R > 0.5 or prevAbs.T > 0.5 or prevAbs.B > 0.5
  if edge or hasAbs or prevHasAbs then
    print(string.format(
      "[shove] win=%q dir=%s vis=%dx%d absL=%d absR=%d absT=%d absB=%d",
      appName .. ":" .. (win:title() or ""), dir,
      math.floor(newVisible.w + 0.5), math.floor(newVisible.h + 0.5),
      math.floor(newAbs.L + 0.5), math.floor(newAbs.R + 0.5),
      math.floor(newAbs.T + 0.5), math.floor(newAbs.B + 0.5)
    ))
  end
end

-- Mirror a visible-frame delta on the virtual frame (B4: resize preserves
-- absorbed). Caller passes the deltas it already applied to the visible frame.
-- If the live frame has diverged (external tool moved the window), we drop
-- the virtual state instead — preserving stale absorbed offset would be wrong.
function M.bumpVirtual(win, dx, dy, dw, dh)
  if not win then return end
  local entry = M.sessionVirtual[win:id()]
  if not entry then return end

  if hasDiverged(win) then
    -- Silent reset; see comment in shove for the rationale.
    print(string.format("[ofsr-divergence] win=%q — diverged before resize, silent reset",
      win:title() or "?"))
    M.sessionVirtual[win:id()] = nil
    return
  end

  local v = entry.virtualFrame
  local e = entry.expectedVisible
  local newV = {
    x = v.x + (dx or 0), y = v.y + (dy or 0),
    w = v.w + (dw or 0), h = v.h + (dh or 0),
  }
  M.sessionVirtual[win:id()] = {
    virtualFrame = newV,
    expectedVisible = {
      x = e.x + (dx or 0), y = e.y + (dy or 0),
      w = e.w + (dw or 0), h = e.h + (dh or 0),
    },
    ts = now(),
  }

  -- Persist updated virtual frame.
  local screen = win:screen():frame()
  local abs = absorbed(newV, screen)
  local hasAbs = abs.L > 0.5 or abs.R > 0.5 or abs.T > 0.5 or abs.B > 0.5
  persistVirtual(win, newV, screen, hasAbs)
end

-- ---------------------------------------------------------------------------
-- Init + self-test
-- ---------------------------------------------------------------------------

-- Apply tryRestore to a window proactively, seeding the session entry too.
-- Used for eager restoration on app launch / window-created (Bear especially).
local function eagerRestore(win)
  if not win or not win:isStandard() then return end
  if #hs.screen.allScreens() ~= 1 then return end
  local screen = win:screen():frame()
  local restored = tryRestore(win, screen)
  if not restored then return end
  M.sessionVirtual[win:id()] = {
    virtualFrame = restored,
    expectedVisible = win:frame(),
    ts = now(),
  }
  local key = persistKey(win)
  print(string.format("[ofsr-eager] %q restored on appearance",
    (key or "?"):gsub("\n", ":")))
end

-- Watch for windows of preserve-on-close apps (Bear) appearing, and apply
-- the persistent squeeze immediately. Also iterate existing windows once on
-- start, so reload-while-Bear-open also gets picked up.
M._restoreWatcher = nil  -- module-level to survive GC
local function startEagerRestoreWatcher()
  if M._restoreWatcher then
    M._restoreWatcher:unsubscribeAll()
    M._restoreWatcher = nil
  end
  local appNames = {}
  for app, _ in pairs(APP_PRESERVE_ON_CLOSE) do
    table.insert(appNames, app)
  end
  if #appNames == 0 then return end

  for _, app in ipairs(appNames) do
    local appObj = hs.application.find(app)
    if appObj then
      for _, win in ipairs(appObj:allWindows()) do eagerRestore(win) end
    end
  end

  M._restoreWatcher = hs.window.filter.new(appNames)
    :subscribe(hs.window.filter.windowCreated, eagerRestore)
end

function M.init(opts)
  opts = opts or {}
  if opts.minShrinkSize then minShrinkSize = opts.minShrinkSize end
  if opts.flashEdge then flashEdge = opts.flashEdge end
  if opts.flashWindow then flashWindow = opts.flashWindow end
  if opts.dataFile then dataFile = opts.dataFile end
  local kept = loadFromDisk()
  startEagerRestoreWatcher()
  print(string.format(
    "[ofsr] initialized; floor=%dpx, divergence=%dpx, flashEdge=%s flashWindow=%s, persisted=%d, eagerWatch=%s",
    PROJECT_FLOOR, DIVERGENCE_TOLERANCE,
    flashEdge and "on" or "off", flashWindow and "on" or "off", kept,
    M._restoreWatcher and "on" or "off"))
end

-- Synthetic-frame assertions; run via:
--   hs -c 'return dofile(".../move-to-resize-on-single-screen.lua").selfTest()'
function M.selfTest()
  local results = {}
  local function eq(label, a, b)
    local pass = (math.abs(a - b) < 0.001)
    table.insert(results, { label = label, pass = pass, got = a, want = b })
  end

  local screen = { x = 0, y = 0, w = 1440, h = 900 }
  local floor = { w = 200, h = 200 }
  local step = { w = 48, h = 30 }

  -- 1. clampToScreen: window fully on-screen → unchanged
  local v1 = { x = 100, y = 100, w = 800, h = 600 }
  local c1 = M.clampToScreen(v1, screen)
  eq("clamp-onscreen.x", c1.x, 100); eq("clamp-onscreen.w", c1.w, 800)

  -- 2. clampToScreen: virtual extends past left → visible shrinks
  local v2 = { x = -100, y = 100, w = 800, h = 600 }
  local c2 = M.clampToScreen(v2, screen)
  eq("clamp-leftabs.x", c2.x, 0); eq("clamp-leftabs.w", c2.w, 700)

  -- 3. clampToScreen: virtual extends past right → visible shrinks
  local v3 = { x = 700, y = 100, w = 800, h = 600 }
  local c3 = M.clampToScreen(v3, screen)
  eq("clamp-rightabs.x", c3.x, 700); eq("clamp-rightabs.w", c3.w, 740)

  -- 4. clampToScreen: wider-than-screen, both sides absorbed
  local v4 = { x = -100, y = 0, w = 1600, h = 900 }
  local c4 = M.clampToScreen(v4, screen)
  eq("clamp-wider.x", c4.x, 0); eq("clamp-wider.w", c4.w, 1440)

  -- 5. computeMove: normal slide left (no absorb yet)
  local m5 = M.computeMove({ x = 200, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-slide-left.x", m5.x, 152)

  -- 6. computeMove: cross threshold into absorb
  local m6 = M.computeMove({ x = 0, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-into-absorb-left.x", m6.x, -48)

  -- 7. computeMove: floor cap on left
  -- nv.w=800, floor.w=200 → minX = 0 + 200 - 800 = -600
  local m7 = M.computeMove({ x = -580, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-floor-left.x", m7.x, -600)
  -- And again from already-floored position should stay
  local m7b = M.computeMove({ x = -600, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-floor-left-stays.x", m7b.x, -600)

  -- 8. computeMove: floor cap on right
  local m8 = M.computeMove({ x = 1220, y = 100, w = 800, h = 600 }, "right", step, screen, floor)
  -- maxX = 1440 - 200 = 1240
  eq("move-floor-right.x", m8.x, 1240)

  -- 9. computeMove: release absorbed by moving toward absorbed edge
  -- start with virtual.x=-100 (100 absorbed on left), move right
  local m9 = M.computeMove({ x = -100, y = 100, w = 800, h = 600 }, "right", step, screen, floor)
  eq("move-release-left.x", m9.x, -52)

  -- 10. getFloor: project default
  minShrinkSize = {}
  local f10 = M.getFloor("Bear")
  eq("floor-default.w", f10.w, 200); eq("floor-default.h", f10.h, 200)

  -- 11. getFloor: app-specific min beats project floor
  minShrinkSize = { kitty = { w = 900, h = 400 } }
  local f11 = M.getFloor("kitty")
  eq("floor-kitty.w", f11.w, 900); eq("floor-kitty.h", f11.h, 400)

  -- 12. getFloor: lowercased lookup
  local f12 = M.getFloor("Kitty")
  eq("floor-kitty-cased.w", f12.w, 900)

  -- 13. absorbed: derive from virtual + screen
  local a13 = absorbed({ x = -120, y = 0, w = 800, h = 900 }, screen)
  eq("absorbed.L", a13.L, 120); eq("absorbed.R", a13.R, 0)

  -- Tally
  local pass, fail = 0, 0
  for _, r in ipairs(results) do
    if r.pass then pass = pass + 1
    else
      fail = fail + 1
      print(string.format("[selfTest FAIL] %s: got=%s want=%s", r.label, tostring(r.got), tostring(r.want)))
    end
  end
  print(string.format("[selfTest] %d/%d passed", pass, pass + fail))
  minShrinkSize = {}  -- reset
  return { pass = pass, fail = fail }
end

return M
