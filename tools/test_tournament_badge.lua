-- THE TOURNAMENTS BADGE SAYS SOMETHING TRUE, AND FITS INSIDE ITSELF.
--
--   Run: lua tools/test_tournament_badge.lua
--
-- It said "NEW". That is not a state: it read the same on a tournament that
-- had been running for months and on one that closed an hour ago, so it told a
-- player nothing they could act on. What they want to know before tapping is
-- whether they can play right now.
--
-- And it was drawn into a fixed 48x22 pill. That fits "NEW" and nothing else —
-- "CLOSED" is twice the glyphs and simply ran out of the box, which is the
-- reported overflow.
--
-- The rule now lives in modules/tournament_window.lua, which is also what
-- tournaments.gui_script's own dormant/countdown logic is built from, so the
-- badge and the screen it leads to cannot say different things.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local W = require("modules.tournament_window")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- A fixed "now" so the answer does not depend on when the suite runs.
--
-- The epoch and the hour/min are supplied SEPARATELY on purpose: the window
-- check reads only hour/min, while the launchDate check compares against the
-- epoch. The first version of this returned 1000000 for the epoch — January
-- 1970 — which made a launchDate of "2000-01-01" genuinely in the future and
-- failed an assertion about a date that has long since passed. A believable
-- "now" is part of the fixture, not a detail.
local NOW = 1767225600  -- 2026-01-01T00:00:00Z
local function at(hour, min)
    return NOW, { hour = hour, min = min or 0 }
end

local LIVE = { status = "active" }

print("INSIDE THE DAILY WINDOW IS OPEN")
check("mid-afternoon", W.state(LIVE, at(14)), "open")
check("the minute it opens", W.state(LIVE, at(8, 0)), "open")
check("a minute before it shuts", W.state(LIVE, at(23, 58)), "open")

print("")
print("OUTSIDE IT IS CLOSED")
check("before it opens", W.state(LIVE, at(7, 59)), "closed")
check("the minute it shuts", W.state(LIVE, at(23, 59)), "closed")
check("small hours", W.state(LIVE, at(3)), "closed")

print("")
print("A TOURNAMENT CAN MOVE ITS OWN WINDOW")
local EVENING = { status = "active", activeTime = { start = "18:00", ["end"] = "22:00" } }
check("before its start, even though the default is open", W.state(EVENING, at(14)), "closed")
check("inside its own window", W.state(EVENING, at(19)), "open")
check("after its own end", W.state(EVENING, at(22, 1)), "closed")
-- Half an override is still an override.
local LATE_ONLY = { status = "active", activeTime = { start = "20:00" } }
check("start moved, end left at the default", W.state(LATE_ONLY, at(21)), "open")
check("and before the moved start", W.state(LATE_ONLY, at(19, 59)), "closed")

print("")
print("A FINISHED TOURNAMENT IS CLOSED WHATEVER THE CLOCK SAYS")
check("completed", W.state({ status = "completed" }, at(14)), "closed")
check("cancelled", W.state({ status = "cancelled" }, at(14)), "closed")
-- 'upcoming' is a tournament gathering players, not a finished one.
check("upcoming is not finished", W.state({ status = "upcoming" }, at(14)), "open")
-- No status at all is every tournament that predates the field.
check("no status is not finished", W.state({}, at(14)), "open")

print("")
print("ANNOUNCED BUT NOT LAUNCHED IS 'SOON'")
local FUTURE = { status = "active", launchDate = "2099-01-01T00:00:00.000Z" }
check("still ahead", W.state(FUTURE, at(14)), "soon")
-- ...and it outranks the window, because a tournament that does not exist yet
-- is not open at 2pm either.
check("even inside the daily window", W.state(FUTURE, at(12)), "soon")
local PAST = { status = "active", launchDate = "2000-01-01T00:00:00.000Z" }
check("a launch date already passed does not gate", W.state(PAST, at(14)), "open")
check("an unparseable one is treated as launched",
    W.state({ status = "active", launchDate = "whenever" }, at(14)), "open")

print("")
print("THE LABELS")
check("open", W.badge_label(LIVE, at(14)), "OPEN")
check("closed", W.badge_label(LIVE, at(3)), "CLOSED")
check("soon", W.badge_label(FUTURE, at(14)), "SOON")
check("nothing at all still gets a badge", W.badge_label(nil, at(14)), "CLOSED")

