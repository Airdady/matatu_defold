-- THE DRAW PILE GOING DEAD AFTER AN OPPONENT'S PENALTY.
--
--   Run: lua tools/test_turn_locks.lua
--
-- Reported: "at times when the opponent sends a penalty the draw pile is
-- unable to be accessed by the current player, even if he taps, cards can't
-- get off the pile."
--
-- game.script carries five per-turn locks. FOUR OF THEM HAVE A WATCHDOG in
-- update() and the fifth did not:
--
--   waiting                  watchdog: released when the turn is ours
--   is_animating             watchdog: cleared after 3.5s stuck
--   is_local_action_locked   watchdog: cleared after 3.5s stuck
--   is_suit_selection_active watchdog: released on suit_select_closed
--   player_has_drawn         NOTHING
--
-- Its only per-turn reset was the false->true edge of `now_my_turn` in
-- update(). An edge is sampled once a frame, and two state updates can land in
-- the same frame — the opponent's play, and the turn coming back — so the
-- intermediate "not my turn" is never observed, the edge never fires, and the
-- flag survives from the previous turn.
--
-- Ordinarily that costs nothing: the player can still play a card. With a
-- PENALTY pending, drawing is the ONLY legal move there is, so a stale flag is
-- a dead turn with no way out but the AFK timer. That is the report, including
-- its "at times" — it needs two updates in one frame, which is timing.
--
-- These RUN the decisions. They were unreachable inside on_input, which is why
-- they now live in modules/turn_locks.lua.
package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local TL = require "modules.turn_locks"

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

