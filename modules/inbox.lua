-- THE MESSAGE CENTRE, AS STATE.
--
-- One list per player, oldest first, because that is how a conversation reads.
-- The same list carries a support reply, a bonus notice and an announcement —
-- the server keeps them in one inbox with one unread badge (see be_matatu's
-- services/inbox.ts) and splitting them here would give the player two places
-- to look for one badge.
--
-- Kept apart from the gui script for the reason every module in here is: a
-- claim about what the badge should say, or whether a message is a duplicate,
-- is worth being able to prove without booting a screen.
local M = {}

--- How many messages are held in memory at once.
--
-- The server pages; this is the window. A support thread that has run for a
-- year is not something to keep resident on a phone, and the panel can only
-- show a screenful anyway.
M.MAX_HELD = 200

--- Longest message the player may send. Mirrors MAX_BODY in the service, so
--- the counter under the box and the server's own limit agree — a client that
--- lets somebody type 3000 characters and then silently truncates has taken
--- their words away without telling them.
M.MAX_BODY = 2000

function M.new()
    return {
        messages = {},      -- oldest first
        unread = 0,
        seen_ids = {},      -- id -> true, so a replay cannot double-insert
        loaded = false,     -- has a history page ever arrived
        sending = false,
        error = nil,
    }
end

local function num(v) return tonumber(v) or 0 end

--- Is this something we already hold?
--
-- The same message arrives twice routinely: once live as INBOX_MESSAGE, and
-- again in the next INBOX_HISTORY page. Ids are the server's, so this is exact
-- rather than a guess at equality by text and time.
function M.holds(state, msg)
    if type(state) ~= "table" or type(msg) ~= "table" then return false end
    local id = tostring(msg.id or "")
    if id == "" then return false end
    return state.seen_ids[id] == true
end

--- Add one message, keeping the list oldest-first and bounded.
---
--- Returns true when it was actually added.
function M.append(state, msg)
    if type(state) ~= "table" or type(msg) ~= "table" then return false end
    local id = tostring(msg.id or "")
    if id == "" or state.seen_ids[id] then return false end

    state.seen_ids[id] = true
    state.messages[#state.messages + 1] = msg

    -- Trimmed from the FRONT: the newest are the ones being looked at, and the
    -- oldest can be fetched again by paging.
    while #state.messages > M.MAX_HELD do
        local dropped = table.remove(state.messages, 1)
        if dropped and dropped.id then state.seen_ids[tostring(dropped.id)] = nil end
    end
    return true
end

--- A page of history from the server, which arrives NEWEST first.
--
-- Reversed on the way in so the list stays oldest-first however it was
-- fetched. Merged rather than replacing: a live message that arrived while the
-- page was in flight is already held, and replacing would drop it.
function M.merge_history(state, page)
    if type(state) ~= "table" or type(page) ~= "table" then return 0 end
    local added = 0
    for i = #page, 1, -1 do
        if M.append(state, page[i]) then added = added + 1 end
    end
    -- Sorted after the merge, not assumed: an older page merged after a newer
    -- one would otherwise leave the list out of order.
    table.sort(state.messages, function(a, b)
        local at, bt = tostring(a.at or ""), tostring(b.at or "")
        if at ~= bt then return at < bt end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
    state.loaded = true
    return added
end

--- What the badge says. Never negative, always a whole number.
function M.set_unread(state, n)
    if type(state) ~= "table" then return 0 end
    state.unread = math.max(0, math.floor(num(n)))
    return state.unread
end

--- The player opened the panel.
--
-- The count is cleared LOCALLY and the server is told separately (see
-- websocket_manager.mark_inbox_read). Waiting for the round trip leaves a
-- badge sitting over an open inbox, which reads as the app not having noticed.
function M.mark_all_read(state)
    if type(state) ~= "table" then return end
    state.unread = 0
    for _, m in ipairs(state.messages) do m.read = true end
end

--- Ids the server has not been told about yet.
function M.unread_ids(state)
    local out = {}
    if type(state) ~= "table" then return out end
    for _, m in ipairs(state.messages) do
        if m.direction == "OUT" and not m.read then out[#out + 1] = m.id end
    end
    return out
end

--- Is there anything worth a dot on the bubble?
function M.has_unread(state)
    return type(state) == "table" and (state.unread or 0) > 0
end

--- What to draw on the badge. Capped, because a three-digit number does not
--- fit in a dot and nobody counts past nine anyway.
function M.badge_text(state)
    local n = type(state) == "table" and (state.unread or 0) or 0
    if n <= 0 then return "" end
    if n > 9 then return "9+" end
    return tostring(n)
end

--- Can this be sent? Returns ok, trimmed-or-reason.
function M.compose_check(text)
    local t = tostring(text or ""):gsub("^%s*(.-)%s*$", "%1")
    if t == "" then return false, "Type a message first." end
    if #t > M.MAX_BODY then t = t:sub(1, M.MAX_BODY) end
    return true, t
end

--- The oldest message we hold, for asking the server for the page before it.
function M.oldest_at(state)
    if type(state) ~= "table" then return nil end
    local first = state.messages[1]
    return first and first.at or nil
end

--- Which side of the conversation a message sits on.
--
-- IN is the player's own. Everything else — a support reply, a bonus notice,
-- an announcement — is from us, and is drawn on the other side.
function M.is_mine(msg)
    return type(msg) == "table" and msg.direction == "IN"
end

--- The label above a message that is not the player's own.
function M.sender_label(msg)
    if type(msg) ~= "table" then return "" end
    if msg.direction == "IN" then return "You" end
    local staff = tostring(msg.staffLabel or "")
    if staff ~= "" then return staff end
    if msg.kind == "BONUS" then return "Bonus" end
    if msg.kind == "ANNOUNCEMENT" then return "Announcement" end
    return "Matatu"
end

return M
