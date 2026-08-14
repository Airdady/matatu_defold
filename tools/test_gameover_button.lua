-- "LEVEL CLEARED / ADVANCING..." WITH "PLAY AGAIN" UNDERNEATH.
--
-- This regression came back three times, each time because the NEXT LEVEL
-- label was gated on something further away than the branch it sits in:
--
--   1. is_tournament_owner — the backend's "this side climbs the ladder" flag.
--      Nobody owns the championship, so it was false for BOTH players.
--   2. a championship test off res.tournamentData — needs fields the payload
--      does not always carry, so it answered false whenever they were absent.
--
-- Each gate could only ever SUPPRESS the right answer, never produce it. That
-- is the shape of the bug, and it is why the title changed while the button
-- under it did not: the title is set in the same branch, ungated.
--
-- THE BRANCH IS ALREADY THE PROOF. `elseif res.isMatchComplete` is only
-- reachable when res.tournamentCompleted is false, and endGame forces
-- tournamentCompleted on any ONE-level tournament the moment it has a match
-- winner (isOneLevelTournament there). So being in that branch means: a
-- multi-level ladder, mid-run, with a level just decided. Winning it means
-- advancing. Nothing further needs establishing, and anything that asks for
-- more can only take the answer away again.
--
-- Source-level, because the decision lives inside a gui_script's on_message and
-- the countdown/label nodes only exist inside a running Defold GUI context.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end

local f = assert(io.open(here .. "/../main/gameover.gui_script"))
local src = f:read("*a"); f:close()

-- Comments are stripped before anything is asserted. The block explaining WHY
-- the ownership gate was removed names the very identifiers these checks look
-- for, and a test that a comment can fail is a test nobody trusts.
local function strip(s)
  return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

-- The level-clear branch: from `elseif res.isMatchComplete` to the end of the
-- tournament block.
local branch = src:match("elseif res%.isMatchComplete then(.-)\n\t\t\tend\n")
check("the level-clear branch is findable", branch ~= nil)
branch = branch or ""

local code = strip(branch)

check("it sets NEXT LEVEL", code:find('again_txt = "NEXT LEVEL"') ~= nil)

-- The whole point. A win is the only condition.
check("gated on winning and nothing else",
  code:find("if is_victory then") ~= nil,
  "a gate wider than `is_victory` is how this broke three times")

check("not gated on ownership", code:find("is_tournament_owner") == nil)
check("not gated on a championship test", code:find("is_championship") == nil)

-- It must also set the route flag, or the button says NEXT LEVEL and then
-- fires a rematch anyway.
check("routes to the map instead of replaying",
  code:find("self%._tournament_next_level = true") ~= nil)

-- The animation target is separate from the route, because `or 0` is TRUTHY in
-- Lua and a missing level used to route to a target the map cannot animate.
check("the animation target is separate from the route",
  code:find("self%._tournament_level_target") ~= nil)
check("and a missing level does not become level 0",
  code:find("lvl >= 1") ~= nil)

-- NOTHING MAY OVERWRITE THE LABEL AFTER IT IS DECIDED.
--
-- again_txt is assigned in several branches and then written to the node once.
-- An assignment after that write would be invisible; an unconditional one
-- before it would undo this fix from a distance.
local set_at = src:find("gui%.set_text%(self%.n_again_lbl, again_txt%)")
check("the label is written to the node", set_at ~= nil)
if set_at then
  local after = src:sub(set_at)
  check("nothing reassigns again_txt after it is written",
    after:find("again_txt%s*=") == nil)

  -- Everything between the level-clear branch and the write must be guarded.
  -- The 4-player bracket branches do set PLAY AGAIN, and legitimately so, but
  -- they are conditional on t4_* fields an online tournament never carries.
  local between = src:sub(src:find('again_txt = "NEXT LEVEL"') or 1, set_at)
  for line in between:gmatch("[^\n]+") do
    if line:find('again_txt%s*=%s*"PLAY AGAIN"') and not line:find("^%s*%-%-") then
      check("a PLAY AGAIN reset after the level-clear branch is guarded",
        between:find("message%.t4_champion") ~= nil or between:find("message%.t4_human_out") ~= nil,
        "unguarded PLAY AGAIN would undo NEXT LEVEL")
      break
    end
  end
end

-- The button's own handler has to honour the route flag before it replays.
local handler = src:match("if self%._tournament_next_level then(.-)end")
check("the handler routes to the tournament screen",
  handler ~= nil and handler:find('goto_tournaments') ~= nil)
check("and does it BEFORE posting a replay",
  set_at ~= nil
  and (src:find("self%._tournament_next_level then") or 0) < (src:find('msg%.post%(GAME, "replay"%)') or math.huge))

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
