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

    -- Exactly the frame broadcastOnlineUsers sends: the playable rows, and the
    -- count of everybody mid-game riding alongside them.
    SIM.server_send({ type = "ONLINE_USERS", data = {
        users = { { _id = "u1", username = "A" }, { _id = "u2", username = "B" } },
        playingCount = 104,
    } })
    SIM.pump(0.2)

    check("the count is what the server said", ws.playing_count, 104)
    -- The property that matters: it is NOT derivable from the list, because
    -- the players it counts are deliberately absent from it.
    check("...and not the number of rows", #ws.online_users, 2)

    -- A quiet lobby reports none rather than a stale figure.
    SIM.server_send({ type = "ONLINE_USERS", data = {
        users = { { _id = "u1", username = "A" } }, playingCount = 0,
    } })
    SIM.pump(0.2)
    check("a quiet lobby clears it", ws.playing_count, 0)

    -- An older server sends a bare array and no count at all. That must parse
    -- and simply report none, not break the list.
    SIM.server_send({ type = "ONLINE_USERS", data = {
        { _id = "u1", username = "A" }, { _id = "u2", username = "B" },
    } })
    SIM.pump(0.2)
    check("a server too old to send one still gives us a list", #ws.online_users, 2)
    check("...and reports nobody playing rather than nil", ws.playing_count, 0)

    -- Nonsense is none, not a badge reading "nan".
    SIM.server_send({ type = "ONLINE_USERS", data = { users = {}, playingCount = "many" } })
    SIM.pump(0.2)
    check("nonsense is nobody", ws.playing_count, 0)

    SIM.server_send({ type = "ONLINE_USERS", data = { users = {}, playingCount = -5 } })
    SIM.pump(0.2)
    check("and a negative count is never drawn", ws.playing_count, 0)
end

----------------------------------------------------------------------
print("AND IT IS DRAWN OVER THE HEADER, NOT AS ANOTHER ROW")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "modules/online_center.lua"):read("a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

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
