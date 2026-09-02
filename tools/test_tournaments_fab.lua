-- WHERE THE TOURNAMENTS BAR ACTUALLY LANDS.
--
--   Run: lua tools/test_tournaments_fab.lua
--
-- tools/test_lobby_entries.lua checks what the source SAYS about this control.
-- This one RENDERS it — the real draw_tournaments_fab, against the gui stub in
-- defold_sim, with the same layout numbers main/online.gui_script resolves —
-- and measures the nodes that come out. That is the only way to catch the
-- class of bug this control has actually had twice: a piece drawn somewhere
-- other than where its arithmetic reads as drawing it.
--
-- It floated as a 76px circle carrying one glyph, which is what this replaces:
-- the word TOURNAMENTS was off the control entirely, and the OPEN/CLOSED badge
-- had nowhere to sit but half off the circle's bottom edge. So the three
-- things pinned here are the three that were wrong: the bar reaches the
-- centre/right divider, the word is on it, and the badge is inside it.
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
-- The host, reduced to what this one control touches.
--
-- Every number here is copied from main/online.gui_script rather than chosen:
-- SIDE_RATIO and SIDE_MARGIN are its constants, get_layout is its function
-- verbatim, and mkbtn records a button the way the real one does. If the
-- lobby's own layout changes, this harness is wrong in the same direction the
-- screen is, which is the point.
----------------------------------------------------------------------
local SIDE_RATIO, SIDE_MARGIN = 0.30, 20

local function render(opts)
    opts = opts or {}
    local EDGE_L = opts.EDGE_L or 0
    local EDGE_R = opts.EDGE_R or 1280
    local EDGE_B = opts.EDGE_B or 0
    local EDGE_T = opts.EDGE_T or 720
    local LOGICAL_W, LOGICAL_H = 1280, 720
    local CX, CY = LOGICAL_W / 2, LOGICAL_H / 2
    local VISIBLE_W = EDGE_R - EDGE_L

    local function get_layout()
        return VISIBLE_W * SIDE_RATIO, VISIBLE_W * SIDE_RATIO,
               EDGE_L + VISIBLE_W * SIDE_RATIO, EDGE_R - VISIBLE_W * SIDE_RATIO
    end

    local out = { boxes = {}, texts = {}, images = {}, buttons = {} }
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
        SIDE_MARGIN = SIDE_MARGIN,
        COL_BG    = vmath.vector4(0, 0, 0, 1),
        COL_WHITE = vmath.vector4(1, 1, 1, 1),
        COL_DIM   = vmath.vector4(0.6, 0.6, 0.6, 1),
    }
    local ctx = {
        C = C, ui = ui, track = track, mkbtn = mkbtn, get_layout = get_layout,
        EDGE_L = EDGE_L, EDGE_R = EDGE_R, EDGE_B = EDGE_B, EDGE_T = EDGE_T,
        CX = CX, CY = CY, LOGICAL_W = LOGICAL_W, LOGICAL_H = LOGICAL_H,
    }

    -- A GLOBAL championship, active, in a window that either contains the
    -- current minute or does not — which is the only thing status_label reads.
    ws.current_user_data = { tournaments = {
        { _id = "champ-1", scope = "GLOBAL", status = "active",
          activeTime = opts.window or { start = "00:00", ["end"] = "23:59" } },
    } }
    if opts.no_tournament then ws.current_user_data = { tournaments = {} } end

    -- The cache is keyed on os.time(), and every render in this file happens
    -- inside the same simulated second, so it has to be cleared or the second
    -- case reads the first one's answer.
    self_._tw_at = nil

    for k, v in pairs(opts.state or {}) do self_[k] = v end
    right.draw_tournaments_fab(self_, ctx)

    out.self    = self_
    out.buttons = self_.buttons
    out.div_rx  = select(4, get_layout())
    out.EDGE_R, out.EDGE_B = EDGE_R, EDGE_B
    return out
end

local function button(out, id)
    for _, b in ipairs(out.buttons) do if b.id == id then return b end end
end
local function text_node(out, str)
    for _, n in ipairs(out.texts) do if n.text == str then return n end end
end

----------------------------------------------------------------------
print("THE BAR REACHES THE CENTRE / RIGHT BORDER")
----------------------------------------------------------------------
local open = render()
local bar = button(open, "nav_tournaments")
check("the bar is a button that navigates to tournaments", bar ~= nil)

local bar_l = bar.pos.x - bar.size.x / 2
local bar_r = bar.pos.x + bar.size.x / 2
check("its left edge is the centre/right divider",
      math.abs(bar_l - open.div_rx) < 0.01,
      string.format("left=%.1f divider=%.1f", bar_l, open.div_rx))
check("its right edge takes the panel's own inset",
      math.abs(bar_r - (open.EDGE_R - SIDE_MARGIN)) < 0.01,
      string.format("right=%.1f want=%.1f", bar_r, open.EDGE_R - SIDE_MARGIN))
check("it never draws past the safe right border", bar_r <= open.EDGE_R + 0.01)

-- THE CIRCLE IT REPLACED. 76px, centred midway between the screen centre and
-- the right edge, so its left edge sat at 922 on this canvas — 26px INSIDE the
-- divider, and a fifth of the bar's width.
do
    local FAB = 76
    local old_l = 640 + (open.EDGE_R - 640) / 2 - FAB / 2
    check("it reaches further left than the circle did",
          bar_l < old_l, string.format("bar=%.1f circle=%.1f", bar_l, old_l))
    check("and it is far wider than the circle was",
          bar.size.x > FAB * 3, string.format("w=%.1f", bar.size.x))
    check("and taller, so the word and the badge both fit",
          bar.size.y > 76 or bar.size.y >= 80, string.format("h=%.1f", bar.size.y))
