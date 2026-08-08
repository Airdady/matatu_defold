-- THE PLAYER CAN NEITHER PLAY NOR DRAW AFTER THE OPPONENT'S PENALTY.
--
--   Run: lua tools/test_suit_lock_release.lua
--
-- is_suit_selection_active was set in exactly ONE place — the player played a
-- wildcard and owes a suit — and cleared in exactly ONE place: the player
-- picked a suit. But the picker overlay is closed from FIFTEEN places, and not
-- one of them is a selection. game_flow closes it on nearly every play
-- resolution, online_handler closes it on every opponent PLAY and on every
-- state sync that carries no chosen suit.
--
-- So any close that was not a selection left the flag set with no picker on
-- screen. on_input then swallows every tap, on the hand AND on the deck:
--
--   card tap   if not is_player_turn or waiting or is_local_action_locked
--              or is_suit_selection_active -> shake and return
--   deck tap   same four conditions -> return
--
-- which is exactly "unable to play or draw". And nothing recovered it: the
-- stuck-lock watchdog skips itself while a suit selection is "active", and
-- there was no watchdog for the flag itself.
--
-- A Matatu Joker is both a penalty card and a wildcard, which is why this
-- surfaces when the opponent plays a penalty.
--
-- The picker now reports its own closure and the flag follows the picker.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local gui_src   = slurp("main/suit_select.gui_script")
local game_src  = slurp("main/game.script")
local flow_src  = slurp("modules/game_flow.lua")
local ws_src    = slurp("modules/websocket_manager.lua")
local on_src    = slurp("modules/online_handler.lua")

-- ── the picker reports its own closure ─────────────────────────────────────
print("the picker says when it closes")

-- Sliced by markers rather than by a lazy pattern: the branch contains nested
-- `end`s (an animation callback), so ".-end" stops in the wrong place and the
-- assertion silently reads a truncated block.
local close_at = gui_src:find('elseif message%.mode == "close" then')
local branch_end = gui_src:find('elseif message_id == hash%("reset_hud"%)', close_at or 1)
local close_branch = close_at and gui_src:sub(close_at, (branch_end or #gui_src))

check_true("a close posts back to the game",
    close_branch and close_branch:find('msg%.post%("/controller#game_logic", "suit_select_closed"%)'),
    "the game has no other way to learn the picker is gone")

-- The post must NOT sit inside the is_enabled check: a close can arrive in the
-- 0.05s between the flag being set and the picker actually opening, and that
-- is precisely the case that stranded the flag. Everything from the
-- is_enabled test up to the post is that block.
-- Compared by NESTING, via indentation. Searching the text between the guard
-- and the post for the post itself is vacuous — it can never find it — so that
-- form of the check passes whether the post is inside the block or outside it.
local guard_indent = close_branch and close_branch:match("\n(%s*)if gui%.is_enabled%(self%.ss_overlay%) then")
local post_indent  = close_branch and close_branch:match('\n(%s*)msg%.post%("/controller#game_logic", "suit_select_closed"%)')
check_true("and posts even when the overlay was not up yet",
    guard_indent and post_indent and #post_indent == #guard_indent,
    string.format("post is nested at %s vs guard at %s — inside the is_enabled block, "
        .. "which is the stranding case",
        tostring(post_indent and #post_indent), tostring(guard_indent and #guard_indent)))

print("")
print("and the game releases the input lock on it")
check_true("there is a handler",
    game_src:find('message_id == hash%("suit_select_closed"%)') ~= nil, "handler missing")
local handler = game_src:match('message_id == hash%("suit_select_closed"%) then(.-)elseif')
check_true("which clears the flag",
    handler and handler:find("self%.is_suit_selection_active = false"), "flag not cleared")
check_true("and re-validates the hand so the cards light up again",
    handler and handler:find("RE%.pre_validate_hand%(self%)"), "hand left un-validated")

check_true("the open re-asserts the flag when it actually appears",
    flow_src:match("timer%.delay%(0%.05, false, function%(%)(.-)end%)")
        and flow_src:match("timer%.delay%(0%.05, false, function%(%)(.-)end%)")
            :find("self%.is_suit_selection_active = true"),
    "otherwise a close inside the 0.05s window leaves a picker the game thinks is absent")

-- ── the freeze itself, simulated ───────────────────────────────────────────
--
-- The four conditions on_input gates both the hand and the deck with, driven
-- directly. This is the shape of the bug, not a paraphrase of it.
print("")
print("the input gate, before and after")

local function blocked(s)
    return (not s.is_player_turn) or s.waiting or s.is_local_action_locked
        or s.is_suit_selection_active
end

-- The reported sequence: my turn, I play a wildcard, the opponent's penalty
-- lands and closes my picker.
local state = {
    is_player_turn = true, waiting = false,
    is_local_action_locked = false, is_suit_selection_active = false,
}
check("free to act at the start", blocked(state), false)

state.is_suit_selection_active = true          -- played a wildcard
check("locked while genuinely choosing a suit", blocked(state), true)

-- The opponent's PLAY posts a close. Old behaviour: nothing cleared the flag.
local old = { is_player_turn = true, waiting = false,
    is_local_action_locked = false, is_suit_selection_active = true }
check("OLD: still locked after the picker vanished", blocked(old), true)

-- New behaviour: the picker reports the close and the flag follows it.
state.is_suit_selection_active = false         -- suit_select_closed handler
check("NEW: free to act once the picker is gone", blocked(state), false)

-- And the watchdog that should have rescued this was itself disabled by the
-- same flag — worth pinning, since that is why it never self-corrected.
local watchdog = game_src:match("if self%.is_player_turn%(%) and not self%.is_processing_move and #self%.move_queue == 0\n%s*and not self%.is_animating and not self%.waiting and not self%.is_suit_selection_active(.-)end")
check_true("the stuck-lock watchdog does skip itself while a selection is active",
    watchdog ~= nil,
    "if this stops being true the freeze has a second escape route, which is fine")

-- ── no move survives the end of its game ───────────────────────────────────
print("")
print("no move event goes through once the game has ended")

check_true("send_move refuses when there is no live game",
    ws_src:find('if M%.active_game_id == "" then') ~= nil
        and ws_src:match('if M%.active_game_id == "" then(.-)end'):find("return false"),
    "active_game_id is cleared on GAME_OVER, so empty means no game to move in")

check_true("and refuses a move belonging to a different game",
    ws_src:find("tostring%(game_id%) ~= tostring%(M%.active_game_id%)") ~= nil,
    "a move from the finished round must not land in the next one")

-- The guard has to sit BEFORE the send, or it guards nothing.
local sm = ws_src:match("function M%.send_move%((.-)\nend\n")
check_true("the refusals come before the payload is sent",
    sm and sm:find('M%.active_game_id == ""')
        and sm:find("M%.send_message%(\"MOVE\"")
        and sm:find('M%.active_game_id == ""') < sm:find("M%.send_message%(\"MOVE\""),
    "guard must precede the send")

check_true("end_turn stops early on a finished game too",
    on_src:match("function M%.end_turn%(self%)(.-)local actions_to_send")
        and on_src:match("function M%.end_turn%(self%)(.-)local actions_to_send")
            :find("if self%.game_over then"),
    "keeps the local turn bookkeeping from running on a finished game")

-- on_input's existing game-over gate must stay: it is the first line of
-- defence, and the transport guard is the second.
check_true("and taps are still refused at the input layer",
    game_src:find("if app%.board_locked or self%.game_over or self%.input_locked_for_game_over then") ~= nil,
    "the input gate should remain as well")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
