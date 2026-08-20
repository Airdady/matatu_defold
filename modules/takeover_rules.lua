-- WHEN AN ONLINE GAME MAY TAKE THE SCREEN, AND WHEN IT MAY NOT.
--
-- THE BUG THIS EXISTS FOR
--
-- Every reconnect runs IDENTIFY, and IDENTIFY's reply carries the account's
-- active online game when there is one. websocket_manager turns that into a
-- `game_request_accepted` event — the same event a freshly accepted invite
-- fires — and controller.script's handler ends with:
--
--     if self.screen ~= "game" then show(self, "game")
--     else msg.post("#game_logic", "ws_new_game_start") end
--
-- Read that second branch with an OFFLINE game on screen. The player is in a
-- Quick Play match against the AI, the socket comes back by itself in the
-- background, IDENTIFY reports the online game they abandoned an hour ago, and
-- their offline game is torn down and replaced mid-hand. Nothing they did
-- asked for that; the reconnect was a retry they never saw.
--
-- Reported as: "whenever it happens, any offline game which was going on
-- closes and it's terminated."
--
-- THE RULE
--
-- An offline game in progress OWNS THE SCREEN. Online state still arrives and
-- is still stored — ws.active_game_state is set by the parser before the event
-- is ever emitted, so nothing is lost and the online game is still there to
-- resume when the player leaves the offline one. What is refused is the
-- NAVIGATION, and only that.
--
-- The rule is deliberately narrow. It bites only when all three are true:
-- the player is on the game screen, in offline mode, with a live game. Any
-- looser and it would start swallowing the ordinary path — tap PLAY ONLINE,
-- get matched, go to the game — which is the same event arriving for a
-- completely different reason.
--
-- Pure: no `gui`, no `msg`, no Defold anything. The caller passes a snapshot
-- of what it knows. tools/test_takeover_rules.lua runs it under stock Lua.

local M = {}

--- May an incoming online game take the screen?
---
--- @param state table {
---   screen       = the screen the controller is showing ("game", "lobby", …)
---   mode         = app_state.mode, "offline" or "online"
---   game_active  = app_state.game_active
---   offline_game = app_state.offline_game
--- }
--- @return boolean allowed
--- @return string reason  why not, for the log — always set, both ways
function M.may_take_over(state)
    state = state or {}

    if tostring(state.screen or "") ~= "game" then
        -- Not in any game: this is the ordinary resume/match-found path.
        return true, "not on the game screen"
    end

    if tostring(state.mode or "") ~= "offline" then
        -- An ONLINE game on screen is the round-continuation case, which is
        -- exactly what ws_new_game_start is for. Never blocked.
        return true, "already in an online game"
    end

    -- On the game screen, in offline mode. `game_active` is the live flag;
    -- `offline_game` is the game object the lobby handed over. EITHER being
    -- present means there is a match to protect — they are set at slightly
    -- different moments, and a takeover landing in the gap between them is
    -- precisely the kind of timing this is meant to survive.
    if state.game_active or state.offline_game ~= nil then
        return false, "an offline game is in progress"
    end

    -- The game screen in offline mode with nothing running: a torn-down game,
    -- or the moment before one starts. Nothing to protect.
    return true, "no offline game in progress"
end

--- The same question from the app_state module and a screen name.
---
--- A convenience so the two call sites in controller.script read as one line
--- each and cannot disagree about which fields matter.
function M.may_take_over_now(app_state, screen)
    return M.may_take_over({
        screen = screen,
        mode = app_state and app_state.mode,
        game_active = app_state and app_state.game_active,
        offline_game = app_state and app_state.offline_game,
    })
end

return M
