-- WHERE THE TOURNAMENTS ROW ACTUALLY LANDS.
--
--   Run: lua tools/test_tournaments_row.lua
--
-- tools/test_lobby_entries.lua checks what the source SAYS about this control.
-- This one RENDERS it — the real draw_tournaments_row against the gui stub in
-- defold_sim — and measures the nodes that come out. That is the only way to
-- catch the class of bug this control has actually had: a piece drawn
-- somewhere other than where its arithmetic reads as drawing it.
--
-- It has been three shapes. A full-width row; then a 76px circle, which
-- carries one glyph, so the word came off it and the OPEN/CLOSED badge hung
-- half off the bottom edge; then a floating bar, which fixed the word and the
-- badge and left the floating. It is a row again, and what the two floating
-- passes were worth is the layout INSIDE it. So the three things pinned here
-- are the three that have gone wrong: the row fills the panel and sits in
-- flow, the word is on it, and the badge is inside it.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local SIM = dofile(here .. "/defold_sim.lua")
SIM.install_gui_stub()
_G.window = _G.window or {}
_G.window.set_listener = function() end
_G.http = { request = function() end }

local ui    = require("modules.ui")
local right = require("modules.online_right")
local ws    = require("modules.websocket_manager")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1
        print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or ""))
    end
end

----------------------------------------------------------------------
-- The host, reduced to what this one row touches. cx and pw are the numbers
-- M.draw resolves for the right panel on a 1280-wide logical canvas:
--   div_rx = EDGE_R - VISIBLE_W*SIDE_RATIO, pw = (EDGE_R - div_rx) - 2*SIDE_MARGIN
----------------------------------------------------------------------
local DIV_RX, EDGE_R, SIDE_MARGIN = 896, 1280, 20
local CX = (DIV_RX + EDGE_R) / 2
local PW = (EDGE_R - DIV_RX) - SIDE_MARGIN * 2

