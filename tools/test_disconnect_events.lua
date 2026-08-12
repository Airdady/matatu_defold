-- THE OPPONENT-DISCONNECTED DIALOG READ A PAYLOAD THAT WAS NEVER THERE.
--
--   Run: lua tools/test_disconnect_events.lua
--
-- wsUtil.ts broadcasts PLAYER_DISCONNECTED carrying `disconnectedPlayer` and
-- `gracePeriod`. Every other message from that server wraps its payload in
-- `data`, so the client unwrapped `message.data` and looked there — and got an
-- empty table. Nothing errored. Both defaults just quietly took over: a flat
-- 30-second countdown that had nothing to do with the grace the server granted,
-- and an empty player id, which left the dialog unable to name who dropped,
-- unable to tell somebody else's disconnect from our own, and unable to decide
-- whether an arriving reconnect was even the one it was waiting for.
--
-- The second trap is the one that would have bitten the moment the first was
-- fixed: `gracePeriod` is a DEADLINE, not a duration. Read literally as
-- seconds it is about fifty thousand years. The payload being unreadable is
-- the only reason nobody ever saw that, which is why both are pinned here.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local DC = require("modules.disconnect_events")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- A fixed "now" so the deadline arithmetic is checkable.
local NOW    = 1770000000          -- seconds
local NOW_MS = NOW * 1000

print("THE REPORTED FAILURE: the real server payload, replayed")
-- Exactly what wsUtil.ts broadcasts, in the shape it broadcasts it: fields at
-- the TOP level, no `data` envelope, gracePeriod as an absolute deadline.
local top_level = {
    type = "PLAYER_DISCONNECTED",
    disconnectedPlayer = "opponent-42",
    gracePeriod = NOW_MS + 30000,
}
local dc = DC.parse_disconnect(nil, top_level, NOW)
check("the dropped player is identified at last", dc.player_id, "opponent-42")
check("and the deadline became seconds remaining", dc.grace, 30)

print("")
print("The current shape, wrapped in data")
local wrapped = {
    disconnectedPlayer = "opponent-42",
    gracePeriod = NOW_MS + 45000,
    graceSeconds = 45,
}
local dc2 = DC.parse_disconnect(wrapped, { type = "PLAYER_DISCONNECTED" }, NOW)
check("player id read from data", dc2.player_id, "opponent-42")
check("explicit graceSeconds is preferred", dc2.grace, 45)

print("")
print("A DEADLINE IS NOT A DURATION")
-- The whole point. 1.77e12 read as seconds is ~56,000 years, and a countdown
-- from it never visibly moves.
check("an epoch deadline is converted, not counted from",
    DC.grace_seconds({ gracePeriod = NOW_MS + 30000 }, nil, NOW), 30)
check("a small value is already a duration",
    DC.grace_seconds({ gracePeriod = 25 }, nil, NOW), 25)
check("an ALREADY-EXPIRED deadline falls back, never negative",
    DC.grace_seconds({ gracePeriod = NOW_MS - 5000 }, nil, NOW), 30)
check("nothing usable falls back", DC.grace_seconds({}, {}, NOW), 30)
check("nils are not a crash", DC.grace_seconds(nil, nil, NOW), 30)

print("")
print("WHOSE DISCONNECT IS THIS")
check("our own id is recognized as ours", DC.is_self("me", "me"), true)
check("the opponent's is not", DC.is_self("opponent-42", "me"), false)
-- An unattributed event must never be mistaken for our own: suppressing a
-- dialog we needed is the unrecoverable direction.
check("an unattributed event is not ours", DC.is_self("", "me"), false)
check("nor is it ours when we have no id yet", DC.is_self("opponent-42", ""), false)

print("")
print("WHO MAY DISMISS THE DIALOG")
check("the player we are waiting on may",
    DC.should_dismiss("opponent-42", "opponent-42"), true)
check("somebody else may not",
    DC.should_dismiss("opponent-42", "someone-else"), false)
-- Asymmetric on purpose: the dialog's scrim swallows every tap, so leaving it
-- up wrongly locks the player out of the rest of the game, while dropping it
-- wrongly costs one dialog the next PLAYER_DISCONNECTED raises again.
check("an unattributed reconnect may",
    DC.should_dismiss("opponent-42", ""), true)
check("and so may anything when we are waiting on nobody",
    DC.should_dismiss("", "whoever"), true)
check("nils are not a crash", DC.should_dismiss(nil, nil), true)

print("")
print("RECONNECT ATTRIBUTION")
-- Both server paths name it `reconnectedPlayer`. handleIdentify.ts omitted it
-- entirely until now, which is the common path — it fires on every
-- reconnecting IDENTIFY.
check("read from data", DC.parse_reconnect({ reconnectedPlayer = "opponent-42" }, {}).player_id, "opponent-42")
check("read from the envelope", DC.parse_reconnect({}, { reconnectedPlayer = "opponent-42" }).player_id, "opponent-42")
check("absent is empty, not nil", DC.parse_reconnect({}, {}).player_id, "")

print("")
if failures == 0 then
    print("ALL PASS")
else
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
