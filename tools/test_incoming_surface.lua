-- A CHALLENGE SHOULD NOT TAKE THE APP AWAY FROM YOU.
--
--   Run: lua5.4 tools/test_incoming_surface.lua
--
-- A plain game request used to open the full centred dialog: a scrim over the
-- whole app, a claim on the modal registry, and every screen's on_input
-- returning early for ten seconds. Every OTHER invite on this overlay — a
-- tournament, a battle, a knockout, a championship, a cup — has always been
-- the inline strip instead: same slot, same clock, same two buttons, and the
-- app still works underneath it.
--
-- Asked for: the plain request the same way. So the strip is now the only
-- surface.
--
-- It is a small change because the strip already drew a plain request
-- completely — incoming_budget existed to fall back to exactly that once the
-- blocking dialog had held input too long, and it is that fallback which is
-- now the only path.
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
check("a plain request no longer picks a surface — the strip is the only one",
  SRC:match("local as_banner = true") ~= nil,
  "open_dialog must not branch a plain request into the centred dialog")

check("nothing consults the budget for the surface any more",
  SRC:match("budget%.surface") == nil,
  "budget.surface returning \"dialog\" would put the scrim back")

check("but the budget still ticks, so a returning dialog is still measured",
  SRC:match("budget%.tick") ~= nil)

-- The copy is filled in for every request that did not bring its own. A
-- tournament invite arrives with a title and description already; a plain
-- challenge does not, and an empty strip is worse than the dialog was.
check("a request with no copy of its own is given some",
  SRC:match("if not d%.banner and not title then%s*\n%s*title, desc = plain_banner_text%(d%)") ~= nil)

-- ── AND IT MUST NOT BLOCK ───────────────────────────────────────────────────
-- The whole point. app_state.input_blocked() is true while ANY claim is held,
-- and every screen begins on_input with an early return on it.
check("the strip RELEASES the modal claim rather than taking it",
  SRC:match("if self%.dialog%.banner then%s*\n%s*app_state%.modal_close%(\"incoming\"%)") ~= nil,
  "a strip that claims input is the freeze this change exists to end")

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
