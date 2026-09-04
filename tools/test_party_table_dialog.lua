-- THE TABLE IS FOUR CHAIRS, AND YOU CAN SEE THE EMPTY ONES.
--
--   Run: lua5.3 tools/test_party_table_dialog.lua
--
-- A party used to be drawn by dialog_search — the ring, the reel and the
-- shortlist rail a tournament search uses — because the two look alike from
-- the player's side: you opened something and you are watching people arrive.
--
-- They are not alike. A search rail holds CANDIDATES, out of whom the server
-- picks one; that is why the reel goes on hunting beside them. A party's seats
-- are neither — the table is four chairs, known from the moment it opens, and
-- everybody on them is already in. And the thing a player actually wants to
-- know, how many chairs are LEFT, is the one thing a rail that only draws
-- arrivals cannot show.
--
-- It was also drawn by the ONLINE SCREEN, so it only existed there: joining
-- from the lobby got you a line of text and a board some seconds later.
--
-- Both are the same fix — the table moved to the incoming overlay, which is
-- global and already carries every other invite. Pinned here:
--
--   1. every chair is drawn, the empty ones included, and the count comes
--      from the SERVER rather than from a PARTY_SIZE this side made up
--   2. the clock is the table's, it does not restart when a chair fills, and
--      zero waits for the server instead of declaring failure
--   3. a challenge cannot cover the table, and a clear meant for one cannot
--      take it down
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

