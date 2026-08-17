-- THE INVITE THAT ASKS FOR MONEY.
--
--   Run: lua5.4 tools/test_join_banner.lua
--
-- Championship invites now reach every eligible player, joined or not — a
-- ladder nobody may be invited to fills up very slowly, since the only other
-- way in is a JOIN button on a screen most players never open. So one strip
-- has to carry two different questions:
--
--   already in   ACCEPT / DECLINE. A match, on terms already paid for.
--   not in       JOIN / CANCEL, with the one-off entry fee stated. Tapping it
--                enters them AND starts the match, and it costs real coins.
--
-- Two halves here. The RULE — which question is being asked, what it costs,
-- what is being played for — under plain Lua against the real module. And the
-- GEOMETRY of the join strip, read out of both banner files, because they draw
-- the same invite and a difference between them would mean one request looked
-- like two.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local champ = require("modules.championship")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

local seven = { 1, 2, 3, 4, 5, 6, 7 }
local user_data = { tournaments = {
  { _id = "champ-1", scope = "GLOBAL", levels = seven, status = "active" },
} }

-- The invite as the server sends it now.
local function invite(over)
  local p = {
    requestId = "r1",
    gameType = "TOURNAMENT",
    isChampionship = true,
    youHaveJoined = false,
    entryFee = 450,
    tournament = {
      _id = "champ-1", name = "Global Championship", scope = "GLOBAL", levels = seven,
      stake = { amount = 400, charge = 50 },
      grandPrize = { type = "coins", value = 20000 },
    },
  }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end

----------------------------------------------------------------------

----------------------------------------------------------------------
-- THE ONE THAT MADE THE WHOLE DESIGN INVISIBLE.
--
-- The premium strip is selected by `championship`, not by `joining`. Those were
-- conflated once: the strip fired only for a player who had NOT joined, so
-- everybody already in the championship — which is everybody testing it — got
-- the ordinary grey strip, and so did everybody on a server not yet sending
-- `youHaveJoined` at all. Reported as "still no difference on the championship
-- incoming request".
print("── which invites get the premium strip ──")
check("a championship invite to somebody NOT in it",
      champ.offer(invite(), user_data).championship, true)
check("a championship invite to somebody ALREADY in it",
      champ.offer(invite({ youHaveJoined = true, entryFee = 0 }), user_data).championship, true)
check("...and an older payload that answers neither question",
      champ.offer({
        requestId = "r1",
        tournament = { _id = "champ-1", name = "Global Championship" },
      }, user_data).championship, true)
check("...and one carrying only a bare tournamentId",
      champ.offer({ requestId = "r1", tournamentId = "champ-1" }, user_data).championship, true)
check("a battle never does",
      champ.offer({ requestId = "r2", tournament = { _id = "battle-9", levels = { 1 } } },
        user_data).championship, false)
check("nor does a bare id for something else",
      champ.offer({ requestId = "r2", tournamentId = "battle-9" }, user_data).championship, false)

print("\n── which question the strip asks ──")
local not_in = champ.offer(invite(), user_data)
check("a player who is not in is asked to JOIN", not_in.joining, true)
check("...and the button says so", not_in.accept_label, "JOIN")
check("...and the other one CANCELs rather than declining a match",
      not_in.decline_label, "CANCEL")
check("...and it quotes the fee they would pay", not_in.entry_fee, 450)
check("...and the prize they would play for", not_in.prize, 20000)

local already = champ.offer(invite({ youHaveJoined = true, entryFee = 0 }), user_data)
check("a player already in is asked to ACCEPT", already.joining, false)
check("...with the ordinary labels", already.accept_label, "ACCEPT")
check("...and the ordinary decline", already.decline_label, "DECLINE")
check("...and NO fee, because they are not paying again", already.entry_fee, 0)

----------------------------------------------------------------------
print("\n── it never invents a charge ──")
----------------------------------------------------------------------
-- Present-and-false is the only thing that means "not in yet". Absent means an
-- older server that never answered the question, and putting a JOIN prompt on
-- top of one asks for money nothing is going to take.
local legacy = champ.offer({
  requestId = "r1", gameType = "TOURNAMENT",
  tournament = { _id = "champ-1", name = "Global Championship", scope = "GLOBAL", levels = seven },
}, user_data)
check("an older payload with no answer does NOT offer JOIN", legacy.joining, false)
check("...and quotes no fee", legacy.entry_fee, 0)

local battle = champ.offer({
  requestId = "r2", gameType = "TOURNAMENT", youHaveJoined = false, entryFee = 999,
  tournament = { _id = "battle-9", scope = "PRIVATE", levels = { 1 } },
}, user_data)
check("an ordinary battle never offers JOIN", battle.joining, false)
check("...and ignores a fee it should never have been sent", battle.entry_fee, 0)

