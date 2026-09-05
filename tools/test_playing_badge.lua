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
print("AND IT IS DRAWN AT THE FOOT OF THE LIST, NOT AS ANOTHER ROW")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "modules/online_center.lua"):read("a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

    -- THE SHAPE, pinned where it is read. This is the bug the count had for
    -- its whole first life: it is a sibling of `data`, and reading it off
    -- `data` is reading it off an array.
    local wsm = io.open(ROOT .. "modules/websocket_manager.lua"):read("a")
    ok("the count is read off the whole message, not off data",
        wsm:match("handle_online_users%(d, message%)") ~= nil)
    ok("...and the server really does send it beside data",
        wsm:find("envelope.playingCount", 1, true) ~= nil)

    ok("the list reads the count", code:find("ws.playing_count", 1, true) ~= nil)
    ok("...and says what it is", code:find('"PLAYING"', 1, true) ~= nil)
    ok("...only when there is somebody to report",
        code:match("if playing <= 0 then return nil end") ~= nil)

    -- IT IS ANCHORED TO THE LIST, NOT TO THE HEADER. The header is the label
    -- for what IS here; this is the figure for what is not.
    ok("it hangs off the bottom of the list",
        code:match("draw_playing_badge%(self, ctx, content_r, list_bottom%)") ~= nil)
    ok("...on both the full list and the empty one",
        select(2, code:gsub("draw_playing_badge%(self, ctx, content_r, list_bottom%)", "")) == 2,
        "an empty list with forty people mid-game is the case it earns its keep in")
    -- Its vertical anchor is the list's FOOT. It used to be `hcy + 16` — the
    -- header's own text baseline — which is what made it read as a second half
    -- of the header's label rather than as a figure about the rows.
    ok("its vertical anchor is the foot of the list, not the header",
        code:match("local cy = bottom %+ M%.BADGE_LIFT") ~= nil)
    ok("...and nothing in the badge knows what the header's y is",
        code:match("function M%.draw_playing_badge.-\nend"):find("hcy") == nil)

    -- A figure, not something to tap: it must never become a button, or it is
    -- a row again — the very thing the cap exists to avoid.
    ok("it is not a button", not code:match("draw_playing_badge.-mkbtn"))
    -- The pill is sized from what the labels MEASURED. Guessing from the digit
    -- count is how a badge clips "1,048" and swims around "7".
    ok("the pill is measured, not guessed",
        code:find("get_text_metrics_from_node", 1, true) ~= nil)
    ok("...and re-anchored when it is resized",
        code:match("gui%.set_size%(body.-gui%.set_position%(body") ~= nil,
        "a box grows about its centre, so resizing alone pushes it off the panel")
    -- The host has to tick the beat, or the dot is a still dot.
    local host = io.open(ROOT .. "main/online.gui_script"):read("a")
    ok("the host beats it once a frame",
        host:find("center_panel.pulse_playing(self, self.ui_clock)", 1, true) ~= nil)
end

----------------------------------------------------------------------
print("THE PILL FITS ITS OWN LABEL, RIGHT EDGE FIRST")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path
    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    _G.sys.get_config_string = function() return "" end
    _G.sys.get_config = function() return "" end
    _G.http = { request = function() end }

    local OC = require("modules.online_center")

    -- Laid out from the right edge inwards, so the pill grows leftwards and
    -- the edge the column above it is aligned on never moves.
    local a = OC.badge_layout(700, 100, 30, 60)
    check("the right edge is where it was put", a.right, 700)
    check("the label hugs it", a.label_x, 700 - OC.BADGE_PAD)
    check("the number sits inside the label", a.num_x,
        700 - OC.BADGE_PAD - 60 - OC.BADGE_GAP)
    check("and the pill wraps the lot", a.width,
        OC.BADGE_PAD * 2 + OC.BADGE_DOT + OC.BADGE_GAP * 2 + 30 + 60)

    -- A LONGER NUMBER GROWS THE PILL LEFTWARDS, and nothing else moves.
    local b = OC.badge_layout(700, 100, 52, 60)
    check("a wider number does not shift the label", b.label_x, a.label_x)
    check("...it pushes the left edge out instead", b.width, a.width + 22)
    ok("...and the right edge is still the right edge", b.right == a.right)
end

----------------------------------------------------------------------
print("AND WHAT ACTUALLY GETS DRAWN")
----------------------------------------------------------------------
do
    local ws = require("modules.websocket_manager")
    local ui = require("modules.ui")
    local OC = require("modules.online_center")

    -- A real render of the badge itself: the sim's gui nodes are tables, so
    -- every position and size the drawing sets can be read back. The layout
    -- checks above prove the arithmetic; this proves the arithmetic is the
    -- one the nodes are actually given.
    local drawn
    local ctx = {
        ui = ui,
        C = {
            COL_RED   = vmath.vector4(0.90, 0.25, 0.25, 1.0),
            COL_WHITE = vmath.vector4(1, 1, 1, 1),
        },
        commas = function(n) return tostring(n) end,
        track  = function(_, n) drawn[#drawn + 1] = n; return n end,
    }
    ctx.txtR = function(_, x, y, str, font, color)
        return ctx.track(nil, ui.text(vmath.vector3(x, y, 0), str, font, color))
    end

    local RIGHT, BOTTOM = 700, 200
    local function render(count)
        drawn = {}
        ws.playing_count = count
        local self_ = {}
        local body = OC.draw_playing_badge(self_, ctx, RIGHT, BOTTOM)
        return self_, body
    end

    -- NOBODY PLAYING SAYS NOTHING. A zero badge reads as a broken badge
    -- rather than as a quiet game.
    local quiet = render(0)
    check("a quiet lobby draws no badge at all", #drawn, 0)
    ok("...and parks no node for the beat to find", quiet.playing_dot_node == nil)

    local self_, body = render(104)
    ok("a busy one draws a pill", body ~= nil)
    -- body, two round caps, the dot, the number, the word.
    check("six pieces, no more", #drawn, 6)

    local cy = BOTTOM + OC.BADGE_LIFT + OC.BADGE_H / 2
    check("it sits above the foot of the list, not on it", body.pos.y, cy)
    ok("...clear of the last row", cy - OC.BADGE_H / 2 > BOTTOM)

    -- THE RIGHT EDGE IS THE PANEL'S RIGHT EDGE. This is the offset the rows
    -- and the stake figures above it already align on.
    local cap_r = drawn[3]
    check("the right cap is flush with the panel edge", cap_r.pos.x + OC.BADGE_H / 2, RIGHT)
    local cap_l = drawn[2]
    ok("and the body spans between the two caps",
        math.abs((body.pos.x - body.size.x / 2) - (cap_l.pos.x)) < 1e-6)

    -- NOTHING ESCAPES THE PILL. Every piece has to sit inside the ground it
    -- is drawn on, or the badge is a number with a bruise behind it.
    local left = cap_l.pos.x - OC.BADGE_H / 2
    for i, n in ipairs(drawn) do
        local half = (n.size and n.size.x or 0) / 2
        ok("piece " .. i .. " is inside the pill",
            n.pos.x - half >= left - 1e-6 and n.pos.x + half <= RIGHT + 1e-6)
        check("piece " .. i .. " is on the pill's line", n.pos.y, cy)
    end

    -- The word is outermost and the number sits inside it, which is what
    -- makes "104 PLAYING" read left to right at all.
    ok("the number comes before the word", drawn[5].pos.x < drawn[6].pos.x)
    ok("and the dot leads both", drawn[4].pos.x < drawn[5].pos.x)

    -- THE BEAT IS ARMED. Without this the host ticks nothing and the dot is a
    -- still dot — which is the whole animation, missing, silently.
    ok("the dot is parked for the host to beat", self_.playing_dot_node == drawn[4])
    local dot = self_.playing_dot_node
    OC.pulse_playing(self_, OC.BADGE_PULSE_PERIOD / 2)
    ok("and beating it swells the dot",
        math.abs(dot.scale.x - (1 + OC.BADGE_PULSE_SWELL)) < 1e-6)
    OC.pulse_playing(self_, 0)
    ok("...and lets it back down", math.abs(dot.scale.x - 1) < 1e-6)
    ok("...without ever changing its hue", dot.color.x == ctx.C.COL_RED.x)

    -- A pill that fits "7" must also fit "1,048" without clipping it.
    render(7)
    local narrow = drawn[1].size.x
    render(1048)
    ok("a longer number makes a longer pill", drawn[1].size.x > narrow)
    check("...and it still ends on the panel edge", drawn[3].pos.x + OC.BADGE_H / 2, RIGHT)

    ws.playing_count = 0
end

----------------------------------------------------------------------
print("AND IT BEATS")
----------------------------------------------------------------------
do
    local OC = require("modules.online_center")

    local k0, a0 = OC.badge_pulse(0)
    check("it starts at rest", k0, 1)
    check("...and at its dimmest", a0, 0.55)

    local kh = OC.badge_pulse(OC.BADGE_PULSE_PERIOD / 2)
    ok("half a beat in it is at full swell",
        math.abs(kh - (1 + OC.BADGE_PULSE_SWELL)) < 1e-9)

    -- A RAISED COSINE, so it leaves rest and returns to it with zero
    -- velocity. A triangle wave would tick at both ends of every beat.
    local eps = 1e-4
    local left  = OC.badge_pulse(OC.BADGE_PULSE_PERIOD - eps)
    local right = OC.badge_pulse(eps)
    ok("and it has no corner at the turn",
        math.abs(left - 1) < 1e-6 and math.abs(right - 1) < 1e-6)

    -- Whole periods land on the same value: the phase is read from the clock,
    -- never accumulated, so a rebuild mid-beat cannot shift it.
    local k1 = OC.badge_pulse(0.37)
    local k2 = OC.badge_pulse(0.37 + OC.BADGE_PULSE_PERIOD * 5)
    ok("the phase comes from the clock, not from a counter",
        math.abs(k1 - k2) < 1e-9)

    check("nonsense does not move it", OC.badge_pulse(nil), 1)
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
