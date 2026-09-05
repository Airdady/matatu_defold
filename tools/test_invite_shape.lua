-- AN INVITE THAT COULD NOT SAY WHAT IT WAS.
--
--   Run: lua5.3 tools/test_invite_shape.lua
--
-- Both surfaces that show an incoming request — the global overlay in
-- main/incoming.gui_script and the online screen's inline strip — decide what
-- they are looking at by handing `data.tournament` to modules/championship:
--
--   champ.is_ladder   which SURFACE it takes: the strip for a run at
--                     something, the centred dialog for a plain challenge
--   champ.kind        the badge, and half the title
--   champ.format_text the line under it — "SCORE CAP 200", or "Best of 3"
--
-- THE SERVER NEVER SENT THAT FIELD. handleGameRequest's GAME_REQUEST payload
-- carried a requestId, the two players, a stake, a gameType of 'TOURNAMENT'
-- and a tournament ID — and nothing about the match. It also destructured the
-- request without `matchType`, so the one sender that did put it on the wire
-- (start_invite_search) had it dropped one line after it arrived.
--
-- So every battle invite ever sent was described from an empty table: kind
-- falls through to nil, is_ladder answers false, and a knockout played to a
-- score cap is announced as an ordinary game — reported as "the play mode is
-- scorecap and the incoming banner shows normal".
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path

local champ = require("modules.championship")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

-- The payload as it reaches the client: websocket_manager parks the whole
-- GAME_REQUEST data as `raw`, and both surfaces read raw.tournament off it.
local function invite(tournament)
    return {
        requestId = "r1", tournamentId = "t1", gameType = "TOURNAMENT",
        user = { _id = "u2", username = "OPPONENT" },
        stake = { amount = 500, charge = 50 },
        tournament = tournament,
    }
end
local me = { _id = "u1", tournamentProgress = {} }

----------------------------------------------------------------------
print("WITHOUT THE SHAPE, EVERY INVITE IS AN ORDINARY GAME")
----------------------------------------------------------------------
-- This is the payload as it was: a tournament id and nothing to read.
local blind = invite(nil)
check("nothing to say what it is", champ.kind(nil, me), nil)
check("...so it is not a ladder", champ.is_ladder(blind, me), false)
check("...and the line under it guesses a best-of",
    champ.format_text(nil, champ.kind(nil, me)), "Best of 3")

----------------------------------------------------------------------
print("WITH IT, A KNOCKOUT SAYS SO")
----------------------------------------------------------------------
local ko = { matchType = "KNOCKOUT", scoreCap = 200, matchFormat = 1, levels = { {} } }
local ko_invite = invite(ko)
check("the badge names it", champ.kind(ko, me), "KNOCKOUT")
check("...it takes the ladder strip", champ.is_ladder(ko_invite, me), true)
check("...and the line under it is the CAP, not a best-of",
    champ.format_text(ko, "KNOCKOUT"), "SCORE CAP 200")
check("a different cap reads differently",
    champ.format_text({ matchType = "KNOCKOUT", scoreCap = 500 }, "KNOCKOUT"), "SCORE CAP 500")

----------------------------------------------------------------------
print("AND AN ORDINARY BATTLE STILL READS AS ONE")
----------------------------------------------------------------------
-- The fix must not turn every invite into a knockout: a one-level battle is a
-- game, and it takes the dialog.
local battle = { matchType = "NORMAL", matchFormat = 3, levels = { {} } }
check("a best-of-three battle", champ.kind(battle, me), "BATTLE")
check("...is not a ladder", champ.is_ladder(invite(battle), me), false)
check("...and says how long it is", champ.format_text(battle, "BATTLE"), "Best of 3")

----------------------------------------------------------------------
print("THE SERVER PUTS IT ON THE WIRE, AT BOTH SEND SITES")
----------------------------------------------------------------------
do
    local src = io.open("/home/user/be_matatu/src/matatu/websocket/handlers/handleGameRequest.ts")
    if not src then
        print("  (backend not present — skipped)")
    else
        local code = src:read("a"):gsub("//[^\n]*", ""):gsub("/%*.-%*/", "")

        ok("the request's matchType is read rather than dropped",
            code:match("matchType: requestedMatchType") ~= nil)
        ok("the shape is read off the battle DOCUMENT",
            code:match("Tournament%.findById%(String%(tournamentId%)%)") ~= nil
            and code:match("matchType scoreCap matchFormat levels name type scope partyMode") ~= nil)
        -- Two GAME_REQUEST sends: the ordinary one, and the one that queues an
        -- invite behind a game already in progress. An invite that is right on
        -- one path and blank on the other is the same bug, half the time.
        local n = select(2, code:gsub("tournament: await inviteShapeOf", ""))
            + select(2, code:gsub("tournament: inviteShape", ""))
        check("both invites carry it", n, 2)
        ok("...and a document that cannot be read does not fail the invite",
            code:match("catch %(err%)[\n%s]*{[^}]*console%.warn%('%[GameRequest%]") ~= nil)
    end
end

----------------------------------------------------------------------
print("AND THE CHALLENGE FROM THE BATTLES LIST SAYS IT TOO")
----------------------------------------------------------------------
do
    local code = io.open(ROOT .. "main/online.gui_script"):read("a")
    -- It sent a tournament id and nothing else, unlike start_invite_search
    -- which has always sent matchType.
    ok("the battles-tab challenge names the match type",
        code:match("tournamentId = u%.myBattle%._id or u%.myBattle%.id,[\n%s]*rules = u%.myBattle%.rules,[\n%s]*matchType") ~= nil)
    ok("...and carries the cap with it",
        code:match("scoreCap = tonumber%(u%.myBattle%.scoreCap%)") ~= nil)
    local right = io.open(ROOT .. "modules/online_right.lua"):read("a")
    ok("the invite search always did", right:match("matchType%s*=%s*%(tostring%(mb%.matchType") ~= nil)
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
