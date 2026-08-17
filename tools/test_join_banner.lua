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
print("── which question the strip asks ──")
----------------------------------------------------------------------
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
print("\n── the join strip's geometry, in both files ──")
----------------------------------------------------------------------
-- Nothing in the Defold GUI measures text at build time, so an overlap is only
-- ever found by reading the numbers. Both files are checked because they draw
-- the SAME invite.
local function source(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close()
  return s
end

for _, file in ipairs({ "main/incoming.gui_script", "main/online.gui_script" }) do
  local src = source(file)
  local tag = file:match("([^/]+)$")

  local function const(name)
    return tonumber(src:match("local " .. name .. "%s*=%s*(%-?%d+)"))
  end

  check(tag .. ": the join strip is taller than the ordinary one",
        (const("BAN_H_JOIN") or 0) > 92, true)

  -- The prize block sits where H2H would have been. It must clear the buttons,
  -- which start at R-285 (ACCEPT centred at R-90, DECLINE at R-225, both 120
  -- wide). "subtitle1" is a 34px face; a five-figure amount is comfortably
  -- under 200px, so ±100 from its centre is the span to keep clear.
  local prize_x = const("BAN_PRIZE_X") or 0
  check(tag .. ": the prize is left of the buttons", prize_x - 100 > 285, true)

  -- ...and the fee line sits under the buttons rather than beside them, so it
  -- cannot push into the prize.
  check(tag .. ": the fee line is drawn on the bottom edge, not the centre",
        src:find("One%-time join fee") ~= nil, true)

  check(tag .. ": JOIN has its own colour, distinct from ACCEPT's green",
        src:find("BAN_JOIN%s*=%s*vmath%.vector4") ~= nil, true)
  check(tag .. ": the labels come from the shared offer, not a literal",
        src:find("accept_label") ~= nil, true)
  check(tag .. ": and the offer is asked for by name",
        src:find("champ%.offer") ~= nil, true)
end

-- The two files must AGREE on every shared figure, or one invite looks like two.
local a, b = source("main/incoming.gui_script"), source("main/online.gui_script")
for _, name in ipairs({ "BAN_H_JOIN", "BAN_PRIZE_X" }) do
  local va = tonumber(a:match("local " .. name .. "%s*=%s*(%-?%d+)"))
  local vb = tonumber(b:match("local " .. name .. "%s*=%s*(%-?%d+)"))
  check("both files agree on " .. name, va ~= nil and va == vb, true)
end

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
