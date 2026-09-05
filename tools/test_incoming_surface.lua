-- TWO SURFACES, AND WHICH INVITE GETS WHICH.
--
--   Run: lua5.4 tools/test_incoming_surface.lua
--
-- The choice is not stylistic:
--
--   a TOURNAMENT, battle, knockout, championship or cup invite is the inline
--     strip. It is one of several a player may be offered, often while they
--     are doing something else, and none of them needs answering — letting one
--     run out costs nothing
--   a plain GAME REQUEST is one person asking THIS player for a game, with ten
--     seconds on it and somebody watching the other end. It is the one invite
--     where not answering IS an answer, and it takes the screen
--
-- The plain request was briefly made the strip too, on the argument that being
-- challenged is not worth taking the app away from someone for. Asked for
-- back: on the strip it read as a notification among notifications, which is
-- exactly what it is not.
--
-- THE BUDGET IS WHY THE DIALOG IS SAFE, and is the part worth guarding here:
-- the blocking dialog holds the app's input, and a burst of challenges each
-- restarting ten seconds could hold it indefinitely. Past the budget it
-- demotes to the strip, so every request is still shown and still acceptable
-- while the app works again.
--
-- Two halves, following test_join_banner.lua: the COPY driven as the real
-- function, lifted out of the gui_script and run; and the DECISIONS read out
-- of the source, because a .gui_script is not requireable and the things that
-- would regress here are all one-line branches.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end
local function eq(name, got, want) check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want))) end

local f = assert(io.open(here .. "/../main/incoming.gui_script"))
local SRC = f:read("*a"); f:close()

-- ── THE COPY, RUN FOR REAL ──────────────────────────────────────────────────
-- Lifted out and loaded rather than re-implemented: a copy of the function
-- would agree with itself forever and with the strip never.
local function lift(name)
  local body = SRC:match("(local function " .. name .. "%(.-\nend)")
  assert(body, "could not lift " .. name)
  local commas = SRC:match("(local function commas%(.-end)")
  local chunk = assert(load(commas .. "\n" .. body .. "\nreturn " .. name))
  return chunk()
end

local plain_banner_text = lift("plain_banner_text")

local title, desc = plain_banner_text({ name = "Scovia", stake = { amount = 500 } })
eq("the strip names it a game request", title, "GAME REQUEST  -  SCOVIA")
eq("and states what is being played for, not the entry", desc, "1,000 Coins pot")

local t2, d2 = plain_banner_text({ name = "Ben", stake = { amount = 0 } })
eq("a free match says so rather than showing 0", d2, "Practice Mode")
eq("and still names the sender", t2, "GAME REQUEST  -  BEN")

-- A request whose sender is unknown must still produce a readable strip: an
-- empty title is a blank bar the player cannot act on or explain.
local t3, d3 = plain_banner_text({})
eq("an unnamed sender falls back to a person", t3, "GAME REQUEST  -  A PLAYER")
eq("and no stake reads as practice", d3, "Practice Mode")

