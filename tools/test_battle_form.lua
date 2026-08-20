-- THE BATTLE FORM MUST NOT LAND ON ITSELF.
--
--   Run: lua tools/test_battle_form.lua
--
-- Every row of the create-battle modal is the same three things — a small
-- label, a control, and a grey hint line — and each one used to be positioned
-- by its own hand-picked offset. That produced two visible faults:
--
--   * BATTLE TYPE sat 140px above ENTRY FEE while ENTRY FEE sat 130 above the
--     row below it, so the form read as a stack of unrelated widgets rather
--     than as one thing to fill in
--   * a PARTY set to SCORE CAP grew a FOURTH row that nothing had reserved
--     space for. Its hint landed on the error line and it pushed the submit
--     button into the bottom of the screen
--
-- The offsets are constants now, applied identically to every row, and the
-- party's cap picker moved INLINE beside PLAY MODE — which is what the
-- horizontal space on this screen was always for, and which costs no height at
-- all.
--
-- Nothing in Defold measures text at build time, so none of this is caught by
-- running the game unless you happen to open the one combination that breaks.
-- The source is read and its arithmetic re-done here instead — the same
-- approach tools/test_banner_layout.lua takes to the invite strip, and for the
-- same reason.

local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or ""))
    end
end

local f = assert(io.open(here .. "/../modules/online_right.lua"))
local SRC = f:read("*a")
f:close()

local function num(pattern, label)
    local v = SRC:match(pattern)
    check("source carries " .. label, v ~= nil, "pattern did not match")
    return tonumber(v) or 0
end

-- ── The constants the layout is built from ───────────────────────────────────

local LABEL_DY = num("local ROW_LABEL_DY%s*=%s*(%d+)", "ROW_LABEL_DY")
local HINT_DY  = num("local ROW_HINT_DY%s*=%s*(%d+)", "ROW_HINT_DY")
local CTRL_H   = num("local CTRL_H%s*=%s*(%d+)", "CTRL_H")

