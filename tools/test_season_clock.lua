-- THE WHOLE COUNTDOWN, BESIDE THE PRIZES IT APPLIES TO.
--
--   Run: lua tools/test_season_clock.lua
--
-- The Season Bonuses table says what each rank is paid. The one thing it did
-- not say is when the ranking closes — which is the number that decides
-- whether a player still has time to climb into a tier. That was available
-- only in the lobby header, a screen away from the prizes it applies to.
--
-- It now sits inline with the SEASON BONUSES title, on the far right:
--
--     4D 05H 12M 07S LEFT
--     05H 12M 07S LEFT       inside the last day
--     ENDED                  the boundary has passed
--
-- Every unit, seconds included. The first version of this dropped units as
-- the deadline came closer — "4D 5H", then "5H 3M", then "5M 3S" — on the
-- reasoning that minutes are noise on a four-day countdown. There is room on
-- that row for the whole thing, and a countdown that silently changes which
-- fields it shows is harder to read at a glance than one that always shows
-- the same four.
--
-- The day field still appears only when there IS a day, and everything under
-- it is zero-padded, so the string keeps its width as digits drop and the
-- right-aligned label does not shuffle every second.
--
-- Also checked here: the date arithmetic and the Wednesday-midday /
-- Saturday-midnight fallback, which THREE surfaces were each carrying their
-- own copy of. Three copies of a schedule is three chances for one of them to
-- disagree with the server about when the money moves.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path

local C = require("modules.season_clock")

local MIN, HOUR, DAY = 60, 3600, 86400

print("\n== every unit, and the word LEFT ==")
do
    check("days out", C.full(4 * DAY + 5 * HOUR + 12 * MIN + 7), "4D 05H 12M 07S LEFT")
    check("inside the last day", C.full(5 * HOUR + 3 * MIN + 40), "05H 03M 40S LEFT")
    check("inside the last hour", C.full(5 * MIN + 3), "00H 05M 03S LEFT")
    check("inside the last minute", C.full(42), "00H 00M 42S LEFT")
end

print("\n== the day field appears only when there is a day ==")
do
    -- "0D" is not data, it is a zero taking up space.
    check("exactly one day", C.full(DAY), "1D 00H 00M 00S LEFT")
    check("one second under a day drops the day", C.full(DAY - 1), "23H 59M 59S LEFT")
    check("just under two days", C.full(2 * DAY - 1), "1D 23H 59M 59S LEFT")
end

