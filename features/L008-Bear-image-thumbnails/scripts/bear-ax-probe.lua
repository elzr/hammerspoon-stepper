-- Bear AX probe — diagnostic for L008-Bear-image-thumbnails.
--
-- Purpose: validate the assumptions behind the planned cmd+V interceptor, BEFORE writing it.
--   Q1: Does AXValue return raw markdown `![](path)` after a paste, or a rendered file URL?
--   Q2: Does AXSelectedText return markdown or the file URL when ONLY an embed is selected?
--   Q3: How long does Bear take to insert markdown after a synthesized cmd+V?
--
-- Usage (in Hammerspoon console):
--   probe = dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-ax-probe.lua")
--   probe.probeFullValue()      -- print current note's full AXValue
--   probe.probeSelectedText()   -- print AXSelectedText + AXSelectedTextRange
--   probe.probeClipboard()      -- print clipboard types + text preview
--   probe.probePasteTiming()    -- fire cmd+V via keyStroke, poll, print the inserted slice
--   probe.probeAfterManualPaste() -- YOU paste manually; call this right after to see what AX reports
--
-- Recommended sequence:
--   1. Open a Bear test note that already has an image embed in it.
--   2. probe.probeFullValue()       — does the dump contain `![](path)`?
--   3. Click to place the caret inside the image (select just the embed).
--   4. probe.probeSelectedText()    — what does selecting-just-the-embed look like via AX?
--   5. Click somewhere in plain text to deselect.
--   6. Copy an image to clipboard (e.g., from Finder or a screenshot).
--   7. probe.probePasteTiming()     — fires cmd+V, reports what got inserted and how long it took.

local M = {}

