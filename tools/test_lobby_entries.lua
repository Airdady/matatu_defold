-- WHERE THE MODES ARE REACHED FROM, AND WHICH ONES ARE ON SHOW.
--
--   Run: lua tools/test_lobby_entries.lua
--
-- Three entry points moved and then moved back, and each move is one line in
-- one place while the machinery behind it stays mounted. That is the property
-- worth pinning: a feature taken off screen must lose its ENTRY POINT and
-- nothing else, so putting it back is one edit rather than an excavation.
--
--   TOURNAMENTS   players list -> lobby tile -> players list again
--   TEAM CUPS     lobby tile -> unmounted -> lobby tile again
--   PARTY         shown -> hidden (its logic all still here)
--
-- Source is read rather than run: these are gui_scripts, and what is being
-- checked is which entry points EXIST, which is a property of the text.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

-- Most of this file reads source rather than running it — what is being
-- checked is which entry points EXIST, which is a property of the text. The
-- pulse is the exception: its shape is arithmetic, so it is exercised for
-- real, and that needs the engine stubbed.
local SIM = dofile(here .. "/defold_sim.lua")
SIM.install_gui_stub()
_G.window.set_listener = function() end
_G.http = { request = function() end }

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1
        print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or ""))
    end
end
local function read(rel)
    local f = assert(io.open(here .. "/../" .. rel))
    local s = f:read("*a"); f:close(); return s
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local RIGHT = read("modules/online_right.lua")
local LOBBY = read("main/lobby.gui_script")

----------------------------------------------------------------------
print("TOURNAMENTS IS BACK IN THE PLAYERS LIST")
----------------------------------------------------------------------
check("the row draws a tournaments button", has(RIGHT, '"nav_tournaments"'))
check("with its icon", has(RIGHT, '"tournament_icon"'))
check("and its title", has(RIGHT, '"TOURNAMENTS"'))

-- CENTRED MEANS THE ICON AND THE TEXT TOGETHER. Centring the text alone and
-- hanging an icon off its left puts the visible pair off-centre by half an
-- icon — which is why the row measures before it places anything.
check("the title is measured, not guessed", has(RIGHT, "gui.get_text_metrics_from_node"))
check("...and the icon and text are centred as one group", has(RIGHT, "group_w"))
check("...with a fallback if measuring fails", has(RIGHT, "#title_txt"))

----------------------------------------------------------------------
print("")
print("THE BADGE SAYS SOMETHING TRUE")
----------------------------------------------------------------------
-- It read "NEW". That was accurate for about a day after the feature shipped
-- and decoration ever since.
-- Checked against the source with its comments stripped: the word survives in
-- the note explaining why it went, and matching that would make this pass for
-- the wrong reason the day somebody deletes the note.
local RIGHT_CODE = RIGHT:gsub("%-%-[^\n]*", "")
check("nothing draws the word NEW any more", not has(RIGHT_CODE, '"NEW"'))
check("it reads the live window instead", has(RIGHT, "tournament_window.status_label"))
check("...for the current minute of the day", has(RIGHT, "tournament_window.minute_of_day"))
check("open and closed look different", has(RIGHT, 'is_open and vmath.vector4(0.15, 0.8, 0.25'))

-- "CLOSED" is six characters where "NEW" was three and always would be, so a
-- fixed 48-wide badge would have had the word hanging out of both ends.
check("the badge is sized to its word", has(RIGHT, "badge_w = math.max"))
check("...with a fallback if measuring fails", has(RIGHT, "#t_status * 11"))
-- NOT the box's exact centre — see the block below.
check("...and the label sits where its ink centres",
      has(RIGHT, "gui.set_position(bn, vmath.vector3(nx, tcy2 - bdrop, 0))"))
-- The old row drew a hairline across the badge's top edge, which read as the
-- label sitting low in its box rather than as a border.
check("with no hairline to sit under", not has(RIGHT, "ny + 11"))

