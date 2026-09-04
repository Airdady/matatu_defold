-- THE PARTY TABLE, ON THE INCOMING DIALOG'S SURFACE.
--
--   Run: lua tools/test_party_table.lua
--
-- Three things are pinned here, and they are the three the feature is made of.
--
-- ONE. EVERY CHAIR IS DRAWN, including the empty ones. A table that only shows
-- the players already in it cannot show you it is still filling — the whole
-- point of a twenty-second window is that you watch it happen. So a seat
-- nobody has taken is a placeholder in the position it will be taken in, and
-- the number of them comes from the SERVER's seatsRemaining, never from a
-- table size this side made up.
--
-- TWO. THE CLOCK DOES NOT RESTART WHEN SOMEBODY SITS DOWN. A roster arrives on
-- every seat change and the dialog is rebuilt from it; a countdown reset by
-- each arrival is a table that never closes.
--
-- THREE. A SEATED PLAYER IS NOT TAKING CHALLENGES. The backend sweeps every
-- request in flight when the seat is taken and refuses new ones after, so a
-- GAME_REQUEST reaching this screen has crossed the join on the wire. It must
-- not put an ACCEPT button over a table that has already been paid for.
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
-- 1. THE DRAWING: chairs filled and chairs empty
----------------------------------------------------------------------
print("EVERY SEAT IS DRAWN - THE FULL ONES AND THE EMPTY ONES")

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
    -- what the test asserts is what a player would actually read.
    local said, buttons
    local function ctx()
        said, buttons = {}, {}
        local COL = vmath.vector4(1, 1, 1, 1)
        return {
            C = { COL_DIM = COL, COL_MID = COL, COL_GOLD = COL, COL_WHITE = COL,
                  COL_GREEN = COL, COL_RED = COL, COL_CYAN = COL },
            ui = {
                box  = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                pie  = function() return gui.new_pie_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                text = function(_, s) said[#said + 1] = tostring(s)
                                      return gui.new_text_node(vmath.vector3(0,0,0), tostring(s)) end,
                avatar = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                grad_backdrop = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                btn9 = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
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

    local function count(list, word)
        local n = 0
        for _, s in ipairs(list) do if s:find(word, 1, true) then n = n + 1 end end
        return n
    end

    -- A table of four with two people at it: two names, two placeholders.
    local two_of_four = ws.parse_party({
        partyId = "P1", hostId = "host", entry = 200, mode = "NORMAL",
        status = "FILLING", seatsRemaining = 2, remainingMs = 14000,
        seats = {
            { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
            { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
        },
    })

    check("the table's size is read from the server, not assumed", two_of_four.size, 4)

    local surface = { nodes = {}, buttons = {} }
    ok("the table draws", pcall(party_dialog.draw, surface, ctx(), { party = two_of_four, time_left = 14 }, 1))
    check("one placeholder per empty chair", count(said, "WAITING"), 2)
    check("the host is named as the host", count(said, "HOST"), 1)
    ok("our own chair says YOU", count(said, "YOU") >= 1)
    ok("the other player is named", count(said, "VORTEX") >= 1)
    ok("how many seats are left is said in words", count(said, "2 seats left") >= 1)
    ok("leaving is the one thing offered", buttons[#buttons] == "party_leave")
    -- Not a refund, and it is said where the player is about to act on it.
    ok("and it does not pretend the entry comes back", count(said, "stays with the table") >= 1)

    -- The pot is what has been PAID IN. Two seats at 200 is 400, never 800.
    ok("the pot counts filled seats only", count(said, "400 POT") >= 1)

    -- One short of full: exactly one placeholder, and singular.
    local three = ws.parse_party({
        partyId = "P1", hostId = "host", entry = 200, status = "FILLING",
        seatsRemaining = 1, remainingMs = 6000,
        seats = {
            { userId = "host", username = "Vortex", joinedAt = 1 },
            { userId = "me",   username = "Me",     joinedAt = 2 },
            { userId = "x",    username = "Akira",  joinedAt = 3 },
        },
    })
    surface = { nodes = {}, buttons = {} }
    pcall(party_dialog.draw, surface, ctx(), { party = three, time_left = 6 }, 1)
    check("one chair left, one placeholder", count(said, "WAITING"), 1)
    ok("and it is said in the singular", count(said, "1 seat left") >= 1)

    -- Full. No placeholders at all, and nothing left to wait for.
    local full = ws.parse_party({
        partyId = "P1", hostId = "host", entry = 200, status = "FILLING",
        seatsRemaining = 0, remainingMs = 2000,
        seats = {
            { userId = "host", username = "Vortex", joinedAt = 1 },
            { userId = "me",   username = "Me",     joinedAt = 2 },
            { userId = "x",    username = "Akira",  joinedAt = 3 },
            { userId = "y",    username = "Drago",  joinedAt = 4 },
        },
    })
    surface = { nodes = {}, buttons = {} }
    pcall(party_dialog.draw, surface, ctx(), { party = full, time_left = 2 }, 1)
    check("a full table has no empty chairs", count(said, "WAITING"), 0)

    -- STARTING. There is nothing left to leave, so the button goes.
    local starting = ws.parse_party({
        partyId = "P1", hostId = "host", entry = 200, status = "STARTING",
        seatsRemaining = 1, remainingMs = 0,
        seats = {
            { userId = "host", username = "Vortex", joinedAt = 1 },
            { userId = "me",   username = "Me",     joinedAt = 2 },
            { userId = "x",    username = "Akira",  joinedAt = 3 },
        },
    })
    surface = { nodes = {}, buttons = {} }
    pcall(party_dialog.draw, surface, ctx(), { party = starting, time_left = 0 }, 1)
    check("a starting table offers no way out", count(said, "LEAVE"), 0)

    -- Zero on the clock while still FILLING is not a failure: the server
    -- decides the table at zero and says so a moment later.
    surface = { nodes = {}, buttons = {} }
    pcall(party_dialog.draw, surface, ctx(), { party = three, time_left = 0 }, 1)
    check("zero seconds never reads as nobody came", count(said, "Closing the table"), 1)
end

----------------------------------------------------------------------
-- 2. THE LIFECYCLE, driven by real frames down a real socket
----------------------------------------------------------------------
print("THE TABLE OPENS, REFILLS AND CLOSES ON THE SERVER'S OWN MESSAGES")

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
                          "snd_suspense", "snd_fail", "snd_notify", "tournaments" }) do
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

local function roster(SIM, seats_remaining, seats, remaining_ms, status)
    SIM.server_send({
        type = status == "STARTING" and "PARTY_STARTING" or "PARTY_ROSTER",
        data = {
            partyId = "P1", hostId = "host", entry = 200, mode = "NORMAL",
            status = status or "FILLING", seatsRemaining = seats_remaining,
            remainingMs = remaining_ms, closesAt = 0, seats = seats,
        },
    })
    SIM.pump(0.1)
end

do
    local SIM, ws, S, app_state = boot()

    roster(SIM, 2, {
        { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
        { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
    }, 14000)

    ok("the table is on screen", S.dialog ~= nil and S.dialog.party ~= nil)
    check("as a full dialog, never the strip", S.dialog.banner, false)
    check("with the server's own remaining time", math.floor(S.dialog.time_left + 0.5), 14)
    -- A challenge and a party table are the same modal claim, so the app is
    -- not left accepting taps meant for the table.
    ok("and it holds the app's input like a challenge does", app_state.input_blocked())

    -- Somebody sits down. The chair fills; the clock keeps going.
    SIM.pump(3.0)
    local before = S.dialog.time_left
    roster(SIM, 1, {
        { userId = "host", username = "Vortex", avatar = 3, joinedAt = 1 },
        { userId = "me",   username = "Me",     avatar = 1, joinedAt = 2 },
        { userId = "x",    username = "Akira",  avatar = 2, joinedAt = 3 },
    }, 11000)

    check("the chair filled", #S.dialog.party.seats, 3)
    ok("and the clock did not go back to the top", S.dialog.time_left <= before + 0.2)

    -- A challenge that crossed the join on the wire.
    SIM.server_send({ type = "GAME_REQUEST", data = {
        requestId = "LATE", user = { _id = "rival", username = "Rival", avatar = 4 },
        stake = { amount = 500 }, gameType = "NORMAL",
    } })
    SIM.pump(0.2)
    ok("a late challenge never covers the table", S.dialog.party ~= nil)
    check("and nothing on screen offers to accept it", S.dialog.request_id, nil)

    -- Nor does the clearing of one take the table down with it.
    SIM.server_send({ type = "GAME_REQUEST_CANCELLED", data = { requestId = "LATE" } })
    SIM.pump(0.2)
    ok("clearing that challenge leaves the table up", S.dialog ~= nil and S.dialog.party ~= nil)

    -- Zero is the server's decision point, not ours.
    SIM.pump(15.0)
    ok("the table waits at zero to be told what happened", S.dialog ~= nil and S.dialog.party ~= nil)
    check("with the clock floored, not negative", S.dialog.time_left, 0)

    SIM.server_send({ type = "PARTY_CANCELLED", data = {
        partyId = "P1", reason = "not enough players", refunded = 0,
        message = "A party needs at least 2 players. This table did not fill.",
    } })
    SIM.pump(0.2)
    check("and it closes when it is", S.dialog, nil)
    ok("releasing the app's input with it", not app_state.input_blocked())

    -- THE CONTROL. The same challenge, with no table up, must still be shown —
    -- otherwise every assertion above passes for the wrong reason.
    SIM.server_send({ type = "GAME_REQUEST", data = {
        requestId = "ORDINARY", user = { _id = "rival", username = "Rival", avatar = 4 },
        stake = { amount = 500 }, gameType = "NORMAL",
    } })
    SIM.pump(0.2)
    check("with no table up, a challenge is shown as usual", S.dialog and S.dialog.request_id, "ORDINARY")
end

do
    -- The other ending. STARTING carries the same payload shape, so it must be
    -- understood by the same parser rather than by a second one.
    local SIM, ws, S, app_state = boot()
    roster(SIM, 2, {
        { userId = "host", username = "Vortex", joinedAt = 1 },
        { userId = "me",   username = "Me",     joinedAt = 2 },
    }, 14000)
    roster(SIM, 2, {
        { userId = "host", username = "Vortex", joinedAt = 1 },
        { userId = "me",   username = "Me",     joinedAt = 2 },
    }, 0, "STARTING")
    check("a starting table hands over and leaves the screen", S.dialog, nil)
    ok("and does not leave the app input-dead", not app_state.input_blocked())
end

----------------------------------------------------------------------
-- 3. THE SOCKET SPEAKS THE PARTY PROTOCOL
----------------------------------------------------------------------
print("THE CLIENT CAN OPEN, JOIN AND LEAVE A TABLE")

do
    local SIM, ws = boot()

    ws.create_party({ entry = 200, mode = "SCORECAP", score_cap = 250 })
    ws.join_party("P9")
    ws.leave_party("P9")
    SIM.pump(0.2)

    local function frame_of(t)
        for _, f in ipairs(SIM.outbound) do if f.type == t then return f end end
        return nil
    end

    local created = frame_of("PARTY_CREATE")
    ok("PARTY_CREATE goes out", created ~= nil)
    check("carrying the entry the host picked", created and created.data.entry, 200)
    check("and how the table is won", created and created.data.mode, "SCORECAP")
    check("with the cap that mode needs", created and created.data.scoreCap, 250)

    local joined = frame_of("PARTY_JOIN")
    ok("PARTY_JOIN goes out", joined ~= nil)
    check("naming the table", joined and joined.data.partyId, "P9")

    local left = frame_of("PARTY_LEAVE")
    ok("PARTY_LEAVE goes out", left ~= nil)
    check("naming the table too", left and left.data.partyId, "P9")
end

----------------------------------------------------------------------
-- 4. A SEATED PLAYER IS NOT OFFERED IN THE LOBBY EITHER
----------------------------------------------------------------------
print("A PLAYER AT A TABLE READS AS BUSY, NOT AS AVAILABLE")

do
    for name in pairs(package.loaded) do
        if name:match("^modules%%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path
    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()

    local sort = require("modules.player_sort")

    -- The flag the server now sends beside inGameWith (broadcastOnlineUsers).
    ok("a seated player counts as busy", sort.is_playing({ _id = "a", inParty = true }))
    ok("a player mid-game still does", sort.is_playing({ _id = "b", gameId = "g1" }))
    ok("and an idle one still does not", not sort.is_playing({ _id = "c" }))
    ok("nor does one whose game id is empty", not sort.is_playing({ _id = "d", gameId = "" }))

    -- The lobby row itself: no challenge button, because the server would
    -- refuse the request anyway.
    local src = io.open(ROOT .. "modules/online_center.lua"):read("a")
    ok("the lobby row reads the same flag", src:find("pu.inParty", 1, true) ~= nil)
    ok("and says which kind of busy it is", src:find("AT A TABLE", 1, true) ~= nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
