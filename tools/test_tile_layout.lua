-- THE SPACING INSIDE A MODE TILE, CHECKED RATHER THAN EYEBALLED.
--
--   Run: lua tools/test_tile_layout.lua
--
-- Reported as: the ONLINE / TEAM tags need spacing, PLAY ONLINE and its
-- subtitle should sit higher, and SEASON ENDS IN needs more room.
--
-- All three are the same two mistakes.
--
-- 1. The second tag was drawn at a FIXED +55px from the first, whatever the
--    first one said. Comfortable after "LIVE"; too narrow after "ONLINE" and
--    "OFFLINE". So the pair ran together on TEAM CUPS and looked fine on PLAY
--    ONLINE, which is why it read as one tile's problem.
--
-- 2. Every row hung off the tile's CENTRE. A taller tile therefore spent all
--    its extra height as dead space above the title and none of it on the
--    content — 116px of nothing on the real geometry — while at the bottom the
--    season deadline line came out level with the PLAY NOW pill.
--
-- These run the arithmetic against the lobby's ACTUAL numbers rather than
-- against invented ones, because "it fits" is only a claim about the tiles
-- that exist.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

-- theme.lua builds colour constants at load, so it needs vmath even though
-- nothing here reads a colour.
vmath = { vector4 = function(a, b, c, d) return { a, b, c, d } end }

local L = require("modules.lobby.tile_layout")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- ── the real lobby geometry ────────────────────────────────────────────────
-- Recomputed here from theme.lua's constants exactly as lobby.gui_script does,
-- so a change to the grid shows up as a failure here rather than as a tile
-- that quietly stops fitting.
local T = require("modules.lobby.theme")
local util_h = 56
local grid_b = T.EDGE_B + T.PADDING + util_h + T.GUTTER
local grid_t = T.EDGE_T - T.PADDING - T.HEADER_H
local grid_h = grid_t - grid_b
local row_a_h = math.floor((grid_h - T.GUTTER) * 0.62)
local row_b_h = grid_h - row_a_h - T.GUTTER
local row_a_cy = grid_b + row_b_h + T.GUTTER + row_a_h / 2
local row_b_cy = grid_b + row_b_h / 2

print(string.format("PLAY ONLINE / TEAM CUPS tile: h=%d centre=%.1f", row_a_h, row_a_cy))
local big = L.rows(row_a_cy, row_a_h)
print(string.format("      tag=%.0f title=%.0f sub=%.0f season=%.0f count=%.0f deadline=%.0f cta=%.0f floor=%.0f",
    big.tag, big.title, big.sub, big.season_label, big.season_count, big.season_deadline, big.cta, big.bottom))

print("")
print("EVERY ROW READS TOP TO BOTTOM, IN ORDER")
local order = { "top", "tag", "title", "sub", "season_label", "season_count", "season_deadline", "cta", "bottom" }
local descending = true
for i = 2, #order do
    if not (big[order[i]] < big[order[i - 1]]) then descending = false end
end
check("no row is above the one before it", descending, true)

print("")
print("THE SEASON BLOCK CLEARS THE CTA")
-- The one that was actually broken. On this geometry the deadline line came
-- out at 354.5 and the CTA centre at 354 — the same row. They did not overlap
-- only because one is left-aligned and the other right-aligned, which is luck,
-- not layout.
check("the deadline sits above the CTA pill", big.season_deadline > big.cta_top, true)
print(string.format("      (clearance: %.0fpx)", big.season_deadline - big.cta_top))
check("with real clearance, not a hair", (big.season_deadline - big.cta_top) >= 10, true)

print("")
print("NOTHING ESCAPES THE TILE")
check("the tag row is inside the top", big.tag < big.top, true)
check("the CTA is inside the floor", (big.cta - L.CTA_H / 2) > big.bottom, true)

print("")
print("THE DEAD SPACE AT THE TOP IS GONE")
-- What "extend it more on top" is asking for: the title moves UP into the gap
-- the old centre-anchored stack left empty.
local old_title = row_a_cy + 15                 -- the expression this replaces
print(string.format("      (title was at %.0f, now at %.0f — %.0f px higher)",
    old_title, big.title, big.title - old_title))
check("the title is higher than it was", big.title > old_title, true)
-- Anchored to the tag row, so the gap above the title is a fixed, small
-- number instead of "whatever is left over".
check("the gap under the tag row is the constant, not the leftover",
    big.tag - big.title, L.TITLE_DROP)
check("and that is far less than the 116px it used to be",
    L.TITLE_DROP < 60, true)

print("")
print("SEASON ENDS IN HAS ITS OWN GAP")
-- It used to sit 30px under the subtitle — the same spacing as a line inside a
-- paragraph, so it read as a third line of the subtitle rather than as a
-- separate block.
check("the gap above it is bigger than the gap inside it",
    L.SEASON_GAP > L.SEASON_LINE, true)
check("and bigger than the title-to-subtitle gap", L.SEASON_GAP > L.SUB_DROP, true)
check("sub-to-season gap", big.sub - big.season_label, L.SEASON_GAP)

print("")
print("THE SMALL OFFLINE TILES STILL FIT")
-- The same rule applies to row B, which is a lot shorter. Top-anchoring must
-- not push their content off the bottom.
local small = L.rows(row_b_cy, row_b_h)
print(string.format("      QUICK PLAY etc: h=%d tag=%.0f title=%.0f sub=%.0f cta=%.0f floor=%.0f",
    row_b_h, small.tag, small.title, small.sub, small.cta, small.bottom))
check("the subtitle clears the CTA", small.sub > small.cta_top, true)
check("the title is inside the tile", small.title < small.top and small.title > small.bottom, true)
check("the tag row is inside the tile", small.tag < small.top, true)

print("")
print("THE TAG GAP FOLLOWS THE WORD IN FRONT OF IT")
local x0 = 0
local live    = L.second_tag_x(x0, "LIVE")
local online  = L.second_tag_x(x0, "ONLINE")
local offline = L.second_tag_x(x0, "OFFLINE")
print(string.format("      LIVE→%.0f  ONLINE→%.0f  OFFLINE→%.0f  (old: 55 for all three)",
    live, online, offline))
check("a longer tag pushes the second one further right", online > live, true)
check("and longer again", offline > online, true)
-- The bug, stated as a number. 55px was never enough for the two tiles that
-- are not PLAY ONLINE.
check("the old fixed 55 was too narrow for ONLINE", online > 55, true)
check("and for OFFLINE", offline > 55, true)
check("but it was fine for LIVE, which is why nobody caught it", live <= 55, true)

print("")
print("A MEASURED WIDTH BEATS THE ESTIMATE")
-- On a device gui.get_text_metrics_node answers and the estimate is unused.
check("measured is used when present", L.second_tag_x(0, "LIVE", 100), 100 + L.TAG_GAP)
check("the estimate fills in when it is not", L.second_tag_x(0, "LIVE", nil), 4 * L.EST_CHAR_W + L.TAG_GAP)
check("a zero measurement is not trusted", L.second_tag_x(0, "LIVE", 0), 4 * L.EST_CHAR_W + L.TAG_GAP)
check("nor is a nonsense one", L.second_tag_x(0, "LIVE", "wide"), 4 * L.EST_CHAR_W + L.TAG_GAP)

print("")
print("Nothing here can raise")
-- It runs inside the lobby rebuild, which repaints on every auth event.
check("a nil label", L.tag_width(nil), 0)
check("an empty label", L.tag_width(""), 0)
check("rows on a zero-height tile", type(L.rows(0, 0).title), "number")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
