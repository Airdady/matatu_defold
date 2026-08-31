-- WHEN A BACKGROUND EVENT MAY TAKE THE SCREEN FROM A GAME, AND WHEN IT MAY NOT.
--
-- Two intruders, one rule: an online game arriving on a reconnect
-- (may_take_over) and an auth/connection failure sending the player to the
-- lobby (may_interrupt). Both used to end an offline game that had asked for
-- neither.
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

--- What is on the screen right now, as far as either rule below cares.
---
--- Both questions turn on exactly this, so it is asked once. Two copies of
--- the same condition is how a rule like this comes apart: one gets a fix and
--- the other does not, and the bug comes back down whichever path was missed.
---
--- @param state table {
---   screen       = the screen the controller is showing ("game", "lobby", …)
---   mode         = app_state.mode, "offline" or "online"
---   game_active  = app_state.game_active
---   offline_game = app_state.offline_game
--- }
local function classify(state)
    state = state or {}

    if tostring(state.screen or "") ~= "game" then
        return "no_game_screen"
    end

    if tostring(state.mode or "") ~= "offline" then
        return "online_game"
    end

    -- On the game screen, in offline mode. `game_active` is the live flag;
    -- `offline_game` is the game object the lobby handed over. EITHER being
    -- present means there is a match to protect — they are set at slightly
    -- different moments, and an intruder landing in the gap between them is
    -- precisely the kind of timing this is meant to survive.
    if state.game_active or state.offline_game ~= nil then
        return "offline_game"
    end

    -- The game screen in offline mode with nothing running: a torn-down game,
    -- or the moment before one starts. Nothing to protect.
    return "idle_game_screen"
end

--- May an incoming online game take the screen?
---
--- @param state table  see classify above
--- @return boolean allowed
--- @return string reason  why not, for the log — always set, both ways
function M.may_take_over(state)
    local what = classify(state)

    if what == "no_game_screen" then
        -- Not in any game: this is the ordinary resume/match-found path.
        return true, "not on the game screen"
    end

    if what == "online_game" then
        -- An ONLINE game on screen is the round-continuation case, which is
        -- exactly what ws_new_game_start is for. Never blocked.
        return true, "already in an online game"
    end

    if what == "offline_game" then
        return false, "an offline game is in progress"
    end

    return true, "no offline game in progress"
end

--- May a BACKGROUND CONNECTION OR AUTH EVENT navigate away from the screen?
---
--- THE SECOND HALF OF THE SAME BUG.
---
--- may_take_over above stops a reconnect REPLACING an offline game with an
--- online one. It does nothing about the other way a reconnect ended one:
--- controller.script's auth_required and identify_error handlers both finished
--- with an unconditional
---
---     if self.screen ~= "lobby" then show(self, "lobby") end
---
--- and show() posts `disable` to #game_logic, which sets game_active = false
--- and bumps _seq — the offline game is torn down, mid-hand, and the player is
--- standing in the lobby.
---
--- Neither event has anything to do with an offline game. An expired session
--- and a refused IDENTIFY are both about the SOCKET, and a Quick Play match
--- against the AI needs no socket and no session to finish. They fire from
--- background retries the player never asked for and never saw, which is why
--- this reads as the game closing by itself.
---
--- Reported as: "at times when its offline and the others are trying to
--- reconnect they end up terminating the offline game going on."
---
--- WHAT IS AND IS NOT REFUSED
---
--- Only the navigation. Both handlers still clear the session and still start
--- their silent re-login — the recovery runs exactly as before, in the
--- background, where it belongs. The player is simply left in their game while
--- it happens, and lands on a rebuilt session when they leave it.
---
--- An ONLINE game deliberately stays interruptible. There the session IS the
--- game: a rejected identity means the server will take no more moves, so
--- carrying on would show a board that cannot play. Only the offline case is
--- changed, which is the whole of what was wrong.
---
--- @return boolean allowed
--- @return string reason  always set, both ways
function M.may_interrupt(state)
    local what = classify(state)

    if what == "no_game_screen" then
        return true, "not on the game screen"
    end

    if what == "online_game" then
        -- The session is what makes an online game playable; losing it is
        -- exactly when leaving is right.
        return true, "an online game depends on the session"
    end

    if what == "offline_game" then
        return false, "an offline game is in progress"
    end

    return true, "no offline game in progress"
end

--- The same question from the app_state module and a screen name.
---
--- A convenience so the two call sites in controller.script read as one line
--- each and cannot disagree about which fields matter.
local function snapshot(app_state, screen)
    return {
        screen = screen,
        mode = app_state and app_state.mode,
        game_active = app_state and app_state.game_active,
        offline_game = app_state and app_state.offline_game,
    }
end

function M.may_take_over_now(app_state, screen)
    return M.may_take_over(snapshot(app_state, screen))
end

--- may_interrupt, read off the app_state module and a screen name.
function M.may_interrupt_now(app_state, screen)
    return M.may_interrupt(snapshot(app_state, screen))
end

return M