-- A turn that is ours with nothing whatsoever in flight.
local function idle(over)
    local s = {
        is_player_turn = true,
        waiting = false,
        is_animating = false,
        is_local_action_locked = false,
        is_suit_selection_active = false,
        is_processing_move = false,
        is_waiting_for_server_response = false,
        move_queue_len = 0,
        player_has_drawn = false,
        penalty = 0,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

-- ---------------------------------------------------------------------------
print("")
print("THE FLAG THAT SURVIVED A TURN")

check("a set flag with nothing in flight is stale",
    TL.stale_draw_flag(idle({ player_has_drawn = true })) == true,
    "this is the state the report describes: our turn, nothing happening, deck dead")

check("an unset flag is not stale — there is nothing to clear",
    TL.stale_draw_flag(idle({ player_has_drawn = false })) == false)

check("and it is never cleared on somebody else's turn",
    TL.stale_draw_flag(idle({ player_has_drawn = true, is_player_turn = false })) == false,
    "the flag belongs to a turn; clearing it off-turn would lose a real draw")

print("")
print("BUT NEVER WHILE A DRAW IS ACTUALLY HAPPENING")
-- The whole safety argument: every one of these rules out a draw in progress,
-- so a flag still set without them describes a draw that already finished.
for _, field in ipairs({
    "is_animating", "is_local_action_locked",
    "is_processing_move", "is_waiting_for_server_response",
}) do
    check("not while " .. field,
        TL.stale_draw_flag(idle({ player_has_drawn = true, [field] = true })) == false,
        "clearing here would let a second draw land on top of the first")
end
check("nor with moves still queued",
    TL.stale_draw_flag(idle({ player_has_drawn = true, move_queue_len = 2 })) == false)

check("nothing at all does not throw",
    (function()
        local ok = pcall(TL.stale_draw_flag, nil)
        return ok and TL.stale_draw_flag(nil) == false
    end)())

-- ---------------------------------------------------------------------------
print("")
print("A PENALTY DRAW IS REFUSED ONLY WHILE ONE IS UNDERWAY")
--
-- The old guard was `if self.player_has_drawn then return true end`. Right
-- intent — one draw per turn — wrong variable: the draw sets
-- is_local_action_locked on the very next line, and the outer gate already
-- refuses every tap while that is set, so the second tap was covered twice.
-- The difference is recovery, and the flag had none.

check("a stale flag alone no longer blocks the draw",
    TL.penalty_draw_blocked(idle({ player_has_drawn = true })) == false,
    "this single line is what killed the turn")

check("a draw already animating still blocks it",
    TL.penalty_draw_blocked(idle({ player_has_drawn = true, is_animating = true })) == true,
    "a second tap mid-draw must not deal a second penalty")

check("and so does one still locked",
    TL.penalty_draw_blocked(idle({ player_has_drawn = true, is_local_action_locked = true })) == true)

check("a player who has NOT drawn is never blocked",
    TL.penalty_draw_blocked(idle({ player_has_drawn = false, is_animating = true })) == false,
    "the outer refusal handles that case, with feedback")

-- ---------------------------------------------------------------------------
print("")
print("AND A REFUSAL SAYS WHICH LOCK DID IT")
--
-- The card branch shakes the card when it refuses a tap. The deck branch
-- swallowed it in silence, so every reason below — and any stuck lock —
-- presented to the player as "the deck does not work", with nothing to report.

check("an idle turn is not refused at all", TL.deck_tap_refusal(idle()) == nil)
check("not your turn", TL.deck_tap_refusal(idle({ is_player_turn = false })) == "not your turn")
check("waiting", TL.deck_tap_refusal(idle({ waiting = true })) == "waiting")
check("action in progress",
    TL.deck_tap_refusal(idle({ is_local_action_locked = true })) == "action in progress")
check("suit picker open",
    TL.deck_tap_refusal(idle({ is_suit_selection_active = true })) == "suit picker open")

check("the reasons are all different, or the log says nothing",
    (function()
        -- Each entry sets ONE flag to the value that trips it. Written as
        -- explicit pairs rather than derived: `(f == "x") and false or true`
        -- is always true in Lua, and that trap silently made this assert on
        -- three cases instead of four.
        local cases = {
            { is_player_turn = false },
            { waiting = true },
            { is_local_action_locked = true },
            { is_suit_selection_active = true },
        }
        local seen, n = {}, 0
        for _, over in ipairs(cases) do
            local r = TL.deck_tap_refusal(idle(over))
            if r and not seen[r] then seen[r] = true; n = n + 1 end
        end
        return n == #cases
    end)())

check("and describe() names every lock",
    (function()
        local d = TL.describe(idle({ player_has_drawn = true, penalty = 3 }))
        return d:find("drew=true") and d:find("penalty=3")
            and d:find("my_turn=") and d:find("waiting=")
            and d:find("locked=") and d:find("suit_sel=") and d:find("animating=")
    end)(),
    "the next time somebody says the pile is dead, the log should say which flag")

-- ---------------------------------------------------------------------------
print("")
print("A RESHUFFLE IN FLIGHT IS ITS OWN REASON, NOT SILENCE")
--
-- Reported: "when the cards are reshuffled we can't pick from the deck."
-- reshuffle_queue.lua empties self.deck for the ~1.3s its animation runs, and
-- the deck-tap block in game.script used to be gated on `#self.deck > 0` —
-- so a tap in that window never even reached this function. It now does,
-- carrying `reshuffling = true`, and it has to win over every other flag:
-- there is no physical card to hand over regardless of whose turn it is.

check("reshuffling wins even on an otherwise idle turn",
    TL.deck_tap_refusal(idle({ reshuffling = true })) == "reshuffling")

check("reshuffling wins over every other lock too",
    TL.deck_tap_refusal(idle({
        reshuffling = true, waiting = true, is_local_action_locked = true,
    })) == "reshuffling",
    "none of the other locks mean anything with no card to give")

check("but an idle turn with no reshuffle is still not refused",
    TL.deck_tap_refusal(idle({ reshuffling = false })) == nil)

check("describe() carries it too",
    TL.describe(idle({ reshuffling = true })):find("reshuffling=true") ~= nil)

check("describe survives a nil state",
    (function() local ok = pcall(TL.describe, nil); return ok end)())

-- ---------------------------------------------------------------------------
print("")
print("THE SCENARIO, END TO END")
--
-- The exact sequence from the report, stepped through.

-- 1. Our turn. We draw an ordinary card; the flag goes up and the turn ends.
local s = idle({ player_has_drawn = true, is_local_action_locked = true })
check("mid-draw, a second tap is refused", TL.deck_tap_refusal(s) ~= nil)

-- 2. The opponent plays a penalty. Both the play and the turn coming back
--    arrive in one frame, so the `now_my_turn` edge is never observed and the
--    flag is still up.
s = idle({ player_has_drawn = true, penalty = 2 })

-- 3. BEFORE: the outer gate let the tap through, and then the penalty branch
--    swallowed it on the flag alone. A dead turn, silently.
check("the tap is not refused by the outer gate", TL.deck_tap_refusal(s) == nil)
check("and the penalty branch no longer swallows it",
    TL.penalty_draw_blocked(s) == false,
    "this is the fix: the player can draw their penalty")

-- 4. And the watchdog would have cleared the flag on its own anyway.
check("the watchdog sees the same state as stale", TL.stale_draw_flag(s) == true,
    "belt and braces — either one alone unsticks the board")

-- ---------------------------------------------------------------------------
print("")
print("THE WIRING")

local game = slurp("main/game.script")
local code = game:gsub("%-%-[^\n]*", "")

check("game.script uses the module", code:find('require "modules%.turn_locks"'))
check("the watchdog asks stale_draw_flag", code:find("TL%.stale_draw_flag"))
check("the penalty branch asks penalty_draw_blocked", code:find("TL%.penalty_draw_blocked"))
check("the deck refusal asks for a reason", code:find("TL%.deck_tap_refusal"))
check("and logs it", code:find("%[DECK%] tap refused"))
check("the raw flag check is gone from the penalty branch",
    not code:find("if self%.player_has_drawn then return true end"),
    "that single line is the bug")

check("the watchdog runs where the other lock watchdogs run",
    code:find("Watchdog releasing self%.waiting lock")
        and code:find("stale player_has_drawn"),
    "beside the ones that already existed, under the same conditions")

check("the deck refusal gives feedback, like the card branch does",
    (function()
        local i = code:find("%[DECK%] tap refused")
        return i and code:find("safe_shake_card", i, false)
    end)(),
    "a silent refusal is indistinguishable from a broken board")

check("the naive #self.deck > 0 gate is gone",
    not code:find("if #self%.deck > 0 then"),
    "that condition is false for the ~1.3s a reshuffle spends animating")
check("the deck gate uses the reshuffle queue", code:find("RQ%.is_running%(self%)"))
check("and requires it", code:find('require "modules%.reshuffle_queue"'))
check("the refusal flags carry reshuffling through", code:find("reshuffling = "))

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