----------------------------------------------------------------------
print("EVERY SEAT IS DRAWN - THE FULL ONES AND THE EMPTY ONES")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path

    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()

    local ws = require("modules.websocket_manager")
    ws.current_user_id = "me"

    local party_dialog = require("modules.dialog_party")

    -- A recording ctx, the same shape incoming.gui_script's make_ctx hands
    -- dialog_incoming. Every string that reaches the screen is collected, so
    -- what is asserted is what a player would actually read.
    local said, buttons
    local function ctx()
        said, buttons = {}, {}
        local COL = vmath.vector4(1, 1, 1, 1)
        local node = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end
        return {
            C = { COL_DIM = COL, COL_MID = COL, COL_GOLD = COL, COL_WHITE = COL,
                  COL_GREEN = COL, COL_RED = COL, COL_CYAN = COL },
            ui = {
                box = node, btn9 = node, avatar = node, grad_backdrop = node,
                pie = function() return gui.new_pie_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                text = function(_, str) said[#said + 1] = tostring(str)
                                        return gui.new_text_node(vmath.vector3(0,0,0), tostring(str)) end,
            },
            track = function(self, n) self.nodes[#self.nodes + 1] = n; return n end,
            mkbtn = function(self, id) buttons[#buttons + 1] = id
                                       self.buttons[#self.buttons + 1] = { id = id } end,
            commas = function(n) return tostring(n) end,
            with_a = function(c) return c end,
            dlg_avatar = function() end,
            CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
            DLG_RED = vmath.vector4(1,0,0,1), DLG_SEARCH = vmath.vector4(1,1,0,1),
        }
    end

    local function count(word)
        local n = 0
        for _, s in ipairs(said) do if s:find(word, 1, true) then n = n + 1 end end
        return n
    end

    -- Exactly what partyView puts on the wire.
    local function wire(over)
        local d = {
            partyId = "P1", hostId = "host", entry = 200, mode = "NORMAL",
            status = "FILLING", seatsRemaining = 2, closesAt = 0,
            seats = {
                { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
                { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
            },
        }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end

    local function draw(d, secs)
        local surface = { nodes = {}, buttons = {} }
        local drew = pcall(party_dialog.draw, surface, ctx(),
            { party_view = party_dialog.view(d), time_left = secs }, 1)
        return drew
    end

    local view = party_dialog.view(wire())
    check("the table's size is the server's two numbers, not our constant", view.size, 4)

    ok("the table draws", draw(wire(), 14))
    check("one placeholder per empty chair", count("WAITING"), 2)
    check("the host is named as the host", count("HOST"), 1)
    ok("our own chair says YOU", count("YOU") >= 1)
    ok("the other player is named", count("VORTEX") >= 1)
    ok("how many seats are left is said in words", count("2 seats left") >= 1)
    ok("leaving is the one thing offered", buttons[#buttons] == "party_leave")
    ok("and it does not pretend the entry comes back", count("stays with the table") >= 1)
    -- The pot is what has been PAID IN: two seats at 200 is 400, never 800.
    ok("the pot counts filled seats only", count("400 POT") >= 1)

    -- One short of full: one placeholder, and the singular.
    draw(wire({ seatsRemaining = 1, seats = {
        { userId = "host", username = "Vortex", joinedAt = 1 },
        { userId = "me",   username = "Me",     joinedAt = 2 },
        { userId = "x",    username = "Akira",  joinedAt = 3 },
    } }), 6)
    check("one chair left, one placeholder", count("WAITING"), 1)
    ok("and it is said in the singular", count("1 seat left") >= 1)

    -- Full: no placeholders at all.
    draw(wire({ seatsRemaining = 0, seats = {
        { userId = "host", username = "Vortex", joinedAt = 1 },
        { userId = "me",   username = "Me",     joinedAt = 2 },
        { userId = "x",    username = "Akira",  joinedAt = 3 },
        { userId = "y",    username = "Drago",  joinedAt = 4 },
    } }), 2)
    check("a full table has no empty chairs", count("WAITING"), 0)

    -- A SIZE THIS SIDE DOES NOT KNOW. If the server ever runs a six-seat
    -- table, the chairs come from its numbers and not from a four written
    -- down here.
    draw(wire({ seatsRemaining = 4 }), 10)
    check("six seats draw four placeholders", count("WAITING"), 4)

    -- STARTING: nothing left to leave.
    draw(wire({ status = "STARTING" }), 0)
    check("a starting table offers no way out", count("LEAVE"), 0)

    -- Zero while still FILLING is the server's decision point, not a failure.
    draw(wire({ seatsRemaining = 1 }), 0)
    check("zero seconds never reads as nobody came", count("Closing the table"), 1)

    -- How the table is WON is on screen: a capped party and a normal one are
    -- different games and the seated players are about to play one of them.
    draw(wire({ mode = "SCORECAP", scoreCap = 250 }), 9)
    ok("a capped table says so", count("CAP 250") >= 1)
    draw(wire(), 9)
    ok("and a normal one says what it is too", count("PLAY IT OUT") >= 1)
end

----------------------------------------------------------------------
print("THE TABLE OPENS, REFILLS AND CLOSES ON THE SERVER'S OWN MESSAGES")
----------------------------------------------------------------------
local function boot()
    for name in pairs(package.loaded) do
        if name:match("^modules%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path

    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    _G.window.set_listener = function() end
    _G.window.set_dim_mode = function() end
    _G.window.DIMMING_OFF = 0
    _G.window.WINDOW_EVENT_FOCUS_GAINED = 1
    _G.window.WINDOW_EVENT_FOCUS_LOST = 2
    _G.sys.get_config_string = function() return "" end
    _G.sys.get_config = function() return "" end
    _G.http = { request = function() end }

    for _, id in ipairs({ "lobby", "auth", "online", "themes", "payments", "profile",
                          "team_tournament", "standings", "game", "game_logic", "coins",
                          "signup_bonus", "daily_bonus", "network", "gameover",
                          "update_required", "toast", "announcement", "season_results",
                          "tutorial", "suit_select", "card_factory", "snd_coin",
                          "snd_suspense", "snd_fail", "snd_notify", "snd_found",
                          "tournaments" }) do
        SIM.add_recorder(id)
    end
    SIM.load_script_component("controller", ROOT .. "main/controller.script")
    SIM.init_component("controller")
    SIM.load_script_component("incoming", ROOT .. "main/incoming.gui_script")
    SIM.init_component("incoming")
    SIM.pump(0.2)

    local ws = require("modules.websocket_manager")
    ws.connect()
    SIM.pump(0.5)

    return SIM, ws, SIM.components.incoming.self, require("modules.app_state")
end

local function roster(SIM, remaining, seats, closes_in_s, status)
    local now_ms = (socket.gettime() * 1000)
    SIM.server_send({
        type = status == "STARTING" and "PARTY_STARTING" or "PARTY_ROSTER",
        data = {
            partyId = "P1", hostId = "host", entry = 200, mode = "NORMAL",
            status = status or "FILLING", seatsRemaining = remaining,
            closesAt = now_ms + (closes_in_s * 1000), seats = seats,
        },
    })
    SIM.pump(0.1)
end

local TWO = {
    { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
    { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
}
local THREE = {
    { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
    { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
    { userId = "x",    username = "Akira",  avatar = 2, joinedAt = 3 },
}

do
    local SIM, ws, S, app_state = boot()

    roster(SIM, 2, TWO, 14)

    ok("the table is on screen", S.dialog ~= nil and S.dialog.party_table == true)
    check("as a full dialog, never the strip", S.dialog.banner, false)
    check("counting down to the server's deadline", math.floor(S.dialog.time_left + 0.5), 14)
    -- The seat flag is not the offer flag: an offer strip is closed as soon as
    -- its table leaves the listing, which is the instant it fills.
    ok("and it does not wear the offer strip's flag", not S.dialog.party)
    ok("it holds the app's input like a challenge does", app_state.input_blocked())

    -- A chair fills. The clock keeps going.
    SIM.pump(3.0)
    local before = S.dialog.time_left
    roster(SIM, 1, THREE, 11)
    check("the chair filled", #S.dialog.party_view.seats, 3)
    ok("and the clock did not go back to the top", S.dialog.time_left <= before + 0.2)

    -- A challenge that crossed the join on the wire.
    SIM.server_send({ type = "GAME_REQUEST", data = {
        requestId = "LATE", user = { _id = "rival", username = "Rival", avatar = 4 },
        stake = { amount = 500 }, gameType = "NORMAL",
    } })
    SIM.pump(0.2)
    ok("a late challenge never covers the table", S.dialog.party_table == true)
    check("and nothing on screen offers to accept it", S.dialog.request_id, nil)

    -- Nor does clearing one take the table down with it.
    SIM.server_send({ type = "GAME_REQUEST_CANCELLED", data = { requestId = "LATE" } })
    SIM.pump(0.2)
    ok("clearing that challenge leaves the table up", S.dialog and S.dialog.party_table == true)

    -- Zero is the server's decision point, not ours.
    SIM.pump(12.0)
    ok("the table waits at zero to be told what happened", S.dialog ~= nil)
    check("with the clock floored, not negative", S.dialog.time_left, 0)

    SIM.server_send({ type = "PARTY_CANCELLED", data = {
        partyId = "P1", reason = "not enough players", refunded = 0,
        message = "A party needs at least 2 players. This table did not fill.",
    } })
    SIM.pump(0.2)
    check("and it closes when it is", S.dialog, nil)
    ok("releasing the app's input with it", not app_state.input_blocked())

    -- THE CONTROL. The same challenge, with no table up, is still shown —
    -- otherwise every assertion above passes for the wrong reason.
    SIM.server_send({ type = "GAME_REQUEST", data = {
        requestId = "ORDINARY", user = { _id = "rival", username = "Rival", avatar = 4 },
        stake = { amount = 500 }, gameType = "NORMAL",
    } })
    SIM.pump(0.2)
    check("with no table up, a challenge is shown as usual",
        S.dialog and S.dialog.request_id, "ORDINARY")
end

do
    -- A SOCKET THAT DIES WITH A TABLE OPEN must not leave a modal nothing can
    -- close: a table has no Cancel, because the entry is committed on the seat.
    local SIM, ws, S, app_state = boot()
    roster(SIM, 2, TWO, 4)
    ok("the table is up", S.dialog ~= nil and S.dialog.party_table == true)
    -- Past the deadline and past the grace, with the server never speaking.
    SIM.pump(20.0)
    check("the table gives up rather than trapping the player", S.dialog, nil)
    ok("and the app takes input again", not app_state.input_blocked())
end

do
    -- The other ending. PARTY_STARTING carries the same payload shape, and the
    -- board takes over from here.
    local SIM, ws, S, app_state = boot()
    roster(SIM, 2, TWO, 14)
    roster(SIM, 2, TWO, 0, "STARTING")
    check("a starting table leaves this surface", S.dialog, nil)
    ok("and does not leave the app input-dead", not app_state.input_blocked())
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
