-- A GAME THAT ENDED WHILE YOU WERE OFFLINE HAS TO BE TOLD TO YOU.
--
--   Run: lua5.3 tools/test_missed_gameover.lua
--
-- Reported: a match ends on a timeout while one player is offline. The player
-- who stayed connected is awarded the win, correctly. Then the one who dropped
-- comes back — and is put straight back into the match, plays on, and the
-- OPPONENT is reported as timing out of a game they had already won.
--
-- Two faults, and they are two halves of the same thing.
--
-- ONE. The client kept the finished game cached. The server answers IDENTIFY
-- with the active game when there is one, and every other outcome returns
-- before that point — a game still running comes back as gameState, one that
-- ended while you were away comes back as GAME_OVER out of missedGameResults,
-- a settlement still counting comes back as GAME_OVER too. So an IDENTIFY that
-- carries no game means the server has none: the match is finished and torn
-- down, gameStates and playerGameMap both. The client went on holding it, and
-- controller.script's resume reads exactly that field — so it put the board
-- back up for a match the server had already settled and paid out.
--
-- TWO. And once that is fixed, the result had nowhere to go. The board's own
-- game_over listener is registered when the board is BUILT, so a GAME_OVER
-- reaching a player sitting on the lobby had nothing listening for it. The
-- replay the server keeps for exactly this case was being dropped on arrival.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond, detail) check(label .. (detail and ("  [" .. detail .. "]") or ""),
    cond and true or false, true) end

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

    for _, id in ipairs({ "lobby", "auth", "profile", "online", "themes", "payments",
                          "tournaments", "team_tournament", "standings", "game",
                          "game_logic", "suit_select", "gameover", "coins", "network",
                          "incoming", "toast", "announcement", "season_results",
                          "signup_bonus", "daily_bonus", "update_required", "tutorial",
                          "card_factory", "snd_coin", "snd_suspense", "snd_fail",
                          "snd_notify", "snd_found" }) do
        SIM.add_recorder(id)
    end
    SIM.load_script_component("controller", ROOT .. "main/controller.script")
    SIM.init_component("controller")
    SIM.pump(0.2)

    local ws = require("modules.websocket_manager")
    SIM.with_ctx("controller", function() ws.connect() end)
    SIM.pump(0.5)
    return SIM, ws, require("modules.app_state")
end

-- The state of a match in progress, as the server sends one.
local function live_state()
    return { gameId = "g1", status = "PLAYING", currentTurn = "p1",
             players = { p1 = { _id = "p1" }, p2 = { _id = "p2" } },
             stake = { amount = 500, charge = 0, points = 0 },
             deck = {}, playedCards = {} }
end

local function identify(SIM, with_game)
    SIM.server_send({ type = "IDENTIFY", data = {
        _id = "p1", username = "Me", balance = 5000,
        gameState = with_game and live_state() or nil,
    } })
    SIM.pump(0.6)
end

local function screen_of(SIM) return SIM.components.controller.self.screen end
local function got(SIM, comp, mid)
    for _, r in ipairs((SIM.components[comp] or {}).received or {}) do
        if tostring(r.mid) == tostring(hash(mid)) then return true end
    end
    return false
end

----------------------------------------------------------------------
print("AN IDENTIFY WITH NO GAME MEANS THE GAME IS OVER")
----------------------------------------------------------------------
do
    local SIM, ws, app_state = boot()

    -- Mid-match, then the socket drops. The client still holds the position.
    identify(SIM, true)
    ok("the match is on screen", screen_of(SIM) == "game")
    ok("...and cached", next(ws.active_game_state or {}) ~= nil)

    -- The game ends while we are away. We come back: the server has no game
    -- for us, because it finished and was torn down.
    SIM.components.controller.self.screen = "lobby"
    identify(SIM, false)

    check("the finished game is not put back on screen", screen_of(SIM), "lobby")
    check("...and the client stops holding it", next(ws.active_game_state or {}), nil)
    check("...including its id, which the move sender reads", ws.active_game_id, "")
end

----------------------------------------------------------------------
print("AND THE RESULT IS SHOWN, NOT DROPPED")
----------------------------------------------------------------------
do
    local SIM, ws, app_state = boot()
    identify(SIM, false)
    check("we are on the lobby, with no game", screen_of(SIM), "lobby")

    -- The replay the server keeps for a player who was offline when their
    -- match ended (missedGameResults), delivered right after IDENTIFY.
    SIM.server_send({ type = "GAME_OVER", data = { gameState = {
        gameId = "g1", status = "GAME_OVER",
        players = { p1 = { _id = "p1" }, p2 = { _id = "p2" } },
        stake = { amount = 500 },
        gameOverState = { winner = "p2", reason = "TIMEOUT", gameType = "NORMAL" },
    } } })
    SIM.pump(0.2)

    check("the screen is brought up around the result", screen_of(SIM), "game")
    check("...and the result itself is parked where the board reads it",
        (ws.last_game_over or {}).winner, "p2")
    ok("...with the final position for the board to build from",
        next(ws.active_game_state or {}) ~= nil)

    -- The board is told, by the forward that already existed — and AFTER the
    -- screen is enabled, because this listener is registered before it and
    -- Defold delivers queued messages in order. That ordering is the whole
    -- difference between a result the board hears and one that lands on a
    -- component nobody has enabled.
    ok("and the board is told about it", got(SIM, "game_logic", "ws_game_over"))
    local order_ok = false
    for _, r in ipairs(SIM.components.game.received or {}) do
        if tostring(r.mid) == tostring(hash("screen_enter")) then order_ok = true end
    end
    ok("...with the screen brought up for it", order_ok)
end

----------------------------------------------------------------------
print("THE BOARD STILL OWNS ITS OWN ENDINGS")
----------------------------------------------------------------------
do
    -- A game ending in front of the player is the board's business. A second
    -- hand on the wheel here would route the screen it is already on, and show
    -- the modal twice.
    local SIM, ws = boot()
    identify(SIM, true)
    check("we are on the board", screen_of(SIM), "game")
    SIM.components.game_logic.received = {}

    SIM.server_send({ type = "GAME_OVER", data = { gameState = {
        gameId = "g1", status = "GAME_OVER",
        players = { p1 = { _id = "p1" }, p2 = { _id = "p2" } },
        gameOverState = { winner = "p1", reason = "NO_CARDS", gameType = "NORMAL" },
    } } })
    SIM.pump(0.8)
    -- The forward still posts it, as it does for every game over — what must
    -- NOT happen is this handler routing the screen it is already on, or
    -- consuming the parked state a later reconnect would need.
    check("the screen is left where it was", screen_of(SIM), "game")
    check("...and the parked position is left for whoever needs it",
        ws.pending_game_over_state ~= nil, true)
end

----------------------------------------------------------------------
print("A ROUND THAT CONTINUES IS NOT AN ENDING")
----------------------------------------------------------------------
do
    -- Between two rounds of a tournament the match is still running: the board
    -- must not be torn down and the lobby must not be routed to.
    local SIM, ws = boot()
    identify(SIM, true)
    SIM.components.controller.self.screen = "lobby"

    SIM.server_send({ type = "GAME_OVER", data = { gameState = {
        gameId = "g1", status = "GAME_OVER",
        players = { p1 = { _id = "p1" }, p2 = { _id = "p2" } },
        gameOverState = { winner = "p1", reason = "NO_CARDS", gameType = "TOURNAMENT" },
    } } })
    SIM.pump(0.8)
    check("a continuing round parks no final position", ws.pending_game_over_state, nil)
    check("...and does not route anybody to a board", screen_of(SIM), "lobby")
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