-- Row centres, as offsets from CY (positive is up, as in Defold's gui).
--
-- `label` and `hint` say which captions a row actually carries, because that
-- is what decides how far its ink reaches. BATTLE TYPE has a label and no hint
-- — the segments explain themselves — while ENTRY FEE and the row under it
-- have both.
local ROWS = {
    { name = "title",  y = num("ui%.text%(vmath%.vector3%(CX, CY %+ (%d+), 0%), title,", "the title's y"), h = 40 },
    { name = "type",   y = num("local type_y = CY %+ (%d+)", "type_y"), h = CTRL_H, label = true },
    { name = "fee",    y = num("local fee_y%s*= CY %+ (%d+)", "fee_y"), h = CTRL_H, label = true, hint = true },
    { name = "opt",    y = -num("local opt_y%s*= CY %- (%d+)", "opt_y"), h = CTRL_H, label = true, hint = true },
    { name = "msg",    y = -num("local msg_y%s*= CY %- (%d+)", "msg_y"), h = 18 },
    { name = "submit", y = -num("local sub_y%s*= CY %- (%d+)", "sub_y"), h = 68 },
}

-- Half the height of a line of the "small" font, as drawn on this form. Not
-- measurable from here — Defold does the measuring — so this is the working
-- figure the spacing is designed against, and it is deliberately generous.
local SMALL_HALF = 9

print("\n== the rows descend, in order, without touching ==")
do
    for i = 1, #ROWS - 1 do
        local a, b = ROWS[i], ROWS[i + 1]
        check(a.name .. " sits above " .. b.name, a.y > b.y,
            ("%s at %d, %s at %d"):format(a.name, a.y, b.name, b.y))
    end

    -- The real test: the bottom-most ink of each row against the top-most ink
    -- of the next. A row's ink runs from its hint (if it has one) to its label.
    local function bottom(r)
        if r.hint then return r.y - HINT_DY - SMALL_HALF end
        return r.y - r.h / 2
    end
    local function top(r)
        if r.label then return r.y + LABEL_DY + SMALL_HALF end
        return r.y + r.h / 2
    end

    for i = 1, #ROWS - 1 do
        local a, b = ROWS[i], ROWS[i + 1]
        local gap = bottom(a) - top(b)
        check(a.name .. " clears " .. b.name, gap >= 12,
            ("only %d px between them"):format(gap))
    end
end

print("\n== a label never touches the box it belongs to ==")
do
    -- Both offsets are measured from the control's CENTRE, so the clearance is
    -- the offset minus half the control minus half a line of text. This is the
    -- number that goes negative first if anyone tightens the form.
    local label_gap = LABEL_DY - CTRL_H / 2 - SMALL_HALF
    local hint_gap  = HINT_DY - CTRL_H / 2 - SMALL_HALF
    check("the label clears its control", label_gap >= 5, ("%d px"):format(label_gap))
    check("the hint clears its control", hint_gap >= 5, ("%d px"):format(hint_gap))
end

print("\n== every row uses the shared offsets ==")
do
    -- The modal body only. Anything past the submit button belongs to the
    -- other panels in this file.
    local body = SRC:match("%-%- ── The rows ─(.-)id = \"bm_submit\"") or ""
    check("the modal body was found", #body > 500, ("%d chars"):format(#body))

    -- The old code positioned captions with literal "+ 46" and hints with
    -- "- 42" at each site. One surviving literal is one row that will not move
    -- when the constants do.
    local literals = 0
    for _ in body:gmatch("[yY]_?%w* [%+%-] 4[26]") do literals = literals + 1 end
    check("no hand-picked label/hint offsets survive", literals == 0,
        ("found %d"):format(literals))

    -- Every stepper on the form goes through the one helper. There were four
    -- copies of it inline, which is how the party cap ended up drawn at a
    -- different size from its neighbours.
    local inline_steppers = 0
    for _ in body:gmatch("mkbtn%(self, \"bm_%w+_minus\"") do inline_steppers = inline_steppers + 1 end
    check("no stepper is still built inline", inline_steppers == 0,
        ("found %d"):format(inline_steppers))

    local calls = 0
    for _ in body:gmatch("\n%s+stepper%(self, ctx,") do calls = calls + 1 end
    check("all four steppers call the helper", calls == 4, ("found %d"):format(calls))
end

print("\n== the party row is two columns, and they clear each other ==")
do
    -- stepper_width: the value box plus a button either side, each with 8px of
    -- air. Re-done here rather than trusted, since it is what the column
    -- arithmetic below depends on.
    local pad = num("return box_w %+ 2 %* %(btn %+ (%d+)%)", "the stepper's button padding")
    local function stepper_width(box_w, btn) return box_w + 2 * (btn + pad) end

    local mode_w_capped  = num("capped and (%d+) or %d+, %d+", "the capped PLAY MODE width")
    local mode_w_alone   = num("capped and %d+ or (%d+), %d+", "the uncapped PLAY MODE width")
    local mode_gap       = num("capped and %d+ or %d+, (%d+)", "the segment gap")
    local cap_box, cap_btn = SRC:match("local cap_box, cap_btn = (%d+), (%d+)")
    check("source carries the cap stepper's size", cap_box ~= nil)
    cap_box, cap_btn = tonumber(cap_box) or 0, tonumber(cap_btn) or 0
    local col_gap = num("local col_gap = (%d+)", "the column gap")

    local mode_span = 2 * mode_w_capped + mode_gap
    local cap_span  = stepper_width(cap_box, cap_btn)

    -- The pair is centred as a whole, which is what makes it read as one row
    -- rather than as two things that happen to share a y.
    local CX = 640 -- LOGICAL_W / 2
    local left = CX - (mode_span + col_gap + cap_span) / 2
    local mode_cx = left + mode_span / 2
    local cap_cx  = left + mode_span + col_gap + cap_span / 2

    check("the columns do not overlap",
        (cap_cx - cap_span / 2) - (mode_cx + mode_span / 2) >= 40,
        ("gap %d"):format((cap_cx - cap_span / 2) - (mode_cx + mode_span / 2)))

    -- The close button sits at CX + 340, so that is the content edge.
    local edge = 340
    check("the pair fits the content width",
        (mode_cx - mode_span / 2) >= CX - edge and (cap_cx + cap_span / 2) <= CX + edge,
        ("spans %d..%d"):format(mode_cx - mode_span / 2, cap_cx + cap_span / 2))

    -- Uncapped, PLAY MODE keeps the middle to itself: a lone control pushed
    -- off to one side of an empty half reads as something failing to draw.
    check("alone, PLAY MODE is centred", SRC:find("local mode_cx, cap_cx = CX, CX", 1, true) ~= nil)
    check("and it is drawn wider when alone", mode_w_alone > mode_w_capped,
        ("%d vs %d"):format(mode_w_alone, mode_w_capped))

    -- The inline cap must be narrower than the full-width fee stepper above
    -- it, or it is not sharing the row, it is fighting for it.
    local step_w = num("local STEP_W = (%d+)", "STEP_W")
    check("the inline cap is narrower than the fee stepper",
        cap_span < stepper_width(step_w, CTRL_H),
        ("%d vs %d"):format(cap_span, stepper_width(step_w, CTRL_H)))
end

print("\n== the form still fits the screen ==")
do
    local CY = 360 -- LOGICAL_H / 2
    local top = ROWS[1].y + ROWS[1].h / 2
    local bottom_row = ROWS[#ROWS]
    local bottom = bottom_row.y - bottom_row.h / 2
    check("nothing runs off the top", CY + top <= 720, ("top at %d"):format(CY + top))
    check("nothing runs off the bottom", CY + bottom >= 0, ("bottom at %d"):format(CY + bottom))
end

print("")
if fail == 0 then
    print(("ALL %d CHECKS PASSED"):format(pass))
else
    print(("%d of %d CHECKS FAILED"):format(fail, pass + fail))
    os.exit(1)
end
