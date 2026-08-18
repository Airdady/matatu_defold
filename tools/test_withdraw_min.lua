-- THE AMOUNT THAT COULD NEVER HAVE WORKED.
--
--   Run: lua5.4 tools/test_withdraw_min.lua
--
-- Reported: a player tried to withdraw 1200 and had their account SUSPENDED
-- for a high win rate. 1200 is below the smallest tier the payment provider
-- carries — the request could never have succeeded — so the only thing that
-- should have happened is a one-line refusal.
--
-- Two failures met in the middle. The backend checked WHO was asking before it
-- checked WHAT was asked (fixed in be_matatu: withdrawMoney and sendPayment
-- both validate the amount first now). And the client let the request leave the
-- handset, because it gated on `method.min` alone — a field that becomes 0 when
-- absent, which passes every amount there is.
--
-- These drive the real modules/withdraw_rules.lua.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local W = require("modules.withdraw_rules")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

-- The config the server sends, in the shape payments.gui_script falls back to.
local SELL = { type = "SELL COINS", min = 5000, charges = {
  { min = 3000,  max = 25000, fee = 800 },
  { min = 25001, max = 50000, fee = 1000 },
  { min = 50001, fee = 1500 },
} }
local BUY = { type = "BUY COINS", min = 500, charges = { { min = 0, fee = 0 } } }

print("── which side of the counter ──")
check("SELL is a withdrawal", W.is_withdraw(SELL), true)
check("BUY is not", W.is_withdraw(BUY), false)
check("so is anything named WITHDRAW", W.is_withdraw({ type = "Withdraw Funds" }), true)
check("junk is not", W.is_withdraw(nil), false)

print("\n── the floor ──")
check("the declared minimum when it is the stricter", W.minimum(SELL), 5000)

-- THE REPORTED HOLE. A config with no `min` made `tonumber(nil) or 0` = 0, and
-- every amount passed. The tiers are still sitting right there saying 3000.
local no_min = { type = "SELL COINS", charges = SELL.charges }
check("a config with NO declared minimum falls back to its tiers", W.minimum(no_min), 3000)
check("...and so 1200 is refused rather than sent", (select(1, W.check(no_min, 1200))), false)

-- And the other way round: tiers missing, declared minimum still applies.
check("no tiers at all leaves the declared minimum standing",
      W.minimum({ type = "SELL COINS", min = 5000 }), 5000)
check("neither one means no floor to enforce",
      W.minimum({ type = "SELL COINS" }), 0)

-- A deposit is judged on its declared minimum alone: its `charges` are a flat
-- fee table starting at 0, not a ladder of withdrawable bands, and reading a
-- floor out of them would refuse deposits the server is happy to take.
check("a deposit is not held to withdrawal tiers", W.minimum(BUY), 500)

check("the lowest tier is found wherever it sits in the list",
      W.tier_floor({ charges = { { min = 50001 }, { min = 3000 }, { min = 25001 } } }), 3000)
check("a zero-min tier is not a floor", W.tier_floor(BUY), 0)

print("\n── what the player is told ──")
local ok, msg = W.check(SELL, 1200)
check("1200 is refused", ok, false)
check("...and the reason names the real minimum", msg, "The minimum you can withdraw is 5000.")

ok, msg = W.check(SELL, 5000)
check("exactly the minimum goes through", ok, true)
check("...with nothing to say about it", msg, nil)
check("above it goes through too", (select(1, W.check(SELL, 25000))), true)

ok, msg = W.check(SELL, 0)
check("an empty amount is refused", ok, false)
check("...and says so rather than naming a figure", msg, "Enter an amount first.")
check("a negative amount is refused too", (select(1, W.check(SELL, -500))), false)

ok, msg = W.check(BUY, 100)
check("a small deposit is refused on its own minimum", ok, false)
check("...and says BUY, not withdraw", msg, "The minimum you can buy is 500.")

-- The screen passes its own thousands-grouping formatter in, so the figure in
-- the message reads the way every other figure on that screen does.
local function commas(n)
  return (tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
ok, msg = W.check({ type = "SELL COINS", min = 25000, charges = SELL.charges }, 900, commas)
check("the figure is formatted by the caller", msg, "The minimum you can withdraw is 25,000.")

print("\n── the screen actually calls it ──")
local f = assert(io.open(here .. "/../main/payments.gui_script"))
local src = f:read("*a"); f:close()
check("PAY asks the rule rather than reading method.min",
      src:find("wrules%.check%(method, amount, commas%)") ~= nil, true)
check("...and the old bare comparison is gone",
      src:find("amount >= %(tonumber%(method%.min%) or 0%)") == nil, true)
-- Below the minimum the tap used to fall through every branch and do nothing.
check("a refused amount raises a toast rather than nothing",
      src:find("toast%.error%(amt_msg%)") ~= nil, true)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