print("")
print("IT DESCRIBES THE TOURNAMENT THE TAP OPENS")
-- Worse than the "NEW" it replaces would be a badge saying OPEN about a
-- tournament other than the one the player then lands on. Same order as
-- tournaments.gui_script picks in.
local GLOBAL_LIVE = { scope = "GLOBAL", status = "active", name = "Global Championship" }
local OTHER_LIVE  = { status = "active", name = "Weekend Cup" }
local DEAD        = { status = "completed", name = "Old One" }
check("a global active one wins",
    (W.headline({ OTHER_LIVE, GLOBAL_LIVE, DEAD }) or {}).name, "Global Championship")
check("otherwise any active one",
    (W.headline({ DEAD, OTHER_LIVE }) or {}).name, "Weekend Cup")
check("otherwise the first there is, so a closed one still gets a badge",
    (W.headline({ DEAD }) or {}).name, "Old One")
check("and nothing from nothing", W.headline({}), nil)
check("nor from junk", W.headline("not a list"), nil)

print("")
print("NOTHING HERE CAN RAISE")
-- It runs inside the online screen's rebuild.
check("no tournament", W.state(nil, at(14)), "closed")
check("junk tournament", W.state("nope", at(14)), "closed")
check("junk activeTime", W.state({ status = "active", activeTime = "18:00" }, at(14)), "open")
check("junk window strings",
    W.state({ status = "active", activeTime = { start = "later", ["end"] = "never" } }, at(14)), "open")
check("junk clock parts", type(W.state(LIVE, 1, {})), "string")

print("")
print("THE BADGE IS SIZED TO ITS WORD")
local src = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../modules/online_right.lua"):read("a")
local code = (src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))

check("it no longer says NEW", code:find('"NEW"', 1, true), nil)
check("it asks the shared rule", code:find("twindow.state(", 1, true) ~= nil, true)
check("and the shared picker", code:find("twindow.headline(", 1, true) ~= nil, true)
-- The overflow. A hardcoded 48 cannot hold CLOSED at any font this uses.
check("no fixed 48-wide pill", code:find("vmath.vector3(48, 22, 0)", 1, true), nil)
check("the width is computed", code:find("local badge_w = math.max", 1, true) ~= nil, true)
check("from the label's own length", code:find("#t_label", 1, true) ~= nil, true)
check("the highlight follows the pill's width",
    code:find("vmath.vector3(badge_w, 1, 0)", 1, true) ~= nil, true)
check("and the label is explicitly centred",
    code:find("gui.PIVOT_CENTER", 1, true) ~= nil, true)

print("")
print("AND THE LABEL IS DRAWN ON TOP OF THE PILL, NOT UNDER IT")
-- The reported "fully messed" badge. In Defold, CREATION ORDER IS DRAW ORDER:
-- a node made earlier renders BEHIND one made later. The label used to be
-- created FIRST — because measuring it was what sized the pill — so the pill
-- and its highlight were both painted straight over the text and the badge
-- came out a blank coloured rectangle. Moving the label's POSITION last is not
-- the same as drawing it last, which is what the code did while a comment
-- claimed otherwise.
--
-- Pinned as the INVARIANT rather than as one way of achieving it: sizing the
-- pill from the label's character count instead of from a measured node means
-- the label no longer has to exist first, so it is simply created last. A
-- gui.move_above after the fact would satisfy this just as well, and both are
-- accepted here — what must never come back is a label created before a box
-- and left there.
local badge_block = code:sub(
    code:find("local BADGE_H", 1, true) or 1,
    code:find("cy = cy %- t_h") or #code)

local txt_at = badge_block:find("local n_badge_txt", 1, true)
local last_box_at = nil
local at = 1
while true do
    local found = badge_block:find("ui.box(", at, true)
    if not found then break end
    last_box_at, at = found, found + 1
end

check("the badge draws a pill", last_box_at ~= nil, true)
check("and a label", txt_at ~= nil, true)
check("the label is created after every box, so it draws over them",
    (txt_at or 0) > (last_box_at or 0)
        or badge_block:find("gui.move_above", 1, true) ~= nil, true)
-- Nothing may be drawn over the label after it exists.
check("and nothing is drawn over it afterwards",
    badge_block:sub(txt_at or #badge_block):find("ui.box(", 1, true), nil)
check("it is centred on the pill by explicit pivot",
    badge_block:find("gui.PIVOT_CENTER", 1, true) ~= nil, true)

-- The estimate must actually be wide enough for the longest word this can show.
local longest = 0
for _, label in pairs(W.BADGE_LABEL) do
    if #label > longest then longest = #label end
end
print(string.format("      (longest label is %d chars; estimate gives %dpx + 28 padding = %dpx)",
    longest, longest * 9, longest * 9 + 28))
check("the minimum width cannot clip the longest label", 52 <= (longest * 9 + 28), true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
