-- A PARTY PLAYED TO A SCORE CAP IS A KNOCKOUT BY ANOTHER NAME.
--
--   Run: lua5.3 tools/test_party_scorecap.lua
--
-- Pick SCORECAP at a party table and the SERVER already runs the whole thing:
-- each hand ends, the cards left in every surviving hand are added to that
-- player's running total (endPartyGame's continueCappedParty), anybody at or
-- over the cap is out, and the rest are re-dealt. partyRules says as much in
-- its own words — the cap ladder is "deliberately the SAME ladder a KNOCKOUT
-- chamber uses", and isEliminatedAtCap gives "the same reading a KNOCKOUT
-- chamber gives it".
--
-- THE CLIENT DREW AN ORDINARY BOARD ANYWAY. Everything the score-cap display
-- does hangs off one predicate, and it only ever said yes to matchType
-- KNOCKOUT or ELIMINATION. A party's matchType is 'PARTY' and it carries the
-- cap in its own fields, so the standings chamber never opened, the running
-- totals were never pushed, and a seat that crossed the cap simply vanished
-- with nothing on screen to say why. The magic was all present and gated
-- behind a name this state does not use.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path

local SIM = dofile(ROOT .. "tools/defold_sim.lua")
SIM.install_gui_stub()
_G.sys.get_config_string = function() return "" end
_G.sys.get_config = function() return "" end
_G.http = { request = function() end }

local OH = require("modules.online_handler")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

local function party(over)
    local s = {
        matchType = "PARTY", partyMode = "SCORECAP", scoreCap = 200,
        players = {
            a = { username = "A", cumulativeScore = 0 },
            b = { username = "B", cumulativeScore = 0 },
        },
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

----------------------------------------------------------------------
print("A CAPPED PARTY IS A SCORE-CAP GAME")
----------------------------------------------------------------------
check("a party in SCORECAP mode", OH.is_score_capped(party()), true)
check("...whatever its cap is", OH.is_score_capped(party({ scoreCap = 500 })), true)
check("...and case does not matter", OH.is_score_capped(party({ partyMode = "scorecap" })), true)

-- A mid-game sync need not echo matchType — which is exactly why the call
-- sites keep a sticky flag — so the party branch does not ask for one. The
-- mode and the cap are the facts that decide this.
check("a sync that dropped matchType is still capped",
    OH.is_score_capped({ partyMode = "SCORECAP", scoreCap = 200 }), true)

----------------------------------------------------------------------
print("AND A PARTY THAT IS NOT CAPPED IS NOT ONE")
----------------------------------------------------------------------
check("a NORMAL party", OH.is_score_capped(party({ partyMode = "NORMAL" })), false)
-- Built without the key rather than with a nil value: assigning nil in Lua is
-- not the same as omitting it, and a fixture that cannot express "absent"
-- cannot test it.
check("a party with no mode at all", OH.is_score_capped({
    matchType = "PARTY", scoreCap = 200, players = { a = {}, b = {} },
}), false)
-- partyMode can read SCORECAP with no meaningful cap attached. The server
-- treats that as a NORMAL party rather than a table where everybody is out on
-- the first hand (isEliminatedAtCap), so this must agree with it.
check("SCORECAP with no cap is not a capped game",
    OH.is_score_capped(party({ scoreCap = 0 })), false)
check("...nor with a nonsense one",
    OH.is_score_capped(party({ scoreCap = "lots" })), false)
check("...nor a negative one", OH.is_score_capped(party({ scoreCap = -200 })), false)

----------------------------------------------------------------------
print("AND THE KNOCKOUT BATTLE IT WAS ALWAYS TRUE FOR STILL IS")
----------------------------------------------------------------------
check("a knockout battle", OH.is_score_capped({ matchType = "KNOCKOUT" }), true)
check("...and its legacy name", OH.is_score_capped({ matchType = "ELIMINATION" }), true)
check("an ordinary duel is not", OH.is_score_capped({ matchType = "NORMAL" }), false)
check("nor is a bare state", OH.is_score_capped({}), false)
check("nor nothing at all", OH.is_score_capped(nil), false)

----------------------------------------------------------------------
print("THE STANDINGS BOARD GOES WHERE NOBODY IS SITTING")
----------------------------------------------------------------------
-- left_center is halfway down the left edge: empty in a duel, and exactly
-- where the LEFT SEAT's avatar and its arch of cards are at a party of three
-- or more. Four rows of standings over an opponent's hand is worse than no
-- standings at all.
check("two seats keep the left edge", OH.chamber_placement(party()), "left_center")

local three = party()
three.players.c = { username = "C", cumulativeScore = 0 }
check("three take the corner instead", OH.chamber_placement(three), "top_left")

local four = party()
four.players.c = { username = "C" }
four.players.d = { username = "D" }
check("and so do four", OH.chamber_placement(four), "top_left")
check("a state with no players at all does not crash",
    OH.chamber_placement({}), "left_center")

----------------------------------------------------------------------
print("AND THE BOARD IS ACTUALLY WIRED TO IT")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "modules/online_handler.lua"):read("a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

    -- One predicate, three jobs: it suppresses the battle scoreboard, it
    -- builds the chamber at the deal, and it pushes the running totals on
    -- every sync. If any of these stops asking, a capped party silently goes
    -- back to looking like an ordinary game.
    ok("the local alias is the exported rule, not a second copy",
        code:match("local is_knockout_state = M%.is_score_capped") ~= nil)
    ok("the battle scoreboard stands down for it",
        code:match("if is_knockout_state%(state%) or self%._is_knockout then.-update_scoreboard.-show = false") ~= nil)
    ok("the chamber is built when the cards are dealt",
        code:match("self%._is_knockout = is_knockout_state%(state%)") ~= nil
        and code:match("if self%._is_knockout then knockout_init_chamber") ~= nil)
    ok("...seeded from the server's own cumulative totals",
        code:match("if self%._is_knockout then M%.seed_knockout_totals") ~= nil)
    ok("and the totals are pushed on every sync",
        code:match("if is_knockout_state%(state%) then knockout_update_chamber%(self, state%) end") ~= nil)

    -- The rows come from the state, so a party of four produces four of them —
    -- the chamber has always been N-row (t4_ui keys them by name and sorts
    -- them), it was only ever handed two.
    ok("a row per player, read off the state",
        code:match("for pid, p in pairs%(%(state or {}%)%.players or {}%) do.-cumulativeScore") ~= nil)
    ok("...carrying the elimination flag the server sets",
        code:match("eliminated = p%.eliminated and true or false") ~= nil)

    -- Each hand of a capped party arrives as PARTY_NEXT_HAND and rebuilds the
    -- board, which is what makes the totals cumulate on screen: the chamber is
    -- re-seeded from the server's running score every deal.
    ok("every fresh hand rebuilds the board",
        code:match('ws%.on%("party_next_hand".-M%.start_game') ~= nil)
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