-- ---------------------------------------------------------------------------
-- AX traversal (matches bear-hud.lua's pattern: Window → AXScrollArea → AXTextArea)
-- ---------------------------------------------------------------------------

local function findChildWithRole(el, role)
    local children = el:attributeValue("AXChildren")
    if not children then return nil end
    for _, child in ipairs(children) do
        if child:attributeValue("AXRole") == role then return child end
    end
    return nil
end

local function getBearTextArea()
    local bear = hs.application.get("Bear")
    if not bear then return nil, "Bear not running" end

    -- Fast path: system-wide focused element is often the AXTextArea directly.
    local syswide = hs.axuielement.systemWideElement()
    local focused = syswide:attributeValue("AXFocusedUIElement")
    if focused and focused:attributeValue("AXRole") == "AXTextArea" then
        return focused
    end

    -- Fallback: walk Bear's focused window.
    local appEl = hs.axuielement.applicationElement(bear)
    if not appEl then return nil, "no AX application element" end
    local focusedWin = appEl:attributeValue("AXFocusedWindow")
    if not focusedWin then return nil, "no focused AX window (is a note open?)" end
    local scrollArea = findChildWithRole(focusedWin, "AXScrollArea")
    if not scrollArea then return nil, "no AXScrollArea under focused window" end
    local textArea = findChildWithRole(scrollArea, "AXTextArea")
    if not textArea then return nil, "no AXTextArea under AXScrollArea" end
    return textArea
end

local function truncate(s, n)
    if not s then return "<nil>" end
    if #s <= n then return s end
    return s:sub(1, n) .. string.format("…[+%d more chars]", #s - n)
end

local function sep(label)
    print(string.rep("=", 4) .. " " .. label .. " " .. string.rep("=", 4))
end

-- ---------------------------------------------------------------------------
-- Probes
-- ---------------------------------------------------------------------------

function M.probeFullValue()
    sep("probeFullValue")
    local ta, err = getBearTextArea()
    if not ta then print("[probe] ERR: " .. err); return end
    local value = ta:attributeValue("AXValue") or ""
    print(string.format("AXValue length: %d chars", #value))
    print("--- content ---")
    print(truncate(value, 2000))
    print("--- end content ---")
    -- Quick regex tell-tales:
    local mdImages = 0
    for _ in value:gmatch("!%b[]%b()") do mdImages = mdImages + 1 end
    local fileUrls = 0
    for _ in value:gmatch("file:///") do fileUrls = fileUrls + 1 end
    print(string.format("heuristic counts: markdown-image-embeds=%d, file:///-occurrences=%d",
        mdImages, fileUrls))
    sep("end")
    return value
end

function M.probeSelectedText()
    sep("probeSelectedText")
    local ta, err = getBearTextArea()
    if not ta then print("[probe] ERR: " .. err); return end
    local range = ta:attributeValue("AXSelectedTextRange")
    local selText = ta:attributeValue("AXSelectedText")
    if range then
        print(string.format("AXSelectedTextRange: location=%d length=%d",
            range.location, range.length))
    else
        print("AXSelectedTextRange: <nil>")
    end
    print(string.format("AXSelectedText (length=%d):", selText and #selText or 0))
    print(truncate(selText, 2000))
    if selText and selText:match("^file:///") then
        print("==> selection is a file:// URL (Bear rendered form, not markdown)")
    elseif selText and selText:match("!%b[]%b()") then
        print("==> selection contains markdown image syntax")
    end
    sep("end")
end

function M.probeClipboard()
    sep("probeClipboard")
    local types = hs.pasteboard.typesAvailable() or {}
    print("types available: " .. (next(types) and table.concat(types, ", ") or "<none>"))
    local str = hs.pasteboard.readString()
    print("readString (text): " .. (str and truncate(str, 500) or "<nil>"))
    local imgs = hs.pasteboard.readImage()
    print("readImage: " .. (imgs and "<image present>" or "<nil>"))
    sep("end")
end

function M.probeAfterManualPaste()
    sep("probeAfterManualPaste")
    print("This reports AX state NOW. Run immediately after you manually press ⌘V in Bear.")
    local ta, err = getBearTextArea()
    if not ta then print("[probe] ERR: " .. err); return end
    local value = ta:attributeValue("AXValue") or ""
    local range = ta:attributeValue("AXSelectedTextRange")
    print(string.format("AXValue length: %d chars", #value))
    print(string.format("caret: %d, selection length: %d",
        range and range.location or -1, range and range.length or 0))
    print("--- full content ---")
    print(truncate(value, 2000))
    print("--- end ---")
    local objReplCount = 0
    for _ in value:gmatch("\239\191\188") do objReplCount = objReplCount + 1 end  -- UTF-8 of U+FFFC
    print(string.format("U+FFFC (￼) placeholder count: %d", objReplCount))
    sep("end")
end

function M.probePasteTiming()
    sep("probePasteTiming")
    local ta, err = getBearTextArea()
    if not ta then print("[probe] ERR: " .. err); return end

    -- Diagnostics
    local types = hs.pasteboard.typesAvailable() or {}
    print("clipboard types (raw): " .. hs.inspect(types))
    print("clipboard readImage: " .. (hs.pasteboard.readImage() and "<image present>" or "<nil>"))
    local front = hs.application.frontmostApplication()
    print(string.format("frontmost BEFORE activate: '%s' (bundleID=%s)",
        front and front:name() or "?", front and front:bundleID() or "?"))

    -- Auto-activate Bear so the paste goes there even if invoked from `hs -c` (where
    -- the terminal is frontmost). Then wait for focus to settle before firing.
    local bear = hs.application.find("Bear")
    if not bear then print("[probe] ERR: Bear not running"); return end
    local alreadyFront = front and front:bundleID() == "net.shinyfrog.bear"
    if not alreadyFront then
        print("activating Bear…")
        bear:activate()
    end

    -- Use a nested timer so the paste fires AFTER the activation has settled.
    local settleDelay = alreadyFront and 0.02 or 0.30
    hs.timer.doAfter(settleDelay, function()
        local frontNow = hs.application.frontmostApplication()
        print(string.format("frontmost AT FIRE: '%s'", frontNow and frontNow:name() or "?"))

        local beforeValue = ta:attributeValue("AXValue") or ""
        local beforeRange = ta:attributeValue("AXSelectedTextRange")
        local beforeCaret = beforeRange and beforeRange.location or -1
        local beforeLen = #beforeValue
        print(string.format("BEFORE: AXValue len=%d, caret=%d, selection length=%d",
            beforeLen, beforeCaret, beforeRange and beforeRange.length or 0))
        print("firing cmd+V via hs.eventtap.keyStroke…")

        hs.eventtap.keyStroke({"cmd"}, "v", 0)

        local startTime = hs.timer.secondsSinceEpoch()
        local poll
        poll = hs.timer.doEvery(0.02, function()
            local elapsed = hs.timer.secondsSinceEpoch() - startTime
            local nowValue = ta:attributeValue("AXValue") or ""
            local nowRange = ta:attributeValue("AXSelectedTextRange")
            local nowLen = #nowValue

            if nowLen ~= beforeLen then
                print(string.format("CHANGED after %dms: AXValue len %d→%d (delta %+d)",
                    math.floor(elapsed * 1000), beforeLen, nowLen, nowLen - beforeLen))
                if nowRange then
                    print(string.format("caret: %d → %d (delta %+d)",
                        beforeCaret, nowRange.location, nowRange.location - beforeCaret))
                end
                if beforeCaret >= 0 and nowRange and nowRange.location > beforeCaret then
                    local inserted = nowValue:sub(beforeCaret + 1, nowRange.location)
                    print("--- inserted slice ---")
                    print(truncate(inserted, 500))
                    print(string.format("--- end (inserted bytes: %d) ---", #inserted))
                    if inserted:match("!%b[]%b()") then
                        print("==> inserted has markdown image syntax")
                    elseif inserted:match("^file:///") then
                        print("==> inserted is file:// URL")
                    elseif inserted:match("\239\191\188") then
                        print("==> inserted contains U+FFFC placeholder (￼) — markdown lives elsewhere")
                    end
                end
                sep("end")
                poll:stop()
            elseif elapsed > 3 then
                print("TIMEOUT after 3s — no AXValue change detected")
                sep("end")
                poll:stop()
            end
        end)
    end)
end

return M
