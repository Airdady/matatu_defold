-- The ceiling on how long an incoming request may hold the app's input.
--
--   Run: lua tools/test_incoming_budget.lua
--
-- THE FREEZE THIS RULE EXISTS FOR
--
-- The full incoming dialog claims "incoming" at priority 100, and every screen
-- in the app begins its on_input with `if app_state.input_blocked() then
-- return false end`. While that claim is held nothing anywhere responds. That
-- is correct for one challenge: it has ten seconds on it and an opponent
-- waiting on the answer.
--
-- What was not correct is that the ten seconds RESTART. Each arriving request
-- replaced the live dialog and gave it a fresh countdown, so a player being
-- spammed — or in a busy tournament lobby where invites land every few seconds
-- — held that claim continuously. The dialog kept changing, so it never looked
-- stuck. The app underneath simply stopped taking input, for as long as the
-- requests kept coming, with no way out but force-quitting.
--
-- Reported as: "when users keep requesting games and in-app notifications keep
-- coming, after some time the app freezes, all the buttons, you can't click on
-- anything, not even notification acceptance."
--
-- The rule is a budget on the CLAIM rather than on any one request. Past it
-- the overlay keeps showing every invite, on the non-blocking banner instead.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local B = require("modules.incoming_budget")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- Run `secs` seconds of frames at 60fps with the given surface showing,
-- returning whichever tick first asked for a demotion.
local function run(state, secs, showing)
    local dt, demoted = 1 / 60, nil
    for _ = 1, math.floor(secs / dt) do
        local r = B.tick(state, dt, showing)
        demoted = demoted or r
    end
    return demoted
end

print("ONE challenge is never demoted")
-- The whole point of the blocking dialog. A single request must get its full
-- ten seconds at full strength or this fix has broken the feature it guards.
local s = B.new()
check("a full 10s dialog is left alone", run(s, 10, "dialog"), nil)
check("and so are two back-to-back", run(B.new(), 20, "dialog"), nil)

print("")
print("A BURST is demoted, and the app comes back")
local burst = B.new()
check("blocking past the budget demotes", run(burst, 26, "dialog"), "demote")
-- The demotion has to actually stick, or the next arrival re-blocks and the
-- player is back where they started one frame later.
check("the next request goes to the banner", B.surface(burst, false), "banner")

print("")
print("The cooldown OUTLASTS the burst that caused it")
-- A cooldown shorter than the gap between arrivals would flip straight back to
-- blocking on the very next challenge, which is the failure this is for.
check("still banner after 10s", (function()
    local st = B.new(); run(st, 26, "dialog"); run(st, 10, "banner")
    return B.surface(st, false)
end)(), "banner")
check("blocking is restored once it lapses", (function()
    local st = B.new(); run(st, 26, "dialog"); run(st, 25, nil)
    return B.surface(st, false)
end)(), "dialog")

print("")
print("A quiet moment resets the budget")
-- Two separate bursts an hour apart are not one long burst. Without this a
-- player who saw a demotion once would be stuck on the banner for the rest of
-- the session.
local quiet = B.new()
run(quiet, 20, "dialog")
run(quiet, 30, nil)
check("a fresh 25s is available", run(quiet, 24, "dialog"), nil)

print("")
print("A BANNER does not refill the budget")
-- The exact traffic that froze it: game requests interleaved with tournament
-- invites. Tournament invites are banners, so if a banner reset the budget,
-- alternating the two would hand back a fresh 25 seconds of blocking every
-- time and the ceiling would never be reached.
local mixed = B.new()
run(mixed, 20, "dialog")     -- 20 of 25 used
run(mixed, 30, "banner")     -- a tournament invite lands in the middle
check("the remaining budget is what was left", run(mixed, 6, "dialog"), "demote")

print("")
print("Tournament / battle / cup invites are ALWAYS non-blocking")
-- Independently of any of this. They are ambient by design and play carries on
-- underneath them.
check("banner request with budget spare", B.surface(B.new(), true), "banner")
check("banner request while cooling down", B.surface(burst, true), "banner")

print("")
print("Nothing here can raise")
-- It runs inside update(), every frame, on the component that sits above every
-- screen. An error in it takes the whole overlay down.
check("nil state", B.tick(nil, 1, "dialog"), nil)
check("nil dt", (function() local st = B.new(); return B.tick(st, nil, "dialog") end)(), nil)
check("nil surface state", B.surface(nil, false), "dialog")
check("unknown showing value", B.tick(B.new(), 1, "something-else"), nil)

print("")
print("The budget is a ceiling on being FROZEN, so keep it short")
-- A number, asserted, because it is the actual promise: the longest the app
-- can be input-dead in one stretch. Raising it silently is how this regresses.
check("budget", B.BUDGET_SECONDS, 25)
check("cooldown", B.COOLDOWN_SECONDS, 20)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
