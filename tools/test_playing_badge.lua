-- THE PLAYERS THE LIST LEAVES OUT ARE STILL WORTH A NUMBER.
--
--   Run: lua5.3 tools/test_playing_badge.lua
--
-- The lobby list is capped at thirty and carries PLAYABLE opponents only.
-- Somebody already in a game cannot be challenged, so a row for them is a row
-- pushing a playable opponent off the screen — they are left out on purpose,
-- and the server sends a count instead (playingCount, since LOBBY_LIST_MAX).
-- Four bytes for a figure that would otherwise be a hundred rows the client
-- draws and nobody can tap.
--
-- Nothing on this side read it. So a lobby with a hundred people in it showed
-- "AVAILABLE PLAYERS" and six rows, which reads as an empty game rather than a
-- busy one: the count is the whole difference between the two, and it is
-- exactly the number the cap makes invisible.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

----------------------------------------------------------------------
print("THE COUNT IS READ OFF THE FRAME, NOT COUNTED FROM THE ROWS")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path

    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    _G.window.set_listener = function() end
    _G.window.set_dim_mode = function() end
    _G.window.DIMMING_OFF = 0
    _G.sys.get_config_string = function() return "" end
    _G.sys.get_config = function() return "" end
    _G.http = { request = function() end }

    local ws = require("modules.websocket_manager")
    SIM.add_recorder("controller")
    ws.connect()
    SIM.pump(0.3)

    check("nothing has been said yet", ws.playing_count, 0)

    -- EXACTLY THE FRAME broadcastOnlineUsers SENDS, and the shape is the whole
    -- point: `data` is the user ARRAY, and playingCount sits BESIDE it, not
    -- inside it. The server says so in as many words — "A SIBLING FIELD, NOT A
    -- CHANGE TO `data`" — because an older client that only reads `data` had
    -- to keep working on the day the list was capped.
    --
    -- This test used to send { data = { users = ..., playingCount = ... } },
    -- which is a shape nothing produces. It passed, and the badge still never
    -- drew: the client was reading the count off an array, where it is nil
    -- forever. A fixture invented to match the code proves only that the code
    -- matches itself.
    local function frame(users, playing)
        return { type = "ONLINE_USERS", data = users, playingCount = playing }
    end

    SIM.server_send(frame({ { _id = "u1", username = "A" }, { _id = "u2", username = "B" } }, 104))
    SIM.pump(0.2)

    check("the count is what the server said", ws.playing_count, 104)
    -- The property that matters: it is NOT derivable from the list, because
    -- the players it counts are deliberately absent from it.
    check("...and not the number of rows", #ws.online_users, 2)

    -- A quiet lobby reports none rather than a stale figure.
    SIM.server_send(frame({ { _id = "u1", username = "A" } }, 0))
    SIM.pump(0.2)
    check("a quiet lobby clears it", ws.playing_count, 0)

    -- Back to a busy lobby, so the checks below cannot pass on a stale zero.
    SIM.server_send(frame({ { _id = "u1", username = "A" } }, 7))
    SIM.pump(0.2)
    check("and it comes back", ws.playing_count, 7)

    -- An older server sends a bare array and no count at all. That must parse
    -- and simply report none, not break the list.
    SIM.server_send({ type = "ONLINE_USERS", data = {
        { _id = "u1", username = "A" }, { _id = "u2", username = "B" },
    } })
    SIM.pump(0.2)
    check("a server too old to send one still gives us a list", #ws.online_users, 2)
    check("...and reports nobody playing rather than nil", ws.playing_count, 0)

    -- Nonsense is none, not a badge reading "nan".
    SIM.server_send(frame({}, "many"))
    SIM.pump(0.2)
    check("nonsense is nobody", ws.playing_count, 0)

    SIM.server_send(frame({}, -5))
    SIM.pump(0.2)
    check("and a negative count is never drawn", ws.playing_count, 0)

    -- A server that DID nest it would still be read, so the fallback is not
    -- dead code — but the envelope is where the real one lives.
    SIM.server_send({ type = "ONLINE_USERS",
        data = { users = { { _id = "u1" } }, playingCount = 12 } })
    SIM.pump(0.2)
    check("a nested count is still understood", ws.playing_count, 12)
end

----------------------------------------------------------------------
print("AND IT IS DRAWN OVER THE HEADER, NOT AS ANOTHER ROW")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "modules/online_center.lua"):read("a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

    -- THE SHAPE, pinned where it is read. This is the bug: the count is a
    -- sibling of `data`, and reading it off `data` is reading it off an array.
    local wsm = io.open(ROOT .. "modules/websocket_manager.lua"):read("a")
    ok("the count is read off the whole message, not off data",
        wsm:match("handle_online_users%(d, message%)") ~= nil)
    ok("...and the server really does send it beside data",
        wsm:find("envelope.playingCount", 1, true) ~= nil)

    ok("the list header reads the count", code:find("ws.playing_count", 1, true) ~= nil)
    ok("...and says what it is", code:find('" PLAYING"', 1, true) ~= nil)
    ok("...only when there is somebody to report",
        code:match("if playing > 0 then") ~= nil)
    -- A figure, not something to tap: it must never become a button, or it is
    -- a row again — the very thing the cap exists to avoid.
    ok("it is not a button", code:match("if playing > 0 then.-end") and
        not code:match("if playing > 0 then.-mkbtn"))
    -- The pill is sized from what the label MEASURED. Guessing from the digit
    -- count is how a badge clips "104" and swims around "7".
    ok("the pill is measured, not guessed",
        code:find("get_text_metrics_from_node", 1, true) ~= nil)
    ok("...and re-anchored when it is resized",
        code:match("gui%.set_size%(pill.-gui%.set_position%(pill") ~= nil,
        "a box grows about its centre, so resizing alone pushes it off the panel")
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