end

-- SAFE AREA. On a device whose usable bottom border is not zero, the bar has
-- to move UP with it — a floating control positioned off the raw canvas is
-- exactly the thing that ends up half under a home indicator.
do
    local inset = render({ EDGE_B = 60 })
    local b0 = button(open,  "nav_tournaments")
    local b1 = button(inset, "nav_tournaments")
    check("a bottom inset lifts the bar by exactly that much",
          math.abs((b1.pos.y - b0.pos.y) - 60) < 0.01,
          string.format("moved %.1f", b1.pos.y - b0.pos.y))
    check("...and it still clears the safe border",
          (b1.pos.y - b1.size.y / 2) > 60)
end

-- A NARROWER COLUMN must not squeeze the word out: the floor takes over and
-- the bar overhangs the divider rather than clipping its own content.
do
    local narrow = render({ EDGE_R = 900 })
    local b = button(narrow, "nav_tournaments")
    check("a narrow layout keeps the bar wide enough to read",
          b.size.x >= 300 - 0.01, string.format("w=%.1f", b.size.x))
end

----------------------------------------------------------------------
print("")
print("THE WORD IS ON THE BUTTON")
----------------------------------------------------------------------
local title = text_node(open, "TOURNAMENTS")
check("the word TOURNAMENTS is drawn", title ~= nil)
if title then
    -- Left-aligned off the icon, so its position is its LEFT edge.
    check("it sits inside the bar", title.pos.x > bar_l and title.pos.x < bar_r,
          string.format("x=%.1f in [%.1f, %.1f]", title.pos.x, bar_l, bar_r))
    check("...clear of the left inset the icon takes", title.pos.x > bar_l + 40)
    check("...and vertically on the bar", math.abs(title.pos.y - bar.pos.y) < bar.size.y / 2)
end

----------------------------------------------------------------------
print("")
print("THE BADGE IS INSIDE THE BAR, NOT HANGING OFF IT")
----------------------------------------------------------------------
-- This is the one the circle could not do: at 76px across there was no room
-- beside the glyph, so the badge went to the bottom edge and half of it was
-- outside the button.
for _, case in ipairs({
    { name = "OPEN",   window = { start = "00:00", ["end"] = "23:59" } },
    { name = "CLOSED", window = { start = "00:00", ["end"] = "00:01" } },
}) do
    local out = render({ window = case.window })
    local b   = button(out, "nav_tournaments")
    local l, r = b.pos.x - b.size.x / 2, b.pos.x + b.size.x / 2
    local top, bot = b.pos.y + b.size.y / 2, b.pos.y - b.size.y / 2

    local word = text_node(out, case.name)
    check(case.name .. ": the badge word is drawn", word ~= nil)

    -- The badge box is the one node sized to that word. Find it by the colour
    -- the source gives it rather than by index, so a node added or removed
    -- above it does not silently point this at something else.
    local badge
    for _, n in ipairs(out.boxes) do
        local c = n.color
        if c and math.abs(c.y - 0.8) < 0.01 and math.abs(c.x - 0.15) < 0.01 then badge = n end
        if c and math.abs(c.x - 0.55) < 0.01 and math.abs(c.y - 0.16) < 0.01 then badge = n end
    end
    check(case.name .. ": the badge box is drawn", badge ~= nil)

    if badge then
        local bl, br = badge.pos.x - badge.size.x / 2, badge.pos.x + badge.size.x / 2
        local bt, bb = badge.pos.y + badge.size.y / 2, badge.pos.y - badge.size.y / 2
        check(case.name .. ": it is fully inside the bar horizontally",
              bl >= l - 0.01 and br <= r + 0.01,
              string.format("[%.1f, %.1f] in [%.1f, %.1f]", bl, br, l, r))
        check(case.name .. ": and fully inside it vertically",
              bb >= bot - 0.01 and bt <= top + 0.01,
              string.format("[%.1f, %.1f] in [%.1f, %.1f]", bb, bt, bot, top))
        check(case.name .. ": it is right-aligned, not centred",
              badge.pos.x > b.pos.x, string.format("x=%.1f centre=%.1f", badge.pos.x, b.pos.x))
        check(case.name .. ": it clears the word",
              title == nil or bl > title.pos.x)
    end

    if word and badge then
        -- The label rides its box, dropped by the fraction of a descent its
        -- ink centre sits below the line box centre.
        check(case.name .. ": the label is on its own box",
              math.abs(word.pos.x - badge.pos.x) < 0.01)
        check(case.name .. ": ...and a shade below its true centre, not above",
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
    check("no championship draws no badge", text_node(n, "CLOSED") == nil and text_node(n, "OPEN") == nil)
    check("...but the bar is still there to tap", button(n, "nav_tournaments") ~= nil)
end

----------------------------------------------------------------------
print("")
print("A MODAL TAKES THE BAR OFF THE SCREEN")
----------------------------------------------------------------------
-- It draws over every panel, so with a dimmed backdrop up it would be a
-- tappable control sitting on top of one — which is how a player ends up on
-- the tournament screen with a half-filled form still open behind them.
for _, flag in ipairs({ "party_open", "battle_modal", "invite_search",
                        "savings_info_open", "savings_plans_open", "savings_add_open" }) do
    local out = render({ state = { [flag] = true } })
    check(flag .. " hides the bar", button(out, "nav_tournaments") == nil)
    check(flag .. " ...and drops the pulsing node", out.self.tourn_badge_node == nil)
end

----------------------------------------------------------------------
print("")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
