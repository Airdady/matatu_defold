-- WHY THE BOARD IS NOT RESPONDING.
--
-- Every lock that can refuse a tap, in one place, as plain functions over a
-- table of flags. No Defold, no `self` methods, nothing to mock — so the
-- question "could the deck be dead in this state?" can actually be asked.
--
-- IT WAS NOT ASKABLE, AND THAT IS THE BUG THIS FILE COMES FROM. Reported:
-- after the opponent plays a penalty the draw pile stops responding — taps do
-- nothing and nothing on screen says why.
--
-- game.script carries five per-turn locks:
--
--   waiting                  turn handed over, awaiting the server
--   is_animating             cards in flight
--   is_local_action_locked   an action of ours is being resolved
--   is_suit_selection_active the suit picker is up
--   player_has_drawn         we have already drawn THIS turn
--
-- Four of them have a watchdog in update(). The fifth did not, and its only
-- per-turn reset was the false->true edge of `now_my_turn`. An edge is sampled
-- once a frame, and two state updates can land in one frame — the opponent's
-- play, and the turn coming back — so the intermediate "not my turn" is never
-- observed, the edge never fires, and the flag survives from the previous
-- turn.
--
-- Ordinarily that costs nothing: the player can still play a card. With a
-- PENALTY pending, drawing is the only legal move there is, so a stale flag is
-- a dead turn. That is the report, including its "at times" — it needs two
-- updates in one frame, which is timing.
--
-- AND TWO UPDATES IN ONE FRAME IS REACHABLE — checked, not assumed, because
-- the whole argument rests on it. online_handler.pump_move_queue drains the
-- queue by recursing from its own on_done, and finalize_state_sync's do_sync
-- calls settle() SYNCHRONOUSLY whenever the opponent's hand did not grow:
--
--   else
--       while #self.ai_hand > target do ... end
--       self.position_hands(true)
--       settle()          -- on_complete -> on_done -> pump_move_queue
--   end
--
-- So a queued opponent PLAY and the state that returns the turn can both be
-- applied inside one call stack, with no update() in between to sample the
-- edge. A penalty play that costs the opponent a card takes exactly that
-- branch.
local M = {}

local function truthy(v) return v and true or false end

--- Is a draw actually in flight right now?
---
--- The thing player_has_drawn was standing in for. A draw sets
--- is_local_action_locked and animates cards to the hand; either being set
--- means the draw this turn is still resolving.
function M.draw_in_flight(s)
    s = s or {}
    return truthy(s.is_animating or s.is_local_action_locked)
end

--- Should a set player_has_drawn be treated as stale and cleared?
---
--- Only under conditions that ALREADY rule out a draw in progress: it is our
--- turn, no move is being processed, the move queue is empty, nothing is
--- awaited from the server, and nothing is animating or locked. A draw fails
--- every one of those, so a flag still set here describes a draw that has
--- already finished — that is, a previous turn's.
function M.stale_draw_flag(s)
    s = s or {}
    if not s.is_player_turn then return false end
    if not s.player_has_drawn then return false end
    if s.is_processing_move then return false end
    if (s.move_queue_len or 0) > 0 then return false end
    if s.is_waiting_for_server_response then return false end
    if M.draw_in_flight(s) then return false end
    return true
end

--- Why a tap on the draw pile is being refused, or nil when it is allowed.
---
--- Returns a REASON rather than a boolean, because the whole difficulty of the
--- original report was that a refusal looked identical to a broken board: the
--- card branch shakes the card when it refuses, and this one swallowed the tap
--- in silence.
function M.deck_tap_refusal(s)
    s = s or {}
    if not s.is_player_turn then return 'not your turn' end
    if s.waiting then return 'waiting' end
    if s.is_local_action_locked then return 'action in progress' end
    if s.is_suit_selection_active then return 'suit picker open' end
    return nil
end

--- Must a PENALTY draw be refused?
---
--- The intent was always one draw per turn, and player_has_drawn was the wrong
--- variable to enforce it with: the draw sets is_local_action_locked on the
--- very next line, and deck_tap_refusal above already refuses every tap while
--- that is set, so the second tap was covered twice over.
---
--- The difference between the two is RECOVERY. is_local_action_locked has a
--- watchdog; player_has_drawn had none. So when the flag went stale it killed
--- the turn outright, and the only way out was the AFK timer.
---
--- Now it refuses only a draw that is genuinely underway.
function M.penalty_draw_blocked(s)
    s = s or {}
    if not s.player_has_drawn then return false end
    return M.draw_in_flight(s)
end

--- Everything holding the board, for the log line. Ordered, stable, cheap.
function M.describe(s)
    s = s or {}
    return string.format(
        'my_turn=%s waiting=%s locked=%s suit_sel=%s animating=%s drew=%s penalty=%s',
        tostring(truthy(s.is_player_turn)), tostring(truthy(s.waiting)),
        tostring(truthy(s.is_local_action_locked)), tostring(truthy(s.is_suit_selection_active)),
        tostring(truthy(s.is_animating)), tostring(truthy(s.player_has_drawn)),
        tostring(tonumber(s.penalty) or 0))
end

return M