----------------------------------------------------------------------
print("")
print("THE LABEL IS DRAWN ON TOP OF ITS BADGE, NOT UNDER IT")
----------------------------------------------------------------------
-- Reported as "green badge with no text". The word was there the whole time,
-- underneath: Defold draws gui nodes in CREATION ORDER, so a box created after
-- its label is a box drawn over its label.
--
-- The row this replaced had it right — box, then text. Measuring the label in
-- order to size the box is what tempted the order to be flipped, and it does
-- not have to be: the box is made at a provisional size, the label goes on top
-- of it, and the box is resized once the label has been measured.
local badge_block = RIGHT:match("if t_status then(.-)\n    end") or ""
check("the badge block was found", #badge_block > 0)

local box_at  = badge_block:find("ui.box(", 1, true)
local text_at = badge_block:find("ui.text(", 1, true)
check("the badge box exists", box_at ~= nil)
check("its label exists", text_at ~= nil)
check("and the label is created AFTER the box, so it draws on top",
      box_at and text_at and box_at < text_at,
      string.format("box@%s text@%s", tostring(box_at), tostring(text_at)))
check("the box is resized after the label is measured, not created after it",
      has(badge_block, "gui.set_size(badge"))

-- LYING SLIGHTLY HIGH, reported after the box stopped covering it entirely.
--
-- A text node's pivot is the centre of its LINE BOX — ascent plus descent —
-- not the centre of the ink. The descent is space reserved for the tails of
-- g, j, p, q, y, and an all-caps word has none of them, so that reservation is
-- empty space hanging below the letters and centring the line box puts the
-- letters high.
--
-- The exact correction is (ascent - descent - capHeight) / 2, and Defold
-- reports ascent and descent but never cap height. Half a descent is the
-- upper end of that range — it assumes capitals reach the full ascent — and it
-- overshot: the word went from sitting high to sitting low. A quarter is the
-- middle of the range, which is the most the metrics available can justify.
check("the box takes the true centre",
      has(badge_block, "gui.set_position(badge, vmath.vector3(nx, tcy2, 0))"))
check("...and the label drops by its own metrics to match",
      has(badge_block, "tcy2 - bdrop"))
check("the drop is measured, not eyeballed", has(RIGHT, "max_descent"))
local frac = tonumber(RIGHT:match("max_descent or 0%) %* sc%.y%) / (%d+)"))
check("...and scaled to the middle of the range it cannot measure",
      frac == 4, tostring(frac))
local fb = tonumber(RIGHT:match("drop = ([%d%.]+)%s*end"))
check("with a fallback when measuring fails, on the same scale",
      fb ~= nil and fb > 0 and fb <= 2, tostring(fb))

-- The other half of "add some padding on top": a 25pt face in a 24px box is
-- tight enough that any error in where the word sits shows up at once.
local bh = tonumber(badge_block:match("BADGE_H%s*=%s*(%d+)"))
check("the badge has breathing room", bh ~= nil and bh >= 26, tostring(bh))

-- TOO WIDE, the other half of the report. Twelve a side around a four-letter
-- word in a condensed face is a badge; twenty-two, which is what this first
-- shipped with, is nearly two extra characters of air and reads as a banner.
local pad = tonumber(badge_block:match("BADGE_PAD%s*=%s*(%d+)"))
check("the padding is snug", pad ~= nil and pad <= 14, tostring(pad))
local floor_w = tonumber(badge_block:match("math%.max%((%d+),"))
check("...and the minimum width is not a banner either", floor_w ~= nil and floor_w <= 56, tostring(floor_w))

----------------------------------------------------------------------
print("")
print("OPEN BREATHES, CLOSED SITS STILL")
----------------------------------------------------------------------
-- CLOSED is a fact. OPEN is an invitation with a clock on it — the
-- championship runs a daily window and shuts again — so only one of them has
-- any reason to move. A pulse on both would say nothing.
check("the pulse is conditional on being open",
      badge_block:match("if is_open then") ~= nil)
check("...and the node is handed to the host to tick",
      has(badge_block, "self.tourn_badge_node = badge"))
check("...and cleared when there is nothing to breathe",
      has(RIGHT, "self.tourn_badge_node = nil"))

-- NOT gui.animate, which is what everything else on this screen uses. Two
-- reasons, and the second is fatal on its own:
--
--   1. rebuild() deletes and recreates every node here, and a fresh node has
--      no animation. Rebuilds are not rare — a banner rebuilds once a second,
--      a socket burst up to twelve times a second, and the savings promo
--      rebuilds EVERY FRAME while it types itself out. A looping tween
--      restarted sixty times a second never leaves the start of its first
--      ease: the badge would sit perfectly still.
--
--   2. PLAYBACK_LOOP_PINGPONG oscillates between the value the node HAD when
--      the animation started and the target, so it cannot be seeded to the
--      right phase to survive those restarts without corrupting the
--      amplitude. Phase continuity and correct amplitude are mutually
--      exclusive with that playback mode.
local RIGHT_CODE2 = RIGHT:gsub("%-%-[^\n]*", "")
check("no tween is left to be restarted by a rebuild",
      not has(RIGHT_CODE2, "PLAYBACK_LOOP_PINGPONG"))
check("it is written into the node from a clock instead",
      has(RIGHT, "function M.pulse_badge"))
check("...and the host ticks it every frame",
      has(read("main/online.gui_script"), "right_panel.pulse_badge(self, self.ui_clock)"))
check("...off a monotonic clock that survives rebuilds",
      has(read("main/online.gui_script"), "self.ui_clock = (self.ui_clock or 0) + dt"))

----------------------------------------------------------------------
print("")
print("THE BREATH ITSELF")
----------------------------------------------------------------------
local R = require("modules.online_right")

local function approx(name, got, want, tol)
    check(name, math.abs(got - want) <= (tol or 0.0005),
          string.format("%.4f vs %.4f", got, want))
end

approx("starts at rest", R.badge_pulse_scale(0), 1)
approx("swells fully at the half-way point",
       R.badge_pulse_scale(R.BADGE_PULSE_PERIOD / 2), 1 + R.BADGE_PULSE_AMOUNT)
approx("and is back at rest a second later", R.badge_pulse_scale(R.BADGE_PULSE_PERIOD), 1)
approx("...and every second after that", R.badge_pulse_scale(R.BADGE_PULSE_PERIOD * 97), 1)
check("a full pump takes about a second", R.BADGE_PULSE_PERIOD == 1.0)
check("and it is gentle", R.BADGE_PULSE_AMOUNT <= 0.10, tostring(R.BADGE_PULSE_AMOUNT))

-- A RAISED COSINE, NOT A TRIANGLE. It leaves 1.0 and returns to it with zero
-- velocity, so there is no corner at either end of the breath — a triangle
-- wave would tick audibly, visually.
local prev, vprev = R.badge_pulse_scale(0), nil
local lo, hi, max_jerk = 2, 0, 0
for i = 1, 600 do
    local v = R.badge_pulse_scale(i / 600 * R.BADGE_PULSE_PERIOD)
    local dv = v - prev
    if vprev then max_jerk = math.max(max_jerk, math.abs(dv - vprev)) end
    vprev, prev = dv, v
    lo, hi = math.min(lo, v), math.max(hi, v)
end
approx("never dips below rest", lo, 1, 0.0001)
approx("never overshoots the amplitude", hi, 1 + R.BADGE_PULSE_AMOUNT, 0.001)
check("and has no corner in it", max_jerk < 0.00002, string.format("%.8f", max_jerk))

-- PHASE CONTINUITY IS THE WHOLE POINT. Two rebuilds a millisecond apart must
-- land on the same value, because the clock is the only thing that decides it.
approx("the same instant gives the same breath",
       R.badge_pulse_scale(4.237), R.badge_pulse_scale(4.237))
approx("...and it does not care when the last rebuild was",
       R.badge_pulse_scale(4.237), R.badge_pulse_scale(4.237 + R.BADGE_PULSE_PERIOD * 3))
check("rubbish does not throw", R.badge_pulse_scale(nil) == 1)

-- The host calls this every frame whether or not there is a badge.
check("nothing to pulse is not an error", R.pulse_badge({}, 1.0) == false)
check("...nor is a screen that has not drawn yet", R.pulse_badge(nil, 1.0) == false)

----------------------------------------------------------------------
print("")
print("TEAM CUPS HAS ITS LOBBY TILE BACK")
----------------------------------------------------------------------
check("the tile is titled TEAM CUPS", has(LOBBY, 'title       = "TEAM CUPS"'))
check("...tagged as a team mode", has(LOBBY, 'top_left_2  = "TEAM"'))
check("...and wired to its own children", has(LOBBY, "child_buttons = is_exhausted and nil or team_children"))
check("the tile no longer points at tournaments",
      not has(LOBBY, 'btn_id      = is_exhausted and team_btn_id or "nav_tournaments_lobby"'))

-- Kept for the same reason nav_tournaments was kept while the move was the
-- other way round: it costs one branch, and it is where a stale build or a
-- deep link still lands.
check("the lobby's tournaments handler is still reachable by a deep link",
      has(LOBBY, 'elseif b.id == "nav_tournaments_lobby" then'))

----------------------------------------------------------------------
print("")
print("PARTY IS UNMOUNTED, NOT DELETED")
----------------------------------------------------------------------
local visible = RIGHT:match("M%.BATTLE_TYPES_VISIBLE%s*=%s*{([^}]*)}") or ""
check("party is off the screen", not has(visible, "PARTY"), visible)
check("...while battle and knockout stay",
      has(visible, "NORMAL") and has(visible, "KNOCKOUT"), visible)

-- The one list is the whole switch: it feeds both the lobby's battle rows and
-- the type picker in the maker, so the word coming out takes party off both
-- and nothing else.
check("one list drives the rows and the picker",
      select(2, RIGHT:gsub("BATTLE_TYPES_VISIBLE", "")) >= 3)

-- Everything behind it stays exactly where it is. Put the word back and all
-- of this returns.
for _, kept in ipairs({
    "PARTY_TIERS", "PARTY_MODES", "PARTY_CAPS", "PARTY_DEFAULT_CAP_I",
    "is_party", "partyRules.ts",
}) do
    check("still here: " .. kept, has(RIGHT, kept))
end
check("party is still a type the maker can build", has(RIGHT, 'M.BATTLE_TYPES = { "NORMAL", "KNOCKOUT", "PARTY" }'))
check("...and still submits as one", has(RIGHT, 'btype ~= "KNOCKOUT" and btype ~= "PARTY"'))

print("")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
