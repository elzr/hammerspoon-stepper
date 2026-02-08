-- =============================================================================
-- Mouse drag to move/resize window under cursor
-- =============================================================================
-- fn + drag        → move window
-- fn + shift + drag → resize window (nearest corner/edge algorithm)
--
-- Useful for apps like Kitty and Bear where Better Touch Tool doesn't work.
-- Uses global _G.windowDrag table to prevent garbage collection of eventtaps
-- and includes zombie detection (eventtaps that report enabled but don't fire)

local M = {}

-- Global state to prevent garbage collection
_G.windowDrag = _G.windowDrag or {}
_G.windowDrag.dragState = {
    mode = "idle",        -- "idle", "move", "resize"
    startedAs = "none",   -- "fnOnly" or "fnShift" — which combo initiated the drag
    resizeDirX = "none",  -- "left", "right", or "none"
    resizeDirY = "none",  -- "top", "bottom", or "none"
    window = nil,
    windowStartX = 0,
    windowStartY = 0,
    mouseStartX = 0,
    mouseStartY = 0,
    pendingDX = 0,        -- accumulated resize deltas for throttling
    pendingDY = 0,
    frame = nil           -- cached frame during resize (avoids stale reads)
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

-- Divide window into 3x3 grid and return which corner/edge to resize from
local function computeResizeSection(win, mousePos)
    local frame = win:frame()
    local relX = mousePos.x - frame.x
    local relY = mousePos.y - frame.y
    local dirX = relX < frame.w / 3 and "left" or relX > 2 * frame.w / 3 and "right" or "none"
    local dirY = relY < frame.h / 3 and "top" or relY > 2 * frame.h / 3 and "bottom" or "none"
    return dirX, dirY
end

local RESIZE_INTERVAL = 0.033  -- ~30fps resize timer

local function stopResizeTimer()
    if _G.windowDrag.resizeTimer then
        _G.windowDrag.resizeTimer:stop()
        _G.windowDrag.resizeTimer = nil
    end
end

local function startResizeTimer()
    stopResizeTimer()
    _G.windowDrag.resizeTimer = hs.timer.doEvery(RESIZE_INTERVAL, function()
        local dragState = _G.windowDrag.dragState
        if dragState.mode ~= "resize" or not dragState.window then
            stopResizeTimer()
            return
        end
        local tdx = dragState.pendingDX
        local tdy = dragState.pendingDY
        if tdx == 0 and tdy == 0 then return end
        dragState.pendingDX = 0
        dragState.pendingDY = 0

        local f = dragState.frame

        if dragState.resizeDirX == "left" then
            f.x = f.x + tdx
            f.w = f.w - tdx
        elseif dragState.resizeDirX == "right" then
            f.w = f.w + tdx
        end

        if dragState.resizeDirY == "top" then
            f.y = f.y + tdy
            f.h = f.h - tdy
        elseif dragState.resizeDirY == "bottom" then
            f.h = f.h + tdy
        end

        local prev = hs.window.animationDuration
        hs.window.animationDuration = 0
        dragState.window:setFrame(f)
        hs.window.animationDuration = prev
    end)
end

local function clearDragState(dragState)
    dragState.mode = "idle"
    dragState.startedAs = "none"
    dragState.resizeDirX = "none"
    dragState.resizeDirY = "none"
    dragState.window = nil
    dragState.pendingDX = 0
    dragState.pendingDY = 0
    dragState.frame = nil
    stopResizeTimer()
end

local function createMouseMoveHandler()
    return hs.eventtap.new({hs.eventtap.event.types.mouseMoved}, function(event)
        -- Track callback time for zombie detection
        _G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local fnOnly = flags.fn and not (flags.shift or flags.cmd or flags.alt or flags.ctrl)
        local fnShift = flags.fn and flags.shift and not (flags.cmd or flags.alt or flags.ctrl)
        local dragState = _G.windowDrag.dragState

        -- Modifier changed from what started the current operation → end it
        if dragState.mode ~= "idle" then
            local mismatch = (dragState.startedAs == "fnOnly" and not fnOnly)
                          or (dragState.startedAs == "fnShift" and not fnShift)
            if mismatch then
                clearDragState(dragState)
            end
        end

        if dragState.mode == "idle" then
            if fnShift or fnOnly then
                -- Start a new operation
                local win = getWindowUnderMouse()
                if win then
                    local mousePos = hs.mouse.absolutePosition()
                    if fnShift then
                        local dirX, dirY = computeResizeSection(win, mousePos)
                        if dirX == "none" and dirY == "none" then
                            -- Center of window: move instead
                            dragState.mode = "move"
                        else
                            dragState.mode = "resize"
                            dragState.resizeDirX = dirX
                            dragState.resizeDirY = dirY
                            dragState.frame = win:frame()
                            startResizeTimer()
                        end
                        dragState.startedAs = "fnShift"
                    else
                        dragState.mode = "move"
                        dragState.startedAs = "fnOnly"
                    end
                    dragState.window = win
                    local frame = win:frame()
                    dragState.windowStartX = frame.x
                    dragState.windowStartY = frame.y
                    dragState.mouseStartX = mousePos.x
                    dragState.mouseStartY = mousePos.y
                end
            end
        elseif dragState.mode == "move" then
            if dragState.window and dragState.window:isVisible() then
                local dx = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaX)
                local dy = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaY)
                local frame = dragState.window:frame()
                dragState.window:setTopLeft({x = frame.x + dx, y = frame.y + dy})
            end
        elseif dragState.mode == "resize" then
            -- Just accumulate deltas; the resize timer applies them
            local dx = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaX)
            local dy = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaY)
            dragState.pendingDX = dragState.pendingDX + dx
            dragState.pendingDY = dragState.pendingDY + dy
        end

        return false  -- Don't consume the event
    end)
end

local function createFlagsHandler()
    return hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
        -- Track callback time for zombie detection
        _G.windowDrag.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local fnOnly = flags.fn and not (flags.shift or flags.cmd or flags.alt or flags.ctrl)
        local fnShift = flags.fn and flags.shift and not (flags.cmd or flags.alt or flags.ctrl)
        local dragState = _G.windowDrag.dragState

        if dragState.mode ~= "idle" then
            local mismatch = (dragState.startedAs == "fnOnly" and not fnOnly)
                          or (dragState.startedAs == "fnShift" and not fnShift)
            if mismatch then
                clearDragState(dragState)
            end
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

-- Initialize and start the mouse drag functionality
function M.init()
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
end

return M
