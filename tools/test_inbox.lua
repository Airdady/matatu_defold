-- THE MESSAGE CENTRE, AS STATE.
--
--   Run: lua tools/test_inbox.lua
--
-- One list per player, oldest first, carrying a support reply, a bonus notice
-- and an announcement alike — the server keeps them in one inbox with one
-- unread badge, and splitting them here would give the player two places to
-- look for one badge.
--
-- The properties that matter are about DUPLICATES and ORDER. The same message
-- arrives twice routinely — once live, again in the next history page — and a
-- page fetched later covers older ground than one fetched first.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path
local I = require("modules.inbox")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

local function m(id, dir, body, at, extra)
    local msg = {
        id = id, direction = dir, kind = "SUPPORT", body = body,
        at = at or ("2026-08-27T00:00:" .. string.format("%02d", tonumber(id:match("%d+")) or 0) .. "Z"),
        read = false,
    }
    for k, v in pairs(extra or {}) do msg[k] = v end
    return msg
end

----------------------------------------------------------------------
print("A MESSAGE IS NEVER HELD TWICE")
----------------------------------------------------------------------
do
    local s = I.new()
    check("the first copy is added", I.append(s, m("1", "OUT", "hello")), true)
    check("the second is refused", I.append(s, m("1", "OUT", "hello")), false)
    check("and only one is held", #s.messages, 1)
end

do
    -- The real sequence: a live message, then the history page that contains
    -- it. Without the id check the player sees their own conversation doubled.
    local s = I.new()
    I.append(s, m("2", "OUT", "live"))
    I.merge_history(s, { m("2", "OUT", "live"), m("1", "IN", "earlier") })
    check("a page containing a live message does not double it", #s.messages, 2)
end

do
    local s = I.new()
    check("a message with no id is refused rather than stored", I.append(s, { body = "x" }), false)
    check("and so is nothing at all", I.append(s, nil), false)
end

----------------------------------------------------------------------
print("THE LIST IS OLDEST FIRST, HOWEVER IT WAS FETCHED")
----------------------------------------------------------------------
do
    -- A history page arrives NEWEST first. Reversed on the way in.
    local s = I.new()
    I.merge_history(s, { m("3", "OUT", "third"), m("2", "IN", "second"), m("1", "OUT", "first") })
    check("oldest is first", s.messages[1].body, "first")
    check("newest is last", s.messages[#s.messages].body, "third")
end

do
    -- An OLDER page merged after a newer one. Sorting after the merge rather
    -- than assuming append order is what keeps this right.
    local s = I.new()
    I.merge_history(s, { m("4", "OUT", "d"), m("3", "IN", "c") })
    I.merge_history(s, { m("2", "OUT", "b"), m("1", "IN", "a") })
    local order = {}
    for i, msg in ipairs(s.messages) do order[i] = msg.body end
    check("the whole thread is still in order", table.concat(order, ","), "a,b,c,d")
end

----------------------------------------------------------------------
print("THE LIST IS BOUNDED, AND TRIMS THE RIGHT END")
----------------------------------------------------------------------
do
    local s = I.new()
    for i = 1, I.MAX_HELD + 40 do
        I.append(s, { id = tostring(i), direction = "OUT", body = "m" .. i, at = string.format("%05d", i) })
    end
    check("held at the cap", #s.messages, I.MAX_HELD)
    -- Trimmed from the FRONT: the newest are what is being looked at, and the
    -- oldest can be fetched again by paging.
    check("and it is the newest that survive", s.messages[#s.messages].body, "m" .. (I.MAX_HELD + 40))
end

do
    -- A trimmed message must leave the seen set too, or it can never be
    -- re-fetched — paging back would silently return nothing.
    local s = I.new()
    for i = 1, I.MAX_HELD + 5 do
        I.append(s, { id = tostring(i), direction = "OUT", body = "m" .. i, at = string.format("%05d", i) })
    end
    check("a trimmed message can be re-added", I.append(s, {
        id = "1", direction = "OUT", body = "m1", at = "00001",
    }), true)
end

----------------------------------------------------------------------
print("THE BADGE")
----------------------------------------------------------------------
do
    local s = I.new()
    check("nothing to show at zero", I.badge_text(s), "")
    check("and no dot", I.has_unread(s), false)
    I.set_unread(s, 3)
    check("three", I.badge_text(s), "3")
    check("and a dot", I.has_unread(s), true)
    I.set_unread(s, 47)
    check("capped, because a three-digit number does not fit in a dot", I.badge_text(s), "9+")
end

do
    local s = I.new()
    check("a negative count is not a count", I.set_unread(s, -5), 0)
    check("nor is junk", I.set_unread(s, "many"), 0)
    check("and a fraction is whole", I.set_unread(s, 2.7), 2)
end

do
    local s = I.new()
    I.append(s, m("1", "OUT", "reply"))
    I.append(s, m("2", "IN", "mine"))
    I.set_unread(s, 1)
    local ids = I.unread_ids(s)
    check("only messages TO the player are reported unread", #ids, 1)
    check("and it is the right one", ids[1], "1")

    I.mark_all_read(s)
    check("opening the panel clears the count", s.unread, 0)
    check("and marks them read", s.messages[1].read, true)
    check("with nothing left to report", #I.unread_ids(s), 0)
end

----------------------------------------------------------------------
print("WHAT MAY BE SENT")
----------------------------------------------------------------------
do
    local ok, why = I.compose_check("   ")
    check("an empty draft is refused", ok, false)
    check("and says why", why, "Type a message first.")
    check("so is nothing at all", (I.compose_check(nil)), false)
end

do
    local ok, text = I.compose_check("  hello there  ")
    check("a real draft is accepted", ok, true)
    check("and trimmed", text, "hello there")
end

do
    -- Cut rather than rejected: losing what somebody typed is worse than
    -- shortening it, and the cap mirrors the server's own MAX_BODY.
    local ok, text = I.compose_check(string.rep("x", I.MAX_BODY + 500))
    check("an over-long draft is cut, not rejected", ok, true)
    check("to the server's own limit", #text, I.MAX_BODY)
end

----------------------------------------------------------------------
print("WHICH SIDE A MESSAGE SITS ON")
----------------------------------------------------------------------
do
    check("the player's own", I.is_mine(m("1", "IN", "x")), true)
    check("a reply is not", I.is_mine(m("2", "OUT", "x")), false)
    check("and junk is not", I.is_mine(nil), false)

    check("their own line is labelled You", I.sender_label(m("1", "IN", "x")), "You")
    check("a named operator is used", I.sender_label(m("2", "OUT", "x", nil,
        { staffLabel = "Brenda" })), "Brenda")
    check("a bonus says so", I.sender_label({ direction = "OUT", kind = "BONUS" }), "Bonus")
    check("an announcement says so", I.sender_label({ direction = "OUT", kind = "ANNOUNCEMENT" }),
        "Announcement")
    check("and anything else is the game", I.sender_label({ direction = "OUT", kind = "SYSTEM" }),
        "Matatu")
end

----------------------------------------------------------------------
print("PAGING BACK")
----------------------------------------------------------------------
do
    local s = I.new()
    check("nothing held, nothing to page from", I.oldest_at(s), nil)
    I.merge_history(s, { m("2", "OUT", "b"), m("1", "IN", "a") })
    -- A timestamp, not an offset: an offset shifts underneath a message
    -- arriving mid-scroll and silently skips or repeats one.
    check("the oldest held timestamp is what is asked from", I.oldest_at(s), s.messages[1].at)
end

----------------------------------------------------------------------
print("THE SCREEN ACTUALLY USES IT")
----------------------------------------------------------------------
do
    local function src(rel)
        local f = io.open(ROOT .. rel); local t = f:read("a"); f:close()
        return (t:gsub("%-%-[^\n]*", ""))
    end
    local gui = src("main/inbox.gui_script")
    local wsm = src("modules/websocket_manager.lua")
    local ctrl = src("main/controller.script")

    check("the protocol is sent", wsm:find("INBOX_SEND", 1, true) ~= nil, true)
    check("and fetched", wsm:find("INBOX_FETCH", 1, true) ~= nil, true)
    check("and read", wsm:find("INBOX_READ", 1, true) ~= nil, true)
    check("live messages are parsed", wsm:find('t == "INBOX_MESSAGE"', 1, true) ~= nil, true)
    check("the badge is parsed", wsm:find('t == "INBOX_UNREAD"', 1, true) ~= nil, true)

    check("the controller forwards to the bubble", ctrl:find('"#inbox"', 1, true) ~= nil, true)

    -- A closed bubble must never eat a tap meant for the board underneath.
    check("input focus is only held while open",
        gui:find('if not self.open then', 1, true) ~= nil, true)
    check("and released on close",
        gui:find('release_input_focus', 1, true) ~= nil, true)
    check("the bubble is hidden before sign-in",
        gui:find("ws.is_identified == true", 1, true) ~= nil, true)
end

----------------------------------------------------------------------
print("THE BUTTON ITSELF")
----------------------------------------------------------------------
do
    local function src(rel)
        local f = io.open(ROOT .. rel); local t = f:read("a"); f:close()
        return t
    end
    local raw = src("main/inbox.gui_script")
    local gui = (raw:gsub("%-%-[^\n]*", ""))

    -- ROUND. A gui box is a rectangle; roundness has to come from artwork,
    -- and circle.png is already in ui.atlas.
    check("it is drawn from the circle image", gui:find('hash("circle")', 1, true) ~= nil, true)
    check("with a chat icon on it", gui:find('hash("bubble")', 1, true) ~= nil, true)
    check("and the atlas is reached safely, so a missing image cannot kill init",
        gui:find("pcall(function()", 1, true) ~= nil, true)

    -- THE REPORTED BUG. Visibility was evaluated once at init and again only
    -- when identify_success arrived — and identify routinely completes BEFORE
    -- this component's init, so the event had already fired and the button
    -- never appeared.
    check("visibility is re-checked every frame", gui:find("function update(self)", 1, true) ~= nil, true)
    check("and the gui is only touched when the answer changes",
        gui:find("if show == self._shown", 1, true) ~= nil, true)

    -- THE CHOICE. Two different jobs behind one button.
    check("the button opens a menu, not a screen", gui:find("open_menu(self)", 1, true) ~= nil, true)
    check("with a chat option", gui:find('b.id == "open_chat"', 1, true) ~= nil, true)
    check("and an inbox option", gui:find('b.id == "open_inbox"', 1, true) ~= nil, true)
    check("and BACK returns to the choice", gui:find('b.id == "back"', 1, true) ~= nil, true)

    -- One flag, derived. Two that can disagree about whether a modal is up is
    -- how a screen ends up holding input focus with nothing on it.
    check("open is derived from view, never set on its own",
        gui:find("self.open = (view ~= nil)", 1, true) ~= nil, true)
    -- Assignments only. The other references are reads, which are fine —
    -- what must not exist is a second place that can put `open` and `view`
    -- out of step.
    check("and it is assigned in exactly one place",
        select(2, gui:gsub("self%.open%s*=", "")), 1)

    -- Keyboard events belong to the composer, which only the chat has.
    check("typing is ignored outside the chat", gui:find('self.view ~= "chat"', 1, true) ~= nil, true)

    -- The component is registered, or none of the above is on screen at all.
    local go = src("main/controller.go")
    check("the component exists in controller.go", go:find('id: "inbox"', 1, true) ~= nil, true)
    check("and points at the gui", go:find('/main/inbox.gui"', 1, true) ~= nil, true)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
