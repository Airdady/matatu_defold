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
    -- Text nodes are collected as NODES, not as the strings they were born
    -- with: draw() creates the countdown and the pot empty and animate() fills
    -- them in, so a list captured at creation time would miss exactly the two
    -- lines that move.
    local said, buttons
    local function ctx()
        said, buttons = {}, {}
        local COL = vmath.vector4(1, 1, 1, 1)
        local node = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end
        return {
            C = { COL_DIM = COL, COL_MID = COL, COL_GOLD = COL, COL_WHITE = COL,
                  COL_GREEN = COL, COL_RED = COL, COL_CYAN = COL },
            ui = {
                box = node, btn9 = node, avatar = node, grad_backdrop = node, image = node,
                coin_pot = require("modules.ui").coin_pot,
                pie = function() return gui.new_pie_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                text = function(_, str)
                    local n = gui.new_text_node(vmath.vector3(0,0,0), tostring(str))
                    said[#said + 1] = n
                    return n
                end,
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
        for _, node in ipairs(said) do
            local t = gui.get_text(node) or ""
            if t:find(word, 1, true) then n = n + 1 end
        end
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

    -- draw() paints the static half; animate() owns the words, so the test
    -- drives both exactly as the overlay's update() does.
    local last_surface
    local function draw(d, secs, over)
        local surface = { nodes = {}, buttons = {} }
        local rec = { party_view = party_dialog.view(d), time_left = secs }
        for k, v in pairs(over or {}) do rec[k] = v end
        local drew = pcall(party_dialog.draw, surface, ctx(), rec, 1)
        last_surface, last_rec = surface, rec
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
    -- NOTHING TO PRESS, AND THAT IS THE DESIGN. A seat is paid for the instant
    -- it is taken and leaving forfeits the entry, so a LEAVE button is a
    -- control whose only function is to take a player's money and give nothing
    -- back — one tap from a table that was about to deal. The table is
    -- resolved by the server: it fills and starts, or the window closes on too
    -- few players and it is called off.
    check("the table offers no button at all", #buttons, 0)
    ok("...and never says anything about leaving", count("LEAVE") == 0)
    ok("...nor about an entry staying behind", count("stays with the table") == 0)
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

    -- STARTING: the reel stops hunting. There is no next chair to fill.
    draw(wire({ status = "STARTING" }), 0)
    ok("a starting table stops hunting for the next player",
        last_surface.party_anim.chairs[3] == nil
        or last_surface.party_anim.chairs[3].reel == nil)

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
print("ONE REEL, ON THE CHAIR THAT IS NEXT TO FILL")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path
    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    local ws = require("modules.websocket_manager"); ws.current_user_id = "me"
    local dp = require("modules.dialog_party")

    -- WHERE THE REEL STANDS is the whole idea: the thing that is moving is
    -- also the thing about to change, so the player is already looking at the
    -- right chair when somebody lands in it.
    local function view(filled, size)
        local seats = {}
        for i = 1, filled do
            seats[i] = { userId = "u" .. i, username = "P" .. i, avatar = i, joinedAt = i }
        end
        return dp.view({ partyId = "P1", hostId = "u1", entry = 200, status = "FILLING",
                         seats = seats, seatsRemaining = size - filled })
    end

    check("the reel stands in the first empty chair", dp.next_empty(view(2, 4)), 3)
    check("...and moves on as they fill", dp.next_empty(view(3, 4)), 4)
    check("a full table has no reel at all", dp.next_empty(view(4, 4)), nil)
    check("a table with only the host has it in the second chair", dp.next_empty(view(1, 4)), 2)

    -- SAME CADENCE AND SAME POOL as the search dialog's reel. A player who has
    -- watched one search has already learned what a hunting reel means; a
    -- party spinning at a different rate reads as a different thing.
    local ONLINE = io.open(ROOT .. "main/online.gui_script"):read("a")
    ok("the reel hunts at the rate the search reel does",
        ONLINE:find("sr%.spin_t >= 0%.07") ~= nil and dp.REEL_STEP == 0.07)
    ok("...out of the same pool of avatars",
        ONLINE:find("math%.random%(60%)", 1, false) ~= nil and dp.REEL_AVATARS == 60)

    -- THE POT IS WHAT HAS BEEN PAID IN, and it grows with the seats: 200 a
    -- head means 200 alone, 400 with two, 600 on the third.
    check("one seat", dp.pot_of(view(1, 4)), 200)
    check("two seats", dp.pot_of(view(2, 4)), 400)
    check("three seats", dp.pot_of(view(3, 4)), 600)
    check("four seats", dp.pot_of(view(4, 4)), 800)
    -- Never entry times the table SIZE. That would promise a four-way prize
    -- out of money nobody has put in — and would then have to count DOWN if
    -- the table started short, which is not a thing a pot should be seen doing.
    ok("...never the table's size", dp.pot_of(view(2, 4)) ~= 200 * 4)

    -- THE REAL COIN POT, out of the atlas every other surface draws it from.
    --
    -- This was ui.image(..., "coins"), which sets the "ui" atlas and asks it
    -- for an animation called "coins" that does not exist there. Every
    -- play_flipbook in this codebase is wrapped in pcall, so the miss was
    -- silent and the pot was drawn as an untextured box.
    local uilib = require("modules.ui")
    check("the party pot reads the one ladder", dp.bundle_for, uilib.coin_pot_image)
    check("the bundle steps up with the pot", dp.bundle_for(600), "500")
    check("...and again at the next tier", dp.bundle_for(1000), "1000")
    check("a lone host's entry is the bottom rung", dp.bundle_for(200), "200")
    check("...and anything under it is still a pot", dp.bundle_for(50), "100")

    -- ONE LADDER, not five. It was written out in the board HUD, both request
    -- dialogs, the savings card and here — five chances for the same 600-coin
    -- pot to be drawn as three different piles.
    for _, path in ipairs({ "modules/dialog_incoming.lua", "modules/dialog_search.lua",
                            "modules/dialog_party.lua", "modules/online_right.lua",
                            "main/coins.gui_script" }) do
        local src = io.open(ROOT .. path):read("a")
        ok(path .. " keeps no ladder of its own",
            src:find(">= 2000 then", 1, true) == nil)
    end
    local uisrc = io.open(ROOT .. "modules/ui.lua"):read("a")
    ok("...because ui.lua owns it", uisrc:find("function M%.coin_pot_image") ~= nil)
    ok("...and pairs it with the atlas that has the art",
        uisrc:match('coin_pot.-set_texture%(n, "coins"%)') ~= nil)
end

----------------------------------------------------------------------
print("AN ARRIVAL IS ONE EVENT TOLD IN FOUR BEATS")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path
    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    local ws = require("modules.websocket_manager"); ws.current_user_id = "me"
    local dp = require("modules.dialog_party")

    local node = function() return gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end
    local COL = vmath.vector4(1, 1, 1, 1)
    local texts
    local function ctx()
        texts = {}
        return {
            C = { COL_DIM = COL, COL_MID = COL, COL_GOLD = COL, COL_WHITE = COL,
                  COL_GREEN = COL, COL_RED = COL, COL_CYAN = COL },
            -- coin_pot comes from the REAL ui module: the pot bundle is the
            -- thing under test in this file's own atlas assertions, and a stub
            -- for it would let the wrong atlas through exactly as it did.
            ui = { box = node, btn9 = node, avatar = node, grad_backdrop = node, image = node,
                   coin_pot = require("modules.ui").coin_pot,
                   pie = function() return gui.new_pie_node(vmath.vector3(0,0,0), vmath.vector3(1,1,0)) end,
                   text = function(_, str)
                       local n = gui.new_text_node(vmath.vector3(0,0,0), tostring(str))
                       texts[#texts + 1] = n; return n
                   end },
            track = function(self, n) self.nodes[#self.nodes + 1] = n; return n end,
            mkbtn = function(self, id) self.buttons[#self.buttons + 1] = { id = id } end,
            commas = function(n) return tostring(n) end,
            with_a = function(c) return c end,
            dlg_avatar = function(self)
                self.nodes[#self.nodes + 1] = node(); self.nodes[#self.nodes + 1] = node()
            end,
            CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
            DLG_RED = vmath.vector4(1,0,0,1), DLG_SEARCH = vmath.vector4(1,1,0,1),
        }
    end
    local function pot_text()
        for _, n in ipairs(texts) do
            local t = gui.get_text(n) or ""
            if t:find("POT", 1, true) then return t end
        end
    end

    local function wire(filled)
        local seats = {}
        for i = 1, filled do
            seats[i] = { userId = "u" .. i, username = "P" .. i, avatar = i, joinedAt = i }
        end
        return { partyId = "P1", hostId = "u1", entry = 200, status = "FILLING",
                 seats = seats, seatsRemaining = 4 - filled }
    end

    -- A third player sits down: the pot goes 400 -> 600, and the arrival is
    -- the chair they landed in.
    local surface = { nodes = {}, buttons = {} }
    local rec = {
        party_view = dp.view(wire(3)), time_left = 11,
        arrived_index = 3, pot_from = 400,
    }
    dp.draw(surface, ctx(), rec, 1)
    local an = surface.party_anim

    check("the pot starts from what it was", an.pot_from, 400)
    check("...and is on its way to what it is now", an.pot_to, 600)
    check("the figure on screen has not jumped straight there", pot_text(), "400 POT")

    -- THE ORDER OF THE BEATS. The chair first, the money a fraction later, the
    -- reel last — two things competing for the eye at the moment somebody
    -- arrives is how an animation ends up reading as a glitch.
    ok("the money follows the chair, it does not race it", dp.POT_DELAY > 0)
    ok("...and the reel waits until the pop has settled",
        dp.REEL_RESUME > dp.POT_DELAY and dp.REEL_RESUME >= dp.POP_SECONDS)

    -- The reel is dark while the arrival has the eye.
    dp.animate(surface, rec, 0.05)
    check("the reel is hidden for that moment", an.chairs[4].reel.color.w, 0)

    -- Halfway through the count-up the figure is between the two, not at
    -- either end: this is the property that separates a number climbing from
    -- a number that jumped.
    dp.animate(surface, rec, dp.POT_DELAY + dp.POT_SECONDS / 2)
    local mid = tonumber((pot_text() or ""):match("^(%d+)"))
    ok("the pot climbs rather than jumping", mid and mid > 400 and mid < 600,
        "got " .. tostring(mid))

    -- And it lands exactly on the real figure, never a rounding of it.
    dp.animate(surface, rec, dp.POT_SECONDS)
    check("...and lands on the true total", pot_text(), "600 POT")

    -- Once the arrival is over the reel is back, hunting in the last chair.
    dp.animate(surface, rec, dp.REEL_RESUME)
    check("the reel comes back for the last chair", an.chairs[4].reel.color.w, 1)
    local first = an.reel_ix
    for _ = 1, 12 do dp.animate(surface, rec, dp.REEL_STEP) end
    ok("...and it is actually hunting", an.reel_ix ~= 0)
    -- Sixty avatars: two draws landing on the same one is possible, twelve
    -- never moving is not.
    ok("...through more than one face", an.reel_ix ~= first or first ~= 0)

    -- A TABLE THAT SIMPLY APPEARED has no arrival to play. Nothing pops,
    -- nothing blooms, and the pot is already correct.
    local s2 = { nodes = {}, buttons = {} }
    local r2 = { party_view = dp.view(wire(2)), time_left = 14 }
    dp.draw(s2, ctx(), r2, 1)
    check("a table opening shows its pot outright", pot_text(), "400 POT")
    check("...with no arrival in flight", s2.party_anim.since, nil)

    -- ANIMATE IS SAFE TO CALL ON ANYTHING. The overlay calls it every frame,
    -- including frames where the record belongs to a table that has gone.
    ok("a record for another table is ignored",
        dp.animate(s2, { party_view = dp.view({ partyId = "OTHER" }) }, 0.1) == false)
    ok("...and so is no record at all", dp.animate({}, r2, 0.1) == false)
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

----------------------------------------------------------------------
print("A PLAYER AT A TABLE READS AS BUSY, NOT AS AVAILABLE")
----------------------------------------------------------------------
do
    for name in pairs(package.loaded) do
        if name:match("^modules%%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path
    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()

    local sort = require("modules.player_sort")

    -- `inParty` is the flag broadcastOnlineUsers now sends beside inGameWith.
    -- The server already refuses every request to a seated player; without
    -- this the lobby still drew a CHALLENGE button over one, and the only way
    -- to find out was to tap it and be told no.
    ok("a seated player counts as busy", sort.is_playing({ _id = "a", inParty = true }))
    ok("a player mid-game still does", sort.is_playing({ _id = "b", gameId = "g1" }))
    ok("an idle one still does not", not sort.is_playing({ _id = "c" }))
    ok("nor does one whose game id is empty", not sort.is_playing({ _id = "d", gameId = "" }))

    local src = io.open(ROOT .. "modules/online_center.lua"):read("a")
    ok("the lobby row reads the same flag", src:find("pu.inParty", 1, true) ~= nil)
    ok("...and says which kind of busy it is", src:find("AT A TABLE", 1, true) ~= nil)
    ok("...and attaches no challenge to it",
        src:find("if not playing then", 1, true) ~= nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