print("\n== padding holds the width ==")
do
    -- The label is right-aligned and repaints every second. Unpadded, it
    -- would change width as each digit dropped and shuffle on the row.
    local a, b = C.full(2 * HOUR + 5 * MIN + 9), C.full(11 * HOUR + 45 * MIN + 59)
    check("single and double digits are the same length", #a, #b)
    check("hours are padded", C.full(2 * HOUR), "02H 00M 00S LEFT")
    -- The day itself is NOT padded: a season is never ten days long, so a
    -- leading zero there would be padding for a digit that cannot arrive.
    check("the day is not padded", C.full(3 * DAY), "3D 00H 00M 00S LEFT")
end

print("\n== past the boundary ==")
do
    -- A clock that has run past its boundary must not print a negative
    -- countdown, or the words "LEFT" after a zero, while it waits for the
    -- next SEASON_STATUS to arrive.
    check("zero has ended", C.full(0), "ENDED")
    check("negative has ended", C.full(-500), "ENDED")
    check("nil has ended", C.full(nil), "ENDED")
    check("nonsense has ended", C.full("soon"), "ENDED")
end

print("\n== urgency, which decides the colour ==")
do
    -- The label is GOLD on the Season Bonuses row — this UI's "there is money
    -- in this" colour, the same one the prize amounts under it use — and turns
    -- RED for the last hour, where the seconds field stops being decoration.
    -- A countdown that looks identical at four days and at forty seconds is
    -- wasting the one moment it matters.
    check("days out is normal", C.urgency(4 * DAY), "normal")
    check("two hours is still normal", C.urgency(2 * HOUR), "normal")
    check("just over an hour is normal", C.urgency(HOUR + 1), "normal")
    check("exactly an hour is the final hour", C.urgency(HOUR), "final_hour")
    check("a minute is the final hour", C.urgency(MIN), "final_hour")
    check("one second is the final hour", C.urgency(1), "final_hour")

    -- ENDED is not urgent, it is over. Leaving it red would keep shouting
    -- about a deadline nobody can still make.
    check("zero has ended", C.urgency(0), "ended")
    check("negative has ended", C.urgency(-1), "ended")
    check("nil has ended", C.urgency(nil), "ended")

    -- The two must agree about the boundary: the string that says ENDED is
    -- the same one that must not be painted red.
    check("ENDED and ended line up",
        C.full(0) == "ENDED" and C.urgency(0) == "ended", true)
end

print("\n== the header's clock is unchanged ==")
do
    -- verbose() is what the lobby header has always shown, moved here rather
    -- than rewritten — full() is this plus the word LEFT. The header says no
    -- such word because that whole strip is already labelled as the season
    -- countdown; the Season Bonuses row is not.
    check("verbose over a day", C.verbose(4 * DAY + 5 * HOUR + 5 * MIN + 7), "4D 05H 05M 07S")
    check("verbose inside a day", C.verbose(5 * HOUR + 3 * MIN + 9), "05H 03M 09S")
    check("verbose at zero", C.verbose(0), "00H 00M 00S")
    check("verbose never goes negative", C.verbose(-10), "00H 00M 00S")
end

print("\n== parsing what the server sends ==")
do
    -- 2026-08-20T09:00:00Z. Cross-checked against a known epoch rather than
    -- against os.time{...}, which reads the DEVICE's timezone — the whole
    -- reason this module does its own date arithmetic.
    local epoch = C.parse_iso_utc("2026-08-20T09:00:00.000Z")
    check("iso parses to a utc epoch", epoch, 1787216400)
    check("the trailing millis do not confuse it",
        C.parse_iso_utc("2026-08-20T09:00:00Z"), epoch)
    check("unparseable is nil", C.parse_iso_utc("next tuesday"), nil)
    check("nil is nil", C.parse_iso_utc(nil), nil)
    check("a number is nil", C.parse_iso_utc(1787907600), nil)

    -- The epoch of the era boundary, as a check on days_from_civil itself.
    check("the unix epoch itself", C.parse_iso_utc("1970-01-01T00:00:00Z"), 0)
end

print("\n== the server's word beats ours ==")
do
    local now = 1787216400 -- 2026-08-20T09:00:00Z, a Thursday
    local stated = C.end_epoch({ endDate = "2026-08-22T20:59:00Z" }, now)
    check("a stated endDate is used", stated, C.parse_iso_utc("2026-08-22T20:59:00Z"))
    check("remaining counts from it",
        C.remaining({ endDate = "2026-08-20T10:30:00Z" }, now), 90 * MIN)

    -- No status at all — a guest, or the window before IDENTIFY lands — must
    -- still get a real boundary rather than a frozen blank.
    local fallback = C.end_epoch(nil, now)
    check("a missing status still yields a boundary", type(fallback), "number")
    check("and it is in the future", fallback > now, true)

    -- An unparseable endDate must fall back too, not produce nil arithmetic.
    check("a broken endDate falls back",
        C.end_epoch({ endDate = "whenever" }, now), fallback)

    -- remaining() is clamped: a boundary already passed reads as zero, which
    -- full() then renders as ENDED.
    check("a passed boundary is zero, not negative",
        C.remaining({ endDate = "2026-08-19T00:00:00Z" }, now), 0)
    check("and shows as ENDED",
        C.full(C.remaining({ endDate = "2026-08-19T00:00:00Z" }, now)), "ENDED")
end

print("\n== the fallback cadence ==")
do
    -- Wednesday midday and Saturday midnight, Africa/Nairobi. Mirrors
    -- be_matatu's Prize.DEFAULT_SEASON_SCOPES.
    --
    -- 2026-08-17 is a Monday. 09:00 UTC is midday EAT.
    local monday = C.parse_iso_utc("2026-08-17T09:00:00Z")
    local target = C.fallback_end_utc(monday)
    -- Wednesday 2026-08-19 12:00 EAT == 09:00 UTC.
    check("monday points at wednesday midday",
        target, C.parse_iso_utc("2026-08-19T09:00:00Z"))
    check("which is two days out", C.full(target - monday), "2D 00H 00M 00S LEFT")

    -- Wednesday afternoon has passed the midday boundary, so the next one is
    -- the end of Saturday: 23:59:59 EAT == 20:59:59 UTC. The last second of
    -- the day, not 23:59:00 — the cadence is "Saturday midnight", and a
    -- boundary a minute early would close the season while people are still
    -- playing into it.
    local wed_pm = C.parse_iso_utc("2026-08-19T12:00:00Z")
    check("wednesday afternoon points at the end of saturday",
        C.fallback_end_utc(wed_pm), C.parse_iso_utc("2026-08-22T20:59:59Z"))
end

print("")
if failures == 0 then
    print(string.format("ALL %d CHECKS PASSED", checks))
else
    print(string.format("%d of %d CHECKS FAILED", failures, checks))
    os.exit(1)
end