check("a fee of zero is not a fee, even when joining",
      champ.offer(invite({ entryFee = 0 }), user_data).entry_fee, 0)
check("and the footer stays away when there is nothing to charge",
      champ.fee_text(champ.offer(invite({ entryFee = 0 }), user_data)), nil)
check("but appears when there is", champ.fee_text(not_in), "One-time join fee")
check("never on an accept strip", champ.fee_text(already), nil)

check("garbage in is not a crash", champ.offer(nil, nil).joining, false)
check("...nor is a payload with no tournament",
      champ.offer({ requestId = "x" }, nil).joining, false)

----------------------------------------------------------------------
print("\n── the prize figure ──")
----------------------------------------------------------------------
check("read from grandPrize.value", champ.grand_prize({ grandPrize = { value = 5000 } }), 5000)
check("...or the flatter coins spelling", champ.grand_prize({ grandPrize = { coins = 800 } }), 800)
check("...or a bare number", champ.grand_prize({ grandPrize = 1200 }), 1200)
check("absent is zero, not nil", champ.grand_prize({}), 0)
check("and nothing at all is zero too", champ.grand_prize(nil), 0)

----------------------------------------------------------------------
print("\n── the button names its own price ──")
----------------------------------------------------------------------
-- A button that spends coins should say how much on its own face. The fee line
-- beside it is the explanation, not the disclosure: a player who reads only the
-- button must still know what it costs.
--
-- champ_banner draws, so unlike championship.lua beside it there is no
-- pretending it does not need Defold: its palette is built from vmath at load
-- time. Two stub globals are enough to load the module and reach the pure
-- parts — the label and the geometry constants — which is all that is being
-- asked of it here. The drawing itself is exercised by the app.
_G.vmath = _G.vmath or {
  vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
  vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
_G.gui = _G.gui or setmetatable({}, { __index = function() return function() end end })
local cb = require("modules.champ_banner")
check("the label carries the fee", cb.join_label(500), "JOIN FOR 500")
check("...with thousands grouped", cb.join_label(20000), "JOIN FOR 20,000")
check("a fee of zero leaves a bare JOIN", cb.join_label(0), "JOIN")
check("...and so does no fee at all", cb.join_label(nil), "JOIN")
check("junk does not produce a price", cb.join_label("free"), "JOIN")

----------------------------------------------------------------------
print("\n── the championship strip's own geometry ──")
----------------------------------------------------------------------
-- It is one module drawn by two surfaces, so the figures are checked once —
-- which is the point of it being a module. Nothing in the Defold GUI measures
-- text at build time, so an overlap is only ever found by reading numbers.
local function source(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close()
  return s
end

check("the strip is taller than the ordinary 92px one", cb.HEIGHT > 92, true)

-- Laid out from the right edge, same convention as the ordinary strip. The
-- prize plaque must clear the buttons, and the buttons must clear each other.
local join_left   = cb.JOIN_X + cb.JOIN_W / 2
local cancel_right = cb.CANCEL_X - cb.CANCEL_W / 2
check("CANCEL sits left of JOIN without touching it", cancel_right > join_left, true)

local plaque_left = cb.PLAQUE_X + cb.PLAQUE_W / 2
local cancel_left = cb.CANCEL_X + cb.CANCEL_W / 2
check("the prize plaque clears both buttons", plaque_left >= cancel_left, true)

local src = source("modules/champ_banner.lua")
check("the plate fades toward one corner rather than filling flat",
      src:find("draw_corner_fade") ~= nil, true)
check("...built from stepped slices, since a box takes one colour",
      src:find("FADE_STEPS") ~= nil, true)
check("...and the ramp is curved so the glow stays out of the left",
      src:find("t %* t %* t") ~= nil, true)
check("the prize has a shimmer that moves per frame, not per rebuild",
      src:find("function M%.animate") ~= nil and src:find("anim%.shimmer") ~= nil, true)
check("the shimmer is confined to the plaque's own span",
      src:find("shimmer_span = {") ~= nil, true)

----------------------------------------------------------------------
print("\n── and both surfaces use it ──")
----------------------------------------------------------------------
for _, file in ipairs({ "main/incoming.gui_script", "main/online.gui_script" }) do
  local s = source(file)
  local tag = file:match("([^/]+)$")
  check(tag .. ": draws the offer through the shared module",
        s:find("champ_banner%.draw") ~= nil, true)
  check(tag .. ": and animates it every frame",
        s:find("champ_banner%.animate") ~= nil, true)
  check(tag .. ": the offer itself is asked for by name",
        s:find("champ%.offer") ~= nil, true)
  -- The old inline JOIN variant of the ordinary strip is gone. Left behind it
  -- would be a second, worse rendering of the same invite.
  check(tag .. ": no leftover inline join layout",
        s:find("BAN_H_JOIN") == nil, true)
end

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
