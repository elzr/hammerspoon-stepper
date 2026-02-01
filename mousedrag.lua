-- =============================================================================
-- Mouse drag to move window under cursor (Cmd+Option+Ctrl + mouse move)
-- =============================================================================
-- Useful for apps like Kitty and Bear where Better Touch Tool doesn't work
--
-- Uses global _G.windowDrag table to prevent garbage collection of eventtaps
-- and includes zombie detection (eventtaps that report enabled but don't fire)

local M = {}

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
