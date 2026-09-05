-- THE PAYMENTS DIALOG HAS TO CLOSE WHEN THE MONEY ARRIVES.
--
--   Run: lua5.4 tools/test_payment_dialog_close.lua
--
-- Reported: "when the payment is complete the payment dialogue never closes
-- automatically on frontend."
--
-- The client half was never the problem, and that is worth stating up front:
-- controller.script has always listened for `transaction_completed` and has
-- always closed the screen on it. NOTHING EVER SENT THAT EVENT. The server
-- built TRANSACTION_COMPLETED, handed it to the push layer, and the push layer
-- drops anything addressed to a player whose app is open — on the reasoning
-- that the in-app UI covers it. For a deposit nothing did. The one player
-- guaranteed to be looking at the payments dialog is the one the message was
-- never delivered to, so it sat on "Request sent - check your phone" for ever
-- while the balance behind it changed silently.
--
-- The fix is in be_matatu (sendTransactionOverSocket, common/firebase/
-- notifications.ts). What is pinned HERE is the receiving end that fix
-- depends on: the shape the handler reads, and the two states it closes on.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

local ctrl = io.open(ROOT .. "main/controller.script"):read("a")
local wsm  = io.open(ROOT .. "modules/websocket_manager.lua"):read("a")

----------------------------------------------------------------------
print("THE EVENT REACHES THE APP AT ALL")
----------------------------------------------------------------------
-- The router branch the server's socket frame lands on. Without this the fix
-- on the other side delivers into nothing.
ok("the socket router handles TRANSACTION_COMPLETED",
   wsm:find('t == "TRANSACTION_COMPLETED"', 1, true) ~= nil)
ok("...and emits it under the name the controller listens for",
   wsm:find('emit("transaction_completed", d)', 1, true) ~= nil)
ok("a failure is routed too, so a dialog can report one",
   wsm:find('t == "TRANSACTION_FAILED"', 1, true) ~= nil)

----------------------------------------------------------------------
print("THE FIELDS THE HANDLER READS ARE THE ONES ON THE WIRE")
----------------------------------------------------------------------
local handler = ctrl:match('ws%.on%("transaction_completed".-\n    end%)%)')
ok("found the transaction_completed handler", handler ~= nil)
handler = handler or ""

-- The router hands the handler `message.data`, and these are read straight off
-- it. The server flattens its own payload INTO that field for exactly this
-- reason: nested, d.type would be the message's name instead of the
-- transaction's kind, and the balance would be a level further down.
ok("reads the transaction kind off the top level", handler:find("d.type", 1, true) ~= nil)
ok("reads the new balance off the top level", handler:find("d.newBalance", 1, true) ~= nil)
ok("knows a deposit by name", handler:find('"buy"', 1, true) ~= nil)
ok("and a sale by name", handler:find('"withdrawal"', 1, true) ~= nil)

----------------------------------------------------------------------
print("WHAT CLOSING ACTUALLY MEANS")
----------------------------------------------------------------------
-- A SALE IS ALSO A FINISHED PAYMENT. The close used to be inside the
-- deposit-only branch, so a player who had just sold coins was left on the
-- same dialog, in the same "check your phone" state, for a transaction that
-- had already settled and already moved the balance under it.
local close_at = handler:find('show(self, "online")', 1, true)
ok("the dialog is closed", close_at ~= nil)

local buy_only = handler:match('if kind == "buy" and new_bal')
ok("the deposit branch still exists", buy_only ~= nil)
ok("but the close is not inside it",
   close_at ~= nil and close_at < (handler:find('if kind == "buy" and new_bal', 1, true) or math.huge))

-- ONLY FROM THE PAYMENTS SCREEN. transaction_completed also arrives while the
-- player is in the lobby or mid-game; routing those to "online" would yank
-- somebody off whatever they were doing because their deposit landed.
ok("and only when the payments screen is the one open",
   handler:find('self.screen == "payments" and', 1, true) ~= nil)

-- THE COINS ARE STILL A DEPOSIT'S OWN BUSINESS. A withdrawal must not drop
-- coins into the counter — the balance went DOWN.
local coin = handler:find("coin_deposit", 1, true)
ok("the coin drop is still there", coin ~= nil)
ok("...and still gated on a deposit that actually gained something",
   handler:find("if gained > 0 then", 1, true) ~= nil)
ok("...and sits inside the deposit branch, not beside it",
   coin ~= nil and buy_only ~= nil and coin > (handler:find('if kind == "buy" and new_bal', 1, true) or 0))

-- Every screen is still refreshed afterwards, whatever the kind: the balance
-- moved, and a screen showing the old one is wrong even when nothing closed.
ok("every money screen is still refreshed", handler:find("user_data_updated", 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
