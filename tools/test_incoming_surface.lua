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
check("the surface is asked for, not assumed",
  SRC:match("local as_banner = budget%.surface%(self%.budget, d%.banner and true or false%)") ~= nil,
  "a plain request takes the centred dialog; an invite says banner for itself")

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

print(("incoming surface: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
