-- BOTH PLAYERS SEE WHAT THE GAME IS WORTH.
--
--   Run: lua tools/test_stake_pot.lua
--
-- Reported: in some matches one player has the stake on their board and the
-- other has nothing.
--
-- The stake is not a label — overlay_ui's static chip was removed and the coin
-- bundle raised on "#coins" IS the display. controller.script raised it in one
-- place: the game_request_accepted handler, BELOW intercept_for_search's early
-- return. So the player sitting in the search dialog — whoever tapped invite,
-- or searched a tournament — returned before reaching it and played the whole
-- match with no pot on screen, while their opponent, who arrived without
-- searching, had one.
--
-- Their board does not exist at that moment (the dialog holds the screen for
-- another 1.8s), so theirs is raised when the screen actually changes.

local SIM = dofile("tools/defold_sim.lua")
-- controller.script registers a window listener at init; the stub has none,
-- and without it init dies before a single ws.on() is registered.
_G.window.set_listener = function() end
-- No network from a test: api_service reaches http.request at boot (device
-- login) and takes controller's init down with it if it is missing.
_G.http = { request = function() end }
local ws = require("modules.websocket_manager")
local app_state = require("modules.app_state")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

for _, id in ipairs({ "lobby", "auth", "profile", "online", "themes", "payments",
                      "tournaments", "game", "suit_select", "gameover", "coins",
                      "snd_suspense", "snd_found" }) do
    SIM.add_recorder(id)
end
SIM.load_script_component("controller", "main/controller.script")
SIM.load_script_component("game_logic", "main/game.script")
SIM.init_component("controller")
SIM.init_component("game_logic")
SIM.pump(0.2)

SIM.with_ctx("controller", function() ws.connect() end)
SIM.pump(0.5)
SIM.server_send({ type = "IDENTIFY", data = { _id = "p1", username = "Me", balance = 5000 } })
SIM.pump(0.5)

local coins = SIM.components.coins
local function pot_messages()
    local out = {}
    for _, r in ipairs(coins.received or {}) do
        -- The recorder keeps the message id as the engine hands it over — a
        -- hash, not the string it was written as.
        if tostring(r.mid) == tostring(hash("coin_collect_pot")) then out[#out + 1] = r.msg end
    end
    return out
end
local function reset_coins() coins.received = {} end

-- A frame the way the server sends one. extract_game_state on the client is
-- what unwraps it, so driving the real socket keeps this test honest about
-- the shape rather than about a re-implementation of it.
local function game_state(stake)
    return {
        gameId = "g1", status = "ACTIVE",
        stake = stake and { amount = stake, charge = 0, points = 0 } or nil,
        players = {}, deck = {}, playedCards = {},
    }
end

local function accepted(stake)
    SIM.server_send({ type = "GAME_REQUEST_ACCEPTED", data = { gameState = game_state(stake) } })
end

local function started(stake)
    SIM.server_send({ type = "START", data = { gameId = "g1", gameState = game_state(stake) } })
end

----------------------------------------------------------------------
print("THE PLAYER WHO WAS SEARCHING")
----------------------------------------------------------------------
-- This is the reported case: they tapped invite, the dialog is up, and the
-- match lands on them while they are still on the online screen.
reset_coins()
SIM.components.controller.self.screen = "online"
app_state.searching_invite = true
accepted(500)
SIM.pump(0.2)

check("nothing is raised while the search dialog still holds the screen",
      #pot_messages(), 0)

SIM.pump(2.5) -- past the 1.8s hand-off to the board
local raised = pot_messages()
check("the pot arrives when their board does", #raised, 1)
check("...carrying both stakes", raised[1] and raised[1].amount, 1000)

----------------------------------------------------------------------
print("")
print("THE PLAYER WHO WAS NOT")
----------------------------------------------------------------------
reset_coins()
SIM.components.controller.self.screen = "lobby"
app_state.searching_invite = false
app_state.game_active = false
accepted(500)
SIM.pump(0.5)
check("the opponent's pot is raised too", #pot_messages(), 1)

----------------------------------------------------------------------
print("")
print("A START THAT ARRIVES ON ITS OWN")
----------------------------------------------------------------------
-- handlePlayerReady broadcasts START to both sides, and a reconnect can
-- deliver one without a preceding GAME_REQUEST_ACCEPTED.
reset_coins()
SIM.components.controller.self.screen = "lobby"
app_state.searching_invite = false
started(200)
SIM.pump(0.5)
local from_start = pot_messages()
check("a player arriving on START still gets the stake", #from_start, 1)
check("...at that game's own value", from_start[1] and from_start[1].amount, 400)

----------------------------------------------------------------------
print("")
print("WHAT IS NOT RAISED")
----------------------------------------------------------------------
reset_coins()
SIM.components.controller.self.screen = "lobby"
accepted(0)
SIM.pump(0.5)
check("a free game has no pot to show", #pot_messages(), 0)

reset_coins()
accepted(nil)
SIM.pump(0.5)
check("and a payload with no stake invents nothing — this read `or 500`",
      #pot_messages(), 0)

reset_coins()
SIM.components.controller.self.screen = "game"
app_state.game_active = true
accepted(500)
SIM.pump(0.5)
check("the next ROUND of a match does not replay the collection",
      #pot_messages(), 0)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
