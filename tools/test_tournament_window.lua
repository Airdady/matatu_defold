-- IS THE GLOBAL TOURNAMENT OPEN? — modules/tournament_window
--
--   Run: lua tools/test_tournament_window.lua
--
-- The lobby's way in used to wear a "NEW" badge that had been there since the
-- feature shipped and meant nothing by the second day. It says OPEN or CLOSED
-- now, which means it has to compute the same daily window the tournament
-- screen greys its PLAY button on — and a second copy of a schedule is a
-- promise that the two will drift.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

local TW = require("modules.tournament_window")
local function at(h, m) return h * 60 + (m or 0) end
local active = { scope = "GLOBAL", status = "active" }

print("== which tournament is the championship ==")
-- Three generations of the backend have said this differently and old
-- tournaments are still live, so any of the three counts.
ok("an explicit scope", TW.is_global({ scope = "GLOBAL" }))
ok("the name", TW.is_global({ name = "Global Championship" }))
ok("the public type", TW.is_global({ type = "public" }))
ok("a private cup is not", not TW.is_global({ scope = "TEAM", name = "Our Cup" }))
ok("and rubbish is not", not TW.is_global(nil))

print("\n== picking it out of the list ==")
local mine = { scope = "TEAM", status = "active" }
check("an active global wins", TW.global_of({ mine, active }), active)
-- "The championship exists and is shut" is a different thing to say than
-- nothing at all, so a dormant one is still returned when it is all there is.
local dormant = { scope = "GLOBAL", status = "completed" }
check("a dormant global is still found", TW.global_of({ mine, dormant }), dormant)
check("an active one is preferred over it", TW.global_of({ dormant, active }), active)
check("no global at all", TW.global_of({ mine }), nil)
check("nothing at all", TW.global_of(nil), nil)

print("\n== the daily window ==")
local s, e = TW.bounds(nil)
check("defaults to the screen's own hours (start)", s, at(8, 0))
check("...and its end", e, at(23, 59))

s, e = TW.bounds({ activeTime = { start = "09:30", ["end"] = "21:15" } })
check("an override is honoured (start)", s, at(9, 30))
check("...and its end", e, at(21, 15))

-- Per FIELD, not wholesale: a tournament that names only its start keeps the
-- default end rather than losing both.
s, e = TW.bounds({ activeTime = { start = "10:00" } })
check("a half-set override keeps the default end", e, at(23, 59))
check("...while taking the start it gave", s, at(10, 0))
s, e = TW.bounds({ activeTime = { start = "nonsense" } })
check("an unparseable override falls back", s, at(8, 0))

print("\n== open, closed, and the night shift ==")
ok("shut before it opens", not TW.is_open_at(nil, at(7, 59)))
ok("open on the minute it opens", TW.is_open_at(nil, at(8, 0)))
ok("open in the middle", TW.is_open_at(nil, at(15, 0)))
ok("shut on the minute it closes", not TW.is_open_at(nil, at(23, 59)))

-- THE CASE THE SCREEN'S OWN VERSION COULD NOT DO. It compared against both
-- bounds as though they were always in order, so a window running 20:00 to
-- 02:00 read as closed for the whole of its actual run. Nothing sets one
-- today, which is exactly why it would have been found the hard way.
local night = { activeTime = { start = "20:00", ["end"] = "02:00" } }
ok("an overnight window is open late", TW.is_open_at(night, at(23, 0)))
ok("...and after midnight", TW.is_open_at(night, at(1, 0)))
ok("...and shut in the afternoon", not TW.is_open_at(night, at(15, 0)))
ok("a zero-length window is shut", not TW.is_open_at({ activeTime = { start = "08:00", ["end"] = "08:00" } }, at(8, 0)))

print("\n== the badge word ==")
-- The schedule describes when an ACTIVE championship runs, not whether there
-- is one — so a tournament the server has not marked active is shut whatever
-- the clock says.
check("open inside the window", TW.status_label({ active }, at(12, 0)), "OPEN")
check("closed outside it", TW.status_label({ active }, at(3, 0)), "CLOSED")
check("closed when the server says it is not active",
      TW.status_label({ { scope = "GLOBAL", status = "completed" } }, at(12, 0)), "CLOSED")

-- Nil rather than "CLOSED": they are different facts. A badge reading CLOSED
-- says the door is shut; one drawn over a list that has not loaded yet says it
-- about a door nobody has looked at.
check("nothing to say with no championship", TW.status_label({ mine }, at(12, 0)), nil)
check("...or before the list has loaded", TW.status_label(nil, at(12, 0)), nil)

print("\n== minute of day ==")
check("from an os.date table", TW.minute_of_day({ hour = 9, min = 45 }), at(9, 45))
check("rubbish is midnight", TW.minute_of_day(nil), 0)

print("")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
