-- THE DECK EMPTIED INTO ONE HAND, AND NO PENALTY WAS INVOLVED.
--
--   Run: lua tools/test_draw_once_per_turn.lua
--
-- Reported: mostly at the START of a game, and in scorecap/knockout brackets.
-- A human turn, no penalty anywhere, and the deck drains card by card into the
-- player's hand. Nothing on the server capped it, so the whole run arrived as
-- one move carrying that many DRAW actions.
--
-- HOW ONE TAP BECAME THIRTY.
--
-- player_has_drawn is the ONLY thing enforcing one draw per turn.
-- turn_locks.board_may_touch_deck deliberately does not consult it (its own
-- note explains why: refusing on has_drawn broke the second card a skip owes),
-- so the flag at game.script's deck-tap branch is the whole guard.
--
-- game.script's watchdog then cleared that flag every frame, on this
-- reasoning:
--
--   "a flag still set in this state can only describe a draw that already
--    finished — i.e. a previous turn's"
--
-- It cannot. check_post_draw's `has_any` branch clears
-- is_local_action_locked and LEAVES THE TURN OPEN, because Matatu lets you
-- play the card you just drew. That is this turn's flag, sitting in exactly
-- the state the watchdog reads as stale:
--
--   tap -> draw 1, player_has_drawn = true, is_local_action_locked = true
--   check_post_draw -> something playable remains -> unlock, turn stays open
--   watchdog          -> clears player_has_drawn
--   tap -> draw 1 again ...
--
-- WHY THE START OF A GAME. has_any asks whether ANY card in hand is playable.
-- With a full seven-card hand that is near-certain, so the turn never closes
-- itself and the loop stays open. Later a small hand makes has_any false, the
-- turn ends after one draw, and the loop cannot run at all — which is exactly
-- the reported "mostly at the start".
--
-- The fix is drew_this_turn: set when this turn takes a draw, cleared at every
-- turn boundary (everywhere current_turn_actions is flushed) and by
-- reopen_kept_turn, so a skip still gets its second card.
--
-- These model the real flag interaction rather than importing game.script,
-- which is a Defold script and cannot be loaded standalone. The conditions are
-- transcribed from it and asserted against the source below, so the model
-- cannot drift from the code without the last section failing.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

local function read(p)
    local f = assert(io.open(ROOT .. p)); local s = f:read("*a"); f:close(); return s
end

----------------------------------------------------------------------
-- A board, and the three steps that act on it.
----------------------------------------------------------------------
local function new_board()
    return {
        deck = 39,
        hand = 7,
        drawn_this_move = 0,
        player_has_drawn = false,
        drew_this_turn   = false,
        is_animating     = false,
        is_local_action_locked = false,
        my_turn = true,
    }
end

-- game.script's deck-tap branch: `elseif not self.player_has_drawn then`
local function tap_deck(b)
    if b.player_has_drawn then return false end
    if b.deck <= 0 then return false end
    b.player_has_drawn = true
    b.drew_this_turn   = true          -- the fix
    b.is_local_action_locked = true
    b.deck = b.deck - 1
    b.hand = b.hand + 1
    b.drawn_this_move = b.drawn_this_move + 1
    return true
end

-- game_flow.check_post_draw: has_any -> unlock and KEEP the turn open.
local function check_post_draw(b, has_any)
    if has_any then
        b.is_local_action_locked = false
    else
        b.my_turn = false              -- turn ends
    end
end

-- game.script's watchdog, with the guard under test.
local function watchdog(b, with_fix)
    if not b.my_turn then return end
    if b.is_animating or b.is_local_action_locked then return end
    if not b.player_has_drawn then return end
    if with_fix and b.drew_this_turn then return end
    b.player_has_drawn = false
end

local function play_out(with_fix, has_any)
    local b = new_board()
    for _ = 1, 60 do                   -- a player tapping repeatedly
        if not tap_deck(b) then break end
        check_post_draw(b, has_any)
        watchdog(b, with_fix)
    end
    return b
end

----------------------------------------------------------------------
print("-- the loop, with a full hand (the start of a game) --")

local broken = play_out(false, true)
check("without the fix the deck drains", broken.deck, 0)
check("...into one hand, on ONE turn", broken.drawn_this_move, 39)

