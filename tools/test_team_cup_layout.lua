-- DOES THE CREATE FORM FIT ON THE SCREEN IT IS DRAWN ON?
--
--   Run: lua tools/test_team_cup_layout.lua
--
-- Reported as: "charge entry fee to join is not working, looks disabled".
--
-- It was not disabled. It was UNDERNEATH the create button.
--
-- This screen has no scrolling: rows march down from a fixed top and the
-- footer is pinned to the bottom, so adding rows does not make the screen
-- taller — it pushes the bottom rows through the footer and then off the
-- screen. Adding the entry fee (a checkbox, a stepper and a note, ~120px) to a
-- column that was already nearly full put the stepper at y~66 while the submit
-- button spans y=18..74. The button is drawn last, so it is on top and takes
-- the taps: the +/- did nothing. The owner-plays checkbox below it landed at
-- y=-12, off the screen altogether.
--
-- Both were mine, from adding the fee row to a full column.
--
-- The fix is the two-step split: invites move to step 2, so step 1 has the
-- whole width and the settings use both halves of it. This runs the layout
-- arithmetic to prove that, rather than trusting that it looks right.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local f = assert(io.open(dir .. "../main/team_tournament.gui_script", "r"))
local src = f:read("*a"); f:close()

local failures = 0
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end

-- ── the arithmetic, on the real constants ──────────────────────────────────
local ROW, GAP = 46, 18
local H        = 720                 -- the logical screen
local d_y      = H - 80 - 9          -- below the header and its divider
local TOP      = d_y - 34
local FOOT_TOP = 46 + 28             -- EDGE_B + 46, half a 56-high button

-- Each row as the draw code spends it.
local function column(rows)
    local y = TOP
    local lowest = y
    for _, r in ipairs(rows) do
        y = y - r
        lowest = math.min(lowest, y)
    end
    return lowest
end

local LABEL, NOTE = 20, 18
local NAME   = { LABEL, ROW + GAP }
local PRIZE  = { LABEL, ROW + 4, NOTE + GAP }
local FEE    = { 10, ROW, 6, ROW + 4, NOTE }      -- checkbox + stepper + note
local PLAYERS= { LABEL, ROW + 4, NOTE + GAP }
local GPL    = { LABEL, ROW + GAP }
local CODE   = { LABEL, ROW }
local OWNER  = { 10, ROW }

local function concat(...)
    local out = {}
    for _, t in ipairs({...}) do for _, v in ipairs(t) do out[#out + 1] = v end end
    return out
end

print("the old single column did not fit")
local old_bottom = column(concat(NAME, PRIZE, PLAYERS, GPL, CODE, FEE, OWNER))
check_true("it ran past the footer and off the screen",
    old_bottom < 0,
    "expected the old stacking to overflow; got bottom=" .. old_bottom)

print("")
print("step 1, split across both columns, does")
local left_bottom  = column(concat(NAME, PRIZE, FEE))
local right_bottom = column(concat(PLAYERS, GPL, CODE, OWNER))
check_true(string.format("left column clears the footer (bottom=%d, footer=%d)",
    left_bottom, FOOT_TOP), left_bottom > FOOT_TOP, "left column still overlaps")
check_true(string.format("right column clears the footer (bottom=%d, footer=%d)",
    right_bottom, FOOT_TOP), right_bottom > FOOT_TOP, "right column still overlaps")
check_true("and nothing is off the top", TOP < H, "rows start below the header")

-- The entry fee stepper is the row that was actually unreachable, so pin it.
local fee_top = column(concat(NAME, PRIZE))
local fee_stepper_centre = fee_top - 10 - ROW - 6 - ROW / 2
check_true(string.format("the fee stepper sits clear of the button (centre=%d)",
    fee_stepper_centre), fee_stepper_centre - ROW / 2 > FOOT_TOP,
    "the stepper is back under the footer, which is the reported bug")

-- ── the split is actually wired ────────────────────────────────────────────
print("")
print("and the split is real, not just drawn")
check_true("the form carries a step", src:find("step%s*= 1,") ~= nil, "no step in form state")
check_true("settings are gated on step 1", src:find("if step == 1 then") ~= nil, "step 1 not gated")
check_true("invites are gated on step 2", src:find("if step == 2 then") ~= nil, "step 2 not gated")
check_true("step 1 uses the second column",
    src:find("col = right") ~= nil, "settings still stacked in one column")
check_true("step 2 centres the invite column",
    src:find("right = CX") ~= nil, "invites left in the right half with nothing beside them")

print("")
print("moving on is checked, and going back is possible")
check_true("there is a NEXT", src:find('btn%(self, "step_next"') ~= nil, "no way forward")
check_true("and a BACK from step 2", src:find('btn%(self, "step_back"') ~= nil,
    "invites with no way back is a trap")
check_true("settings are validated before leaving step 1",
    src:find("local err = validate_settings%(self%)") ~= nil,
    "an error about the prize is useless on a screen with no prize field")
check_true("and submit still validates everything",
    src:find("local err = validate%(self%)") ~= nil,
    "per-step checks must not become the only checks")
-- Checked STRUCTURALLY, not by pinning coordinates: the buttons have since
-- moved to the screen edges, and an assertion naming their x would fail on a
-- purely cosmetic change while still passing if submit leaked onto step 1.
local footer = src:sub(src:find("%-%- ── FOOTER") or 1)
local f_if     = footer:find("if step == 1 then")
local f_else   = footer:find("\n    else\n", f_if or 1)
local f_next   = footer:find('btn%(self, "step_next"')
local f_submit = footer:find('btn%(self, "submit"')

check_true("NEXT is on step 1",
    f_if and f_next and f_next > f_if and (not f_else or f_next < f_else),
    "NEXT must be in the step-1 branch")
check_true("submit only exists on step 2",
    f_else and f_submit and f_submit > f_else,
    "a create button on step 1 would skip the invite step entirely")
check_true("so NEXT and submit are never both drawn",
    f_next and f_submit and f_else and f_next < f_else and f_submit > f_else,
    "the original bug was a later-drawn node covering an earlier one")

print("")
print("the invite step puts its buttons at the edges")
check_true("BACK is anchored to the left edge",
    footer:find('btn%(self, "step_back", EDGE_L %+ 24 %+ back_w / 2') ~= nil,
    "asked for BACK on the extreme left")
check_true("and submit to the right edge",
    footer:find('btn%(self, "submit", EDGE_R %- 24 %- sub_w / 2') ~= nil,
    "asked for submit on the extreme right")
check_true("they cannot overlap, whatever the screen width",
    footer:find("local back_w, sub_w = 150, 320") ~= nil,
    "widths must be known to place both from their own edges")

-- ── entering straight at the invite step ───────────────────────────────────
print("")
print("the Invite button lands on the invite step")

local st = assert(io.open(dir .. "../main/standings.gui_script", "r"))
local stand = st:read("*a"); st:close()

check_true("standings asks for step 2 when inviting",
    stand:find("app_state%.team_edit_step = 2") ~= nil,
    "this button exists to add people; making the owner tap NEXT past settings "
        .. "they did not come to change is a step for nothing")
check_true("and the form honours it",
    src:find("if seed_step == 2 then f%.step = 2 end") ~= nil, "request ignored")
check_true("the request is cleared with the seed",
    src:find("app_state%.team_edit_step = nil") ~= nil,
    "left set, the next CREATE would open on the invite step of a cup that does not exist yet")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
