-- TWO UNITS, AND ONLY THE TWO THAT MATTER RIGHT NOW.
--
--   Run: lua tools/test_season_clock.lua
--
-- The Season Bonuses table says what each rank is paid. The one thing it did
-- not say is when the ranking closes — which is the number that decides
-- whether a player still has time to climb into a tier. That was available
-- only in the lobby header, a screen away from the prizes it applies to.
--
-- It now sits inline with the SEASON BONUSES title, on the far right, and it
-- is deliberately NOT the header's clock. The header's whole job is the
-- countdown, so it ticks every field: "4D 05H 12M 07S". Beside a title, that
-- string is a stopwatch bolted to a heading — and the minutes field on a
-- four-day countdown is a digit nobody reads while still being wide enough to
-- crowd the words next to it.
--
-- So the compact form shows two units and narrows as the deadline comes:
--
--     4D 5H      out at range — minutes are noise
--     5H 3M      inside the last day
--     5M 3S      inside the last hour, where seconds start to matter
--     42S        inside the last minute
--     ENDED      the boundary has passed
--
-- The row gets more urgent-looking on its own, without anything having to
-- decide that it is urgent.
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

print("\n== days out: no minutes ==")
do
    check("4D 5H", C.compact(4 * DAY + 5 * HOUR + 5 * MIN + 30), "4D 5H")
    -- The minutes and seconds in there are deliberately non-zero: the point
    -- is that they are DROPPED, not that they happened to be zero.
    check("exactly one day", C.compact(DAY), "1D 0H")
    check("a day and a minute still reads as a day", C.compact(DAY + MIN), "1D 0H")
    check("just under two days", C.compact(2 * DAY - 1), "1D 23H")
    check("no zero padding on the day", C.compact(3 * DAY + 2 * HOUR), "3D 2H")
end

print("\n== inside the last day: hours and minutes ==")
do
    check("5H 3M", C.compact(5 * HOUR + 3 * MIN + 40), "5H 3M")
    -- The boundary itself: one second under a day must switch format.
    check("one second under a day", C.compact(DAY - 1), "23H 59M")
    check("exactly one hour", C.compact(HOUR), "1H 0M")
    check("seconds are dropped at this range", C.compact(2 * HOUR + 59), "2H 0M")
end

print("\n== inside the last hour: minutes and seconds ==")
do
    check("5M 3S", C.compact(5 * MIN + 3), "5M 3S")
    check("one second under an hour", C.compact(HOUR - 1), "59M 59S")
    check("exactly one minute", C.compact(MIN), "1M 0S")
end

print("\n== the last minute, and past it ==")
do
    check("under a minute is seconds alone", C.compact(42), "42S")
    check("one second", C.compact(1), "1S")
    check("zero has ended", C.compact(0), "ENDED")
    -- A clock that has run past its boundary must not print a negative
    -- countdown while it waits for the next SEASON_STATUS to arrive.
    check("negative has ended", C.compact(-500), "ENDED")
    check("nil has ended", C.compact(nil), "ENDED")
    check("nonsense has ended", C.compact("soon"), "ENDED")
end

print("\n== the header's clock is unchanged ==")
do
    -- The verbose form is what the lobby header has always shown, moved here
    -- rather than rewritten. Padded, because that surface's string must not
    -- change width every time a digit drops.
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
    -- compact() then renders as ENDED.
    check("a passed boundary is zero, not negative",
        C.remaining({ endDate = "2026-08-19T00:00:00Z" }, now), 0)
    check("and shows as ENDED",
        C.compact(C.remaining({ endDate = "2026-08-19T00:00:00Z" }, now)), "ENDED")
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
    check("which is two days out", C.compact(target - monday), "2D 0H")

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
