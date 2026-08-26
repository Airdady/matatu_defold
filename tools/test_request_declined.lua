-- SOMEBODY ELSE'S WINDOW CLOSING IS NOT OUR SEARCH FAILING.
--
--   Run: lua tools/test_request_declined.lua
--
-- Reported: tapping "find opponent" in a tournament and getting back, on the
-- search dialog, the words
--
--   Window closed
--
-- Two separate faults produced that, and they compound.
--
-- ONE. GAME_REQUEST_DECLINED carries `reason` — a machine token the backend
-- branches on and writes to its log — and `message`, the sentence written for
-- a player. The client read `reason`. So the search dialog printed whatever
-- string an engineer had passed to cancelBroadcast, and for the requester's
-- own no-opponent case it printed the token "NO_OPPONENT".
--
-- TWO, and this is the one that put a stranger's wording on our screen. The
-- same message type is used for two unrelated events:
--
--   our own request was declined              -> our search has failed
--   an invitation sent TO US was withdrawn    -> nothing to do with us
--
-- The second carries `revoked: true`. Nothing here looked at it, so when
-- another player's broadcast settled and retired the invitation it had sent
-- us, our own search died with their reason on it.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

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
                          "signup_bonus", "daily_bonus", "network", "incoming", "gameover",
                          "update_required", "toast", "announcement", "season_results",
                          "tutorial", "suit_select", "card_factory", "snd_coin",
                          "snd_suspense", "snd_fail", "tournaments" }) do
        SIM.add_recorder(id)
    end
    SIM.load_script_component("controller", ROOT .. "main/controller.script")
    SIM.init_component("controller")
    SIM.pump(0.2)

    local ws = require("modules.websocket_manager")
    -- A real frame down a real socket, so parse_message's own
    -- GAME_REQUEST_DECLINED branch is what runs.
    ws.connect()
    SIM.pump(0.5)

    return SIM, ws, require("modules.app_state")
end

-- Did #tournaments receive a search failure, and with what wording?
local function search_failure(SIM)
    local rec = SIM.components.tournaments.received or {}
    for i = #rec, 1, -1 do
        if rec[i].mid == hash("ws_search_failed") then
            return true, tostring((rec[i].msg or {}).reason or "")
        end
    end
    return false, nil
end

local function declined(ws, SIM, payload)
    SIM.server_send({ type = "GAME_REQUEST_DECLINED", data = payload })
    SIM.pump(0.5)
end

----------------------------------------------------------------------
print("A WITHDRAWN INVITATION LEAVES OUR SEARCH ALONE")
----------------------------------------------------------------------
do
    local SIM, ws, app_state = boot()
    app_state.searching_tournament = true

    -- Exactly what cancelBroadcast sends every invitee it retires.
    declined(ws, SIM, {
        requestId = "REQ-FROM-SOMEBODY-ELSE",
        reason = "That invitation expired",
        revoked = true,
    })

    local failed, said = search_failure(SIM)
    check("our search is not failed by it", failed, false)
    check("and their wording never reaches our dialog", said, nil)
end

----------------------------------------------------------------------
print("OUR OWN REQUEST BEING DECLINED STILL FAILS THE SEARCH")
----------------------------------------------------------------------
do
    local SIM, ws, app_state = boot()
    app_state.searching_tournament = true

    declined(ws, SIM, { requestId = "REQ-OURS", reason = "Declined" })

    local failed = search_failure(SIM)
    check("the search is reported failed", failed, true)
end

----------------------------------------------------------------------
print("THE PLAYER READS THE SENTENCE, NOT THE TOKEN")
----------------------------------------------------------------------
do
    local SIM, ws, app_state = boot()
    app_state.searching_tournament = true

    -- settleBroadcast's no-acceptances exit, exactly as the backend sends it.
    declined(ws, SIM, {
        reason = "NO_OPPONENT",
        message = "Nobody was available for that match. Try again in a moment.",
    })

    local failed, said = search_failure(SIM)
    check("the search is still reported failed", failed, true)
    check("and the dialog is given the sentence",
        said, "Nobody was available for that match. Try again in a moment.")
end

----------------------------------------------------------------------
print("AND THE INVITATION BANNER IS STILL CLEARED EITHER WAY")
----------------------------------------------------------------------
do
    -- The revoked case must not become "ignore the message entirely": the
    -- banner offering a match that no longer exists has to come down.
    -- incoming.gui_script listens to the same event for that, and it is the
    -- one part that was always right.
    local src = io.open(ROOT .. "main/incoming.gui_script"):read("a")
    local at = src:find('ws.on("game_request_declined"', 1, true)
    check("incoming still listens for it", at ~= nil, true)
    check("and clears the banner on it",
        src:sub(at, at + 200):find("incoming_clear", 1, true) ~= nil, true)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
