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

-- ---------------------------------------------------------------------------
-- IS THE INCOMING MOVE STUCK, OR JUST SLOW?
--
-- Reported: on a slow connection the opponent's cards take a while to come in,
-- and DURING that delay the player can tap their own cards and the taps are
-- sent as a move.
--
-- is_processing_move is what refuses those taps, and update() had a watchdog
-- that cleared it after 3.5 seconds:
--
--     if #self.move_queue == 0 then
--         if self.is_processing_move then
--             self.stuck_count = self.stuck_count + dt
--             if self.stuck_count > 3.5 then self.is_processing_move = false end
--
-- Both of its conditions are TRUE throughout a perfectly healthy move.
-- pump_move_queue removes the item from the queue BEFORE processing it, so the
-- queue is empty for the whole apply; and the apply itself genuinely takes
-- seconds — process_opponent_actions spends 0.24s between plays and 0.42s
-- settling, a penalty draw batches five cards, and finalize_state_sync can run
-- a 1.3s reshuffle on top. So the watchdog was not detecting a stuck pipeline.
-- It was putting a stopwatch on a slow one and calling time.
--
-- What made that a rules problem rather than a cosmetic one: by then
-- finalize_state_sync has already assigned self.game_state (so is_player_turn()
-- is true) and cleared is_waiting_for_server_response, so reconcile_input_locks
-- releases `waiting` and `is_local_action_locked` too. The tap is then judged by
-- evaluate_play against a pile that has not finished being built, and sent.
--
-- A STOPWATCH CANNOT TELL THE TWO APART. PROGRESS CAN. A move that is being
-- applied changes the board constantly — cards leave a hand, land on the pile,
-- come off the deck, animation locks go up and down. A move that is stuck
-- changes nothing at all. So the timer is reset by any observable change, and
-- only genuine silence counts toward the limit.
--
-- The absolute ceiling stays because the original freeze this watchdog was
-- written for is real: a pipeline can wedge while still ticking an animation
-- counter, and a board that never accepts input again is worse than one that
-- resyncs.

--- No observable change on the board for this long means the apply is dead.
--- Comfortably longer than the longest gap a healthy apply ever leaves
--- (finalize_state_sync's 1.3s reshuffle runs with animation locks held, and
--- process_opponent_actions' quietest beat is 0.42s).
M.STALL_SECONDS = 3.5

--- And no apply may run longer than this however busy it looks, so a pipeline
--- that wedges mid-animation still recovers.
M.CEILING_SECONDS = 15.0

--- A cheap, stable fingerprint of everything an apply moves.
---
--- Counts only: an apply that is running changes at least one of these every
--- fraction of a second, and one that has died changes none of them.
function M.board_signature(s)
    s = s or {}
    local n = function(v) return tonumber(v) or 0 end
    return string.format('%d/%d/%d/%d/%d/%d',
        n(s.player_hand), n(s.ai_hand), n(s.played),
        n(s.deck), n(s.anim_locks), n(s.queue))
end

function M.new_stall_tracker()
    return { since_progress = 0, since_start = 0, signature = nil }
end

--- Advance the tracker one frame.
---
--- Returns a REASON string when the apply should be declared dead, or nil while
--- it is alive. The reason is what gets logged: "it was stuck" with no number
--- attached is how this went unnoticed for so long.
function M.track_processing(t, s, dt)
    s = s or {}
    if not t then return nil end

    if not s.is_processing then
        t.since_progress, t.since_start, t.signature = 0, 0, nil
        return nil
    end

    dt = tonumber(dt) or 0
    t.since_start = t.since_start + dt

    if s.signature ~= t.signature then
        t.signature = s.signature
        t.since_progress = 0
    else
        t.since_progress = t.since_progress + dt
    end

    if t.since_progress >= M.STALL_SECONDS then
        return string.format('no change on the board for %.1fs', t.since_progress)
    end
    -- Checked even when the signature IS moving: an apply that has been busy
    -- for fifteen seconds is not applying, it is spinning.
    if t.since_start >= M.CEILING_SECONDS then
        return string.format('still applying after %.1fs', t.since_start)
    end
    return nil
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
