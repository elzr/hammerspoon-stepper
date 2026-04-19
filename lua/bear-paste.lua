-- =============================================================================
-- bear-paste: auto-shrink images pasted into Bear to 150px thumbnails
-- =============================================================================
-- Observer-based design. No event tap.
--
-- Flow:
--   1. hs.axuielement.observer watches Bear at the *app* level for
--      AXSelectedTextChanged notifications (fires on typing, clicking, pasting).
--   2. On each fire we filter: element must be AXTextArea, AXValue must have
--      grown by exactly +3 bytes (= 1 new U+FFFC / ￼ placeholder), the newly
--      added char must be ￼, and the clipboard must hold an image.
--   3. If all match, we append a width comment at the caret via
--      setAttributeValue("AXSelectedText", '<!-- {"width":150} -->'). Bear
--      attaches the comment to the preceding embed and re-renders the image
--      at the configured width.
--
-- Important quirk: Bear summarizes every embed (image/pdf) as ONE ￼ character
-- in AXValue. Adding a width comment does NOT grow AXValue — the comment gets
-- attached to the embed's markdown in Bear's database, which remains a single
-- ￼ in the AX layer. Don't use AXValue length to verify the write landed;
-- verify visually (image renders as thumbnail) or via clipboard roundtrip
-- (⌘A → ⌘C in a test note gives the full markdown).
--
-- See features/L008-Bear-image-thumbnails/ for design doc and dev-guide.

local M = {}

local BEAR_BUNDLE = "net.shinyfrog.bear"
local THUMB_COMMENT_SMALL = '<!-- {"width":150} -->'
local UTF8_OBJ_REPL = "\239\191\188" -- U+FFFC in UTF-8

local observer = nil
local lastTa = nil        -- last textarea we saw (AX element reference)
local lastLen = nil       -- last AXValue byte length for that textarea
local inserting = false   -- guard against self-induced notifications
local logger = hs.logger.new("bear-paste", "info")

-- =============================================================================
-- Observer callback
-- =============================================================================

local function onObserverFire(_obs, el, _notif)
  if inserting then return end
  if not el then return end
  local ok, role = pcall(function() return el:attributeValue("AXRole") end)
  if not ok or role ~= "AXTextArea" then return end

  local value = el:attributeValue("AXValue") or ""
  local curLen = #value

  -- New textarea? Just snapshot the baseline and return.
  if el ~= lastTa then
    lastTa = el
    lastLen = curLen
    return
  end

  local delta = curLen - (lastLen or curLen)
  lastLen = curLen

  -- Target case: exactly one new ￼ (3 UTF-8 bytes).
  if delta ~= 3 then return end
  -- Confirm the new bytes are actually the object-replacement character.
  -- Caret is now just past the inserted ￼; look at the 3 bytes before it.
  local range = el:attributeValue("AXSelectedTextRange")
  if not range or range.location < 1 then return end
  -- range.location is in AX chars (￼ = 1), but value is UTF-8 bytes.
  -- The paste grew value by exactly 3 bytes; the last 3 bytes of the *grown*
  -- range are the new ￼ iff value ends with (or at-caret-position has) ￼.
  -- Cheap approximation: take the 3 bytes ending at the caret byte-position.
  -- Since ￼ is always 3 bytes, just check the last inserted 3 bytes using
  -- the tail of value — good enough when paste is at end-of-note; for paste
  -- in the middle we'd need to map AX char position → byte offset. For now
  -- check the simple way, and fall back to "contains ￼ somewhere new".
  local lastThree = value:sub(-3)
  if lastThree ~= UTF8_OBJ_REPL and not value:find(UTF8_OBJ_REPL, 1, true) then
    return
  end

  -- Gate: was there an image on the clipboard? If not, this wasn't an image paste.
  if not hs.pasteboard.readImage() then return end

  -- Fire the insert. Guard against our own feedback notifications.
  inserting = true
  pcall(function()
    el:setAttributeValue("AXSelectedText", THUMB_COMMENT_SMALL)
  end)
  inserting = false
  lastLen = #(el:attributeValue("AXValue") or "")
  logger.i("paste→shrink applied")
end

-- =============================================================================
-- Init / stop
-- =============================================================================

function M.init()
  M.stop()
  local bear = hs.application.get("Bear")
  if not bear then
    logger.w("Bear not running at init; restart Hammerspoon after launching Bear")
    return
  end
  observer = hs.axuielement.observer.new(bear:pid())
  observer:callback(onObserverFire)
  local appEl = hs.axuielement.applicationElement(bear)
  local ok = pcall(function()
    observer:addWatcher(appEl, "AXSelectedTextChanged")
  end)
  if not ok then
    logger.w("failed to addWatcher on Bear app element")
    observer = nil
    return
  end
  observer:start()
  logger.i("initialized (app-level observer)")
end

function M.stop()
  if observer then
    pcall(function() observer:stop() end)
    observer = nil
  end
  lastTa = nil
  lastLen = nil
  inserting = false
end

return M