local fixed = play_out(true, true)
check("with the fix exactly one card is taken", fixed.drawn_this_move, 1)
check("and the deck is untouched beyond it", fixed.deck, 38)

print("\n-- and when nothing is playable, the turn simply ends --")
local ends = play_out(true, false)
check("still one card", ends.drawn_this_move, 1)
check("and the turn closed itself", ends.my_turn, false)

print("\n-- the watchdog must still do its real job --")
-- A flag that survived a missed turn transition: the PREVIOUS turn drew, the
-- boundary reset drew_this_turn, but player_has_drawn was left behind.
local stale = new_board()
stale.player_has_drawn = true          -- left over
stale.drew_this_turn   = false         -- this turn has not drawn
watchdog(stale, true)
check("a genuinely stale flag is still cleared", stale.player_has_drawn, false)
check("...so the player can draw on the new turn", tap_deck(stale), true)

print("\n-- a skip keeps the turn and owes a second card --")
local skip = new_board()
tap_deck(skip)                          -- drew, then played a skip
check("one card so far", skip.drawn_this_move, 1)
-- reopen_kept_turn clears BOTH flags
skip.player_has_drawn = false
skip.drew_this_turn   = false
skip.is_local_action_locked = false
check("the skip's second draw is allowed", tap_deck(skip), true)
check("and it is the second, not a thirtieth", skip.drawn_this_move, 2)

----------------------------------------------------------------------
print("\n-- the model matches the code it stands in for --")

local game_script = read("main/game.script")
local game_flow   = read("modules/game_flow.lua")
local game_state  = read("modules/game_state.lua")
local turn_locks  = read("modules/turn_locks.lua")

check("the watchdog consults drew_this_turn",
    game_script:find("player_has_drawn and not self%.drew_this_turn") ~= nil, true)
check("the deck tap still gates on player_has_drawn",
    game_script:find("elseif not self%.player_has_drawn then") ~= nil, true)
check("taking a draw marks the turn",
    game_script:find("self%.drew_this_turn = true") ~= nil, true)
check("the flag has a home in fresh_state",
    game_state:find("self%.drew_this_turn = false") ~= nil, true)
check("a skip re-open clears it too",
    game_flow:find("reopen_kept_turn.-self%.drew_this_turn = false") ~= nil, true)
check("check_post_draw still keeps the turn open when something is playable",
    game_flow:find("if has_any then\n        self%.is_local_action_locked = false") ~= nil, true)
-- The reason the flag is the only guard. If this ever changes, the fix above
-- becomes belt-and-braces rather than the fix.
-- Scoped to the two functions that ARE the deck gate. A whole-file search
-- runs straight past them into board_may_reopen_kept_turn, which mentions
-- has_drawn for an unrelated reason and makes the check pass vacuously.
local gate = (turn_locks:match("function M%.may_touch_deck.-\nend") or "")
    .. (turn_locks:match("function M%.board_may_touch_deck.-\nend") or "")
check("the deck gate was actually found", #gate > 0, true)
check("and it still does not consult has_drawn",
    gate:find("has_drawn") == nil, true)

-- EVERY turn boundary resets it, or the next turn inherits a blocked deck.
local boundaries = select(2, game_script:gsub("self%.drew_this_turn = false", ""))
  + select(2, game_flow:gsub("self%.drew_this_turn = false", ""))
  + select(2, game_state:gsub("self%.drew_this_turn = false", ""))
  + select(2, read("modules/online_handler.lua"):gsub("self%.drew_this_turn = false", ""))
  + select(2, read("modules/offline_handler.lua"):gsub("self%.drew_this_turn = false", ""))
  + select(2, read("modules/tournament4.lua"):gsub("self%.drew_this_turn = false", ""))
local flushes = select(2, game_script:gsub("self%.current_turn_actions = {}", ""))
  + select(2, game_state:gsub("self%.current_turn_actions = {}", ""))
  + select(2, read("modules/online_handler.lua"):gsub("self%.current_turn_actions = {}", ""))
  + select(2, read("modules/offline_handler.lua"):gsub("self%.current_turn_actions = {}", ""))
  + select(2, read("modules/tournament4.lua"):gsub("self%.current_turn_actions = {}", ""))
check("reset at every action-buffer flush, plus the skip re-open",
    boundaries >= flushes, true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