local t4 = plain_banner_text({ name = "a very long username here", stake = {} })
check("a long name is not truncated into nonsense", #t4 > 20)

-- ── THE SURFACE ─────────────────────────────────────────────────────────────
-- THE DECISION, NOT THE CALL.
--
-- The check that used to be here asserted that budget.surface was CALLED. It
-- was, and every plain challenge still drew as a banner: surface answers with
-- a WORD, and in Lua the string "dialog" is truthy, so
--
--     local as_banner = budget.surface(...)
--
-- was true for both answers. A test that reads the call and not the result
-- passes on exactly the code it exists to catch — which is what it did, four
-- reports running.
local budget = require("modules.incoming_budget")
do
  local st = budget.new()
  check("a plain challenge takes the dialog", budget.surface(st, false) == "dialog")
  check("an invite takes the strip", budget.surface(st, true) == "banner")
  -- Both answers are strings, and both are truthy. This is the trap.
  check("...and both answers are truthy, which is why they must be COMPARED",
    budget.surface(st, false) and budget.surface(st, true) and true or false)
  st.cooldown = 5
  check("a burst demotes even a plain challenge", budget.surface(st, false) == "banner")
end

check("the surface is compared, never coerced",
  SRC:match('local as_banner = budget%.surface%(self%.budget, d%.banner and true or false%) == "banner"') ~= nil,
  'without `== "banner"` the string "dialog" reads as true and everything is a strip')

check("...and the budget can still take the dialog away under a burst",
  SRC:match("budget%.tick") ~= nil and SRC:match('== "demote"') ~= nil,
  "without this a stream of challenges holds the whole app input-dead")

check("a demoted request is converted rather than dropped",
  SRC:match("self%.dialog%.banner = true") ~= nil
    and SRC:match("app_state%.modal_close%(\"incoming\"%)") ~= nil,
  "degrading loses the interruption; dropping would lose the request")

-- THE CLAIM FOLLOWS THE SURFACE, IN BOTH DIRECTIONS.
--
-- This is the freeze: a banner that REPLACED a full dialog used to leave the
-- dialog's claim standing, and every screen begins on_input with
-- `if app_state.input_blocked() then return false end` — so the visible thing
-- was a strip that lets taps through and the actual state was an app that
-- accepted none.
check("a strip releases the claim, a dialog takes it",
  SRC:match("if self%.dialog%.banner then%s*\n%s*app_state%.modal_close%(\"incoming\"%)%s*\n%s*else%s*\n%s*app_state%.modal_open%(\"incoming\"%)") ~= nil)

-- The copy is for the STRIP. A tournament invite arrives with a title and a
-- description already; a plain challenge does not, and the dialog composes its
-- own from the fields — so this fills in exactly when a plain request is going
-- to be drawn as a strip, which is when a burst has demoted it.
check("a demoted request is given the copy the strip needs",
  SRC:match("if as_banner and not d%.banner and not title then%s*\n%s*title, desc = plain_banner_text%(d%)") ~= nil)

-- ── WHAT MUST NOT HAVE BEEN LOST ────────────────────────────────────────────
-- The strip is less disruptive, not less complete. An unanswered request still
-- has to be declined when its clock runs out, or the opponent watches a
-- spinner until the server's own timeout; and a request replaced by a newer
-- one is declined immediately for the same reason.
check("an expired request is still declined for the player",
  SRC:match("if self%.dialog%.time_left <= 0 then.-ws%.decline_game_request") ~= nil)

check("a replaced request is still declined rather than dropped",
  SRC:match("pcall%(ws%.decline_game_request, prev%.request_id%)") ~= nil)

check("a cup invitation is still never auto-declined — nobody is waiting on it",
  SRC:match("if not self%.dialog%.cup_invite") ~= nil)

check("the arrival still makes a sound",
  SRC:match("msg%.post, \"#snd_notify\"") ~= nil)

-- ── WHICH INVITE IS WHICH, DRIVEN FOR REAL ──────────────────────────────────
--
-- The predicate the whole split turns on, and the one `gameType` cannot
-- answer: a BATTLE — one player challenging another to a single game at a
-- stake — goes out as gameType TOURNAMENT with a tournament id, because that
-- is how the battle plumbing routes it. Every check of the old shape
--
--     raw.gameType == "TOURNAMENT" or raw.tournament
--
-- therefore called a normal challenge a tournament invite and gave it the
-- strip. Reported twice, the second time as "incoming game request for normal
-- game is still showing up in inline banner".
package.path = here .. "/../?.lua;" .. package.path
local champ = require("modules.championship")

local function ladder(raw, me) return champ.is_ladder(raw, me) end

check("a plain challenge is a game", ladder({ stake = { amount = 200 } }) == false)
check("...and so is nothing at all", ladder(nil) == false and ladder({}) == false)

-- A one-level battle. gameType says TOURNAMENT and it is not one.
check("a BATTLE is a game, whatever its gameType says",
  ladder({ gameType = "TOURNAMENT", tournamentId = "t1",
           tournament = { _id = "t1", levels = 1, matchFormat = 3 } }) == false,
  "this is the one the report is about")
check("...including one whose levels arrive as a list of one",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "t1", levels = { {} }, matchFormat = 3 } }) == false)

-- And the ladders, which keep the strip.
check("a knockout is a ladder",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "t1", levels = 1, matchType = "KNOCKOUT" } }) == true)
check("...and so is a single-game format, which is how a knockout is spelled",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "t1", levels = 1, matchFormat = 1 } }) == true)
check("a multi-level tournament is a ladder",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "t1", levels = 7, matchFormat = 3 } }) == true)
check("the championship is a ladder",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "t1", isChampionship = true, levels = 7 } }) == true)
-- A payload that says nothing about itself, recognised by its id against the
-- ladder this player is already in — which is how championship.known_id reads
-- it, off their own tournament list.
check("...and one recognised only by the player's own joined ladder",
  ladder({ gameType = "TOURNAMENT", tournament = { _id = "champ-1", levels = 1, matchFormat = 3 } },
         { tournaments = { { _id = "champ-1", isChampionship = true, levels = 7 } } }) == true)

-- A tournamentId with no document behind it. Unlabelled, and the dialog is the
-- surface that cannot be missed.
check("an invite the payload cannot explain is treated as a game",
  ladder({ gameType = "TOURNAMENT", tournamentId = "t1" }) == false)

-- ── AND BOTH SURFACES ASK IT ────────────────────────────────────────────────
-- They must answer identically: the overlay stands down for exactly what the
-- online screen draws, so two different answers show one request twice or not
-- at all.
do
  local f = assert(io.open(here .. "/../main/online.gui_script"))
  local ONLINE = f:read("*a"); f:close()
  check("the online screen opens its inline strip only for a ladder",
    ONLINE:find("if champ%.is_ladder%(raw, ws%.current_user_data%) then open_banner") ~= nil)
  check("...and the overlay decides with the same call",
    SRC:find("local is_tb = champ%.is_ladder%(raw, ws%.current_user_data%)") ~= nil)
  check("...so neither is left branching on gameType",
    ONLINE:find('raw%.gameType == "TOURNAMENT"') == nil
      and SRC:find('raw%.gameType == "TOURNAMENT" or raw%.gameType == "BATTLE"') == nil)
end

print(("incoming surface: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