local function render(opts)
    opts = opts or {}
    local out = { boxes = {}, texts = {} }
    local function track(_, n)
        local bucket = (n.kind == "text" and out.texts) or out.boxes
        bucket[#bucket + 1] = n
        return n
    end
    local self_ = { buttons = {}, ui_clock = 0 }
    local function mkbtn(s, id, pos, size, label, style, data, font)
        local bg = track(s, ui.box(pos, size))
        s.buttons[#s.buttons + 1] = { node = bg, id = id, data = data, size = size, pos = pos }
        if label then track(s, ui.text(vmath.vector3(pos.x, pos.y - 3, pos.z), label, font)) end
        return bg
    end
    local C = {
        COL_BG    = vmath.vector4(0, 0, 0, 1),
        COL_WHITE = vmath.vector4(1, 1, 1, 1),
        COL_DIM   = vmath.vector4(0.6, 0.6, 0.6, 1),
    }
    local ctx = { C = C, ui = ui, track = track, mkbtn = mkbtn }

    ws.current_user_data = { tournaments = {
        { _id = "champ-1", scope = "GLOBAL", status = "active",
          activeTime = opts.window or { start = "00:00", ["end"] = "23:59" } },
    } }
    if opts.no_tournament then ws.current_user_data = { tournaments = {} } end

    -- The cache is keyed on os.time(), and every render in this file happens
    -- inside the same simulated second, so it has to be cleared or the second
    -- case reads the first one's answer.
    self_._tw_at = nil

    local cy_in = opts.cy or 400
    out.cy_in  = cy_in
    out.cy_out = right.draw_tournaments_row(self_, ctx, CX, PW, cy_in)
    out.self    = self_
    out.buttons = self_.buttons
    return out
end

local function button(out, id)
    for _, b in ipairs(out.buttons) do if b.id == id then return b end end
end
local function text_node(out, str)
    for _, n in ipairs(out.texts) do if n.text == str then return n end end
end

----------------------------------------------------------------------
print("THE ROW IS IN FLOW, AND FILLS THE PANEL")
----------------------------------------------------------------------
local out = render()
local row = button(out, "nav_tournaments")
check("the row is a button that navigates to tournaments", row ~= nil)

local row_l = row.pos.x - row.size.x / 2
local row_r = row.pos.x + row.size.x / 2
local row_t = row.pos.y + row.size.y / 2
local row_b = row.pos.y - row.size.y / 2

check("it is the panel's full width", math.abs(row.size.x - PW) < 0.01,
      string.format("w=%.1f pw=%.1f", row.size.x, PW))
check("centred on the panel", math.abs(row.pos.x - CX) < 0.01)

-- THE OPAQUE PLATE UNDER IT MATCHES. container_bg is a translucent glass
-- nine-slice, so the row draws a solid box first; a plate narrower than the
-- button is a strip of the panel showing through under one end of it.
do
    local plate
    for _, n in ipairs(out.boxes) do
        if n ~= row.node and n.size and math.abs(n.size.y - row.size.y) < 0.01 then
            plate = plate or n
        end
    end
    check("an opaque plate sits under the row", plate ~= nil)
    check("...at exactly the row's own size and place",
          plate and math.abs(plate.size.x - row.size.x) < 0.01
                and math.abs(plate.pos.x - row.pos.x) < 0.01
                and math.abs(plate.pos.y - row.pos.y) < 0.01,
          plate and string.format("w=%.1f vs %.1f", plate.size.x, row.size.x))
end

-- IN FLOW: it hangs from the cursor it was handed and reports the cursor
-- below itself, like every other block in this panel. A floating control
-- reports nothing and the blocks after it close over its space.
check("its top edge is the cursor it was handed",
      math.abs(row_t - out.cy_in) < 0.01,
      string.format("top=%.1f cursor=%.1f", row_t, out.cy_in))
check("it returns the cursor below itself",
      math.abs(out.cy_out - row_b) < 0.01,
      string.format("returned=%.1f bottom=%.1f", out.cy_out, row_b))
check("...which is exactly its own height lower",
      math.abs((out.cy_in - out.cy_out) - row.size.y) < 0.01)

-- It moves with the cursor rather than sitting at a screen coordinate.
do
    local lower = render({ cy = 250 })
    local b = button(lower, "nav_tournaments")
    check("handed a lower cursor, the whole row moves down with it",
          math.abs((row.pos.y - b.pos.y) - 150) < 0.01,
          string.format("moved %.1f", row.pos.y - b.pos.y))
end

-- IT IS BIGGER THAN THE 72 IT FIRST SHIPPED AT, which is what the "too small"
-- report was about once it stopped being a dot, and it is not so tall that it
-- outgrows the battle rows (88) it sits under.
check("it is taller than the row it replaced", row.size.y > 72,
      string.format("h=%.1f", row.size.y))
check("...but no taller than a battle row", row.size.y <= 88,
      string.format("h=%.1f", row.size.y))

----------------------------------------------------------------------
print("")
print("THE WORD IS ON THE BUTTON")
----------------------------------------------------------------------
local title = text_node(out, "TOURNAMENTS")
check("the word TOURNAMENTS is drawn", title ~= nil)
if title then
    -- Left-aligned off the icon, so its position is its LEFT edge.
    check("it sits inside the row", title.pos.x > row_l and title.pos.x < row_r,
          string.format("x=%.1f in [%.1f, %.1f]", title.pos.x, row_l, row_r))
    check("...clear of the inset the icon takes", title.pos.x > row_l + 40)
    check("...and vertically centred on the row",
          math.abs(title.pos.y - row.pos.y) < 0.01)
end

----------------------------------------------------------------------
print("")
print("THE BADGE IS INSIDE THE ROW, NOT HANGING OFF IT")
----------------------------------------------------------------------
-- The circle could not do this: at 76px across there was no room beside the
-- glyph, so the badge went to the bottom edge and half of it was outside.
for _, case in ipairs({
    { name = "OPEN",   window = { start = "00:00", ["end"] = "23:59" } },
    { name = "CLOSED", window = { start = "00:00", ["end"] = "00:01" } },
}) do
    local o = render({ window = case.window })
    local b = button(o, "nav_tournaments")
    local l, r = b.pos.x - b.size.x / 2, b.pos.x + b.size.x / 2
    local t, bot = b.pos.y + b.size.y / 2, b.pos.y - b.size.y / 2

    local word = text_node(o, case.name)
    check(case.name .. ": the badge word is drawn", word ~= nil)

    -- Find the badge box by the colour the source gives it rather than by
    -- index, so a node added or removed above it does not silently point this
    -- at something else.
    local badge
    for _, n in ipairs(o.boxes) do
        local c = n.color
        if c and math.abs(c.x - 0.15) < 0.01 and math.abs(c.y - 0.8) < 0.01 then badge = n end
        if c and math.abs(c.x - 0.55) < 0.01 and math.abs(c.y - 0.16) < 0.01 then badge = n end
    end
    check(case.name .. ": the badge box is drawn", badge ~= nil)

    if badge then
        local bl, br = badge.pos.x - badge.size.x / 2, badge.pos.x + badge.size.x / 2
        local bt, bb = badge.pos.y + badge.size.y / 2, badge.pos.y - badge.size.y / 2
        check(case.name .. ": fully inside the row horizontally",
              bl >= l - 0.01 and br <= r + 0.01,
              string.format("[%.1f, %.1f] in [%.1f, %.1f]", bl, br, l, r))
        check(case.name .. ": and fully inside it vertically",
              bb >= bot - 0.01 and bt <= t + 0.01,
              string.format("[%.1f, %.1f] in [%.1f, %.1f]", bb, bt, bot, t))
        check(case.name .. ": right-aligned, not centred", badge.pos.x > b.pos.x)
        check(case.name .. ": it clears the word",
              title == nil or bl > title.pos.x)
    end

    if word and badge then
        check(case.name .. ": the label rides its own box",
              math.abs(word.pos.x - badge.pos.x) < 0.01)
        -- A text node's pivot is the centre of its LINE BOX, and an all-caps
        -- word has no descenders to fill the space reserved below it, so the
        -- label has to drop a fraction of a descent to sit where its ink
        -- centres.
        check(case.name .. ": ...a shade below its true centre, not above",
              word.pos.y < badge.pos.y and (badge.pos.y - word.pos.y) < 4,
              string.format("drop=%.2f", badge.pos.y - word.pos.y))
    end
end

----------------------------------------------------------------------
print("")
print("OPEN BREATHES, CLOSED SITS STILL, NOTHING SAYS NOTHING")
----------------------------------------------------------------------
do
    local o = render({ window = { start = "00:00", ["end"] = "23:59" } })
    check("open hands its badge to the host to pulse", o.self.tourn_badge_node ~= nil)

    local c = render({ window = { start = "00:00", ["end"] = "00:01" } })
    check("closed does not", c.self.tourn_badge_node == nil)

    -- No global championship at all: status_label returns nil, and nil is a
    -- different fact from CLOSED. A badge reading CLOSED says the door is
    -- shut; one drawn over a list nobody has looked at says it about a door
    -- that may not exist.
    local n = render({ no_tournament = true })
    check("no championship draws no badge",
          text_node(n, "CLOSED") == nil and text_node(n, "OPEN") == nil)
    check("...but the row is still there to tap", button(n, "nav_tournaments") ~= nil)
    check("...and still takes its own height from the cursor",
          math.abs((n.cy_in - n.cy_out) - button(n, "nav_tournaments").size.y) < 0.01)
end

----------------------------------------------------------------------
print("")
print("AND THE WHOLE PANEL STILL FITS ON THE SCREEN")
----------------------------------------------------------------------
-- THE REGRESSION THIS ROW CAUSED ONCE. A row in flow costs height; a floating
-- one does not. Dropped back into the panel at 80 tall it ran 22px below the
-- bottom of the screen, and nothing in the isolated render above could see
-- that — the row was correct, the column it was in had no room for it.
--
-- So this renders the REAL M.draw for the right panel on a 16:9 canvas, where
-- EDGE_B is 0 and there is no safe-area slack to hide in, and checks the row
-- lands inside it. Every block above it borrows from the same 704 pixels, so
-- this fails if any of them grows — which is the point.
do
    local function grey(a) return vmath.vector4(0.5, 0.5, 0.5, a or 1) end
    local EDGE_L, EDGE_R2, EDGE_B, EDGE_T = 0, 1280, 0, 720
    local C = {
        SIDE_MARGIN = 20, INNER_PAD = 14, SECTION_GAP = 10, CENTER_PAD = 16,
        HDR_H_TABLE = 30, ROW_H_LG = 36, ROW_H_BONUS = 37, ROW_H_SM = 30,
        ROW_H_LIST = 40, ROW_GAP = 6, BLOCK_GAP = 18,
        COL_BG = vmath.vector4(0, 0, 0, 1), COL_GLASS = grey(0.1), COL_GLASS_HI = grey(0.15),
        COL_BORDER = grey(0.2), COL_BRIGHT = grey(0.9), COL_DIM = grey(0.55),
        COL_MID = grey(0.7), COL_WHITE = vmath.vector4(1, 1, 1, 1),
        COL_RED = vmath.vector4(1, 0.2, 0.2, 1), COL_GREEN = vmath.vector4(0.2, 1, 0.2, 1),
        COL_GOLD = vmath.vector4(1, 0.843, 0, 1), COL_CYAN = vmath.vector4(0, 0.72, 0.83, 1),
        ROW_EVEN = grey(0.04), ROW_ODD = grey(0.06), ROW_YOU = grey(0.12),
        TIER_COLORS = { grey(1), grey(1), grey(1), grey(1), grey(1) }, TIER_DIM = grey(1),
        COL_STAT_BG = grey(0.08), COL_NAMEID_BG = grey(0.09), COL_HEADER_BG = grey(0.1),
        COL_BADGE_BG = grey(0.1), COL_TIMER_BG = grey(0.1),
        COL_GOLD_BDR = grey(0.5), COL_GOLD_BDR_D = grey(0.4),
    }
    local self_ = { buttons = {} }
    local function track(_, n) return n end
    local function txt(s, x, y, str, f, c) return ui.text(vmath.vector3(x, y, 0), str, f, c) end
    local function mkbtn(s, id, pos, size, label, style, data, font)
        local bg = ui.box(pos, size)
        s.buttons[#s.buttons + 1] = { node = bg, id = id, pos = pos, size = size }
        return bg
    end
    local function glass(s, pos, size) return ui.box(pos, size) end
    local function get_layout()
        local V = EDGE_R2 - EDGE_L
        return V * 0.30, V * 0.30, EDGE_L + V * 0.30, EDGE_R2 - V * 0.30
    end

    ws.current_user_data = {
        username = "ADA", balance = 1200, points = 340, savingCoins = 50, avatar = 3,
        recentForm = { "W", "L", "W", "W", "L" },
        myBattles = {
            NORMAL   = { _id = "b1", matchFormat = 3, stake = { amount = 200 } },
            KNOCKOUT = { _id = "b2", scoreCap = 200, stake = { amount = 500 } },
            PARTY    = { _id = "b3", partyMode = "SCORECAP", scoreCap = 200, stake = { amount = 200 } },
        },
        tournaments = { { _id = "c1", scope = "GLOBAL", status = "active",
                          activeTime = { start = "00:00", ["end"] = "23:59" } } },
    }
    self_._tw_at = nil

    local ok, err = pcall(right.draw, self_, {
        C = C, ui = ui, track = track, txtL = txt, txtR = txt, mkbtn = mkbtn,
        glass = glass, commas = function(n) return tostring(n) end,
        get_layout = get_layout, EDGE_L = EDGE_L, EDGE_R = EDGE_R2,
        EDGE_B = EDGE_B, EDGE_T = EDGE_T, CX = 640, CY = 360,
        LOGICAL_W = 1280, LOGICAL_H = 720,
    })
    check("the whole right panel draws", ok, tostring(err))

    local tr
    for _, b in ipairs(self_.buttons) do if b.id == "nav_tournaments" then tr = b end end
    check("the tournaments row is in it", tr ~= nil)
    if tr then
        local top, bot = tr.pos.y + tr.size.y / 2, tr.pos.y - tr.size.y / 2
        check("its bottom clears the safe bottom border", bot >= EDGE_B,
              string.format("bottom=%.0f EDGE_B=%d", bot, EDGE_B))
        check("...and its top is still under the safe top border", top <= EDGE_T,
              string.format("top=%.0f EDGE_T=%d", top, EDGE_T))
        -- Every block above it draws first, so nothing else may spill either.
        local lowest = 1e9
        for _, b in ipairs(self_.buttons) do
            lowest = math.min(lowest, b.pos.y - b.size.y / 2)
        end
        check("nothing in the panel hangs off the bottom", lowest >= EDGE_B,
              string.format("lowest=%.0f", lowest))
    end
end

----------------------------------------------------------------------
print("")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
