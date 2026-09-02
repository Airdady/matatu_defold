-- YOUR POSITION SITS ON THE STANDINGS TITLE ROW.
--
--   Run: lua tools/test_standings_position.lua
--
-- It used to live in the right panel's profile card, in a two-row stats box
-- under the balances — a panel's width away from the standings it is a
-- position IN, and the table it belongs to shows only the top five, so a
-- player outside that five had their own rank on the opposite side of the
-- screen from the only thing that gives it meaning.
--
-- The move it copies is the season countdown on the SEASON BONUSES title row
-- directly below: the one number a table does not contain goes on that
-- table's own title row, right-aligned. This RENDERS the left panel against
-- the gui stub in defold_sim and checks the two ended up on the same
-- convention, rather than checking that the source says so.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local SIM = dofile(here .. "/defold_sim.lua")
SIM.install_gui_stub()
_G.window = _G.window or {}
_G.window.set_listener = function() end
_G.http = { request = function() end }

local ui   = require("modules.ui")
local left = require("modules.online_left")
local ws   = require("modules.websocket_manager")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1
        print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or ""))
    end
end

----------------------------------------------------------------------
-- The host, reduced to what the left panel touches. The spacing numbers are
-- main/online.gui_script's own, so if the lobby's layout changes this harness
-- is wrong in the same direction the screen is.
----------------------------------------------------------------------
local EDGE_L, EDGE_R, EDGE_B, EDGE_T = 0, 1280, 0, 720
local SIDE_RATIO, SIDE_MARGIN = 0.30, 20
local VISIBLE_W = EDGE_R - EDGE_L

local function grey(a) return vmath.vector4(0.5, 0.5, 0.5, a or 1) end
local C = {
    SIDE_MARGIN = SIDE_MARGIN, INNER_PAD = 14, SECTION_GAP = 10,
    HDR_H_TABLE = 30, ROW_H_LG = 36, ROW_H_BONUS = 37, BLOCK_GAP = 18,
    COL_BG = vmath.vector4(0, 0, 0, 1), COL_GLASS = grey(0.1),
    COL_BORDER = grey(0.2), COL_BRIGHT = vmath.vector4(0.9, 0.93, 0.96, 1),
    COL_DIM = vmath.vector4(0.55, 0.60, 0.65, 1), COL_MID = grey(0.7),
    COL_WHITE = vmath.vector4(1, 1, 1, 1), COL_RED = vmath.vector4(1, 0.2, 0.2, 1),
    COL_GOLD = vmath.vector4(1.0, 0.843, 0.0, 1),
    ROW_EVEN = grey(0.04), ROW_ODD = grey(0.06), ROW_YOU = grey(0.12),
    TIER_COLORS = { grey(1), grey(1), grey(1), grey(1), grey(1) }, TIER_DIM = grey(1),
}

local function commas(n) return tostring(n) end

local function render(user)
    local out = { texts = {}, boxes = {} }
    local function track(_, n)
        local bucket = (n.kind == "text" and out.texts) or out.boxes
        bucket[#bucket + 1] = n
        return n
    end
    local self_ = { buttons = {} }
    local function txtL(s, x, y, str, font, color)
        local t = track(s, ui.text(vmath.vector3(x, y, 0), str, font, color))
        t.align = "L"; return t
    end
    local function txtR(s, x, y, str, font, color)
        local t = track(s, ui.text(vmath.vector3(x, y, 0), str, font, color))
        t.align = "R"; return t
    end
    local function mkbtn(s, id, pos, size, label, style, data, font)
        local bg = track(s, ui.box(pos, size))
        s.buttons[#s.buttons + 1] = { node = bg, id = id, pos = pos, size = size }
        if label then track(s, ui.text(vmath.vector3(pos.x, pos.y, pos.z), label, font)) end
        return bg
    end
    local function glass(s, pos, size) return track(s, ui.box(pos, size)) end
    local function get_layout()
        return VISIBLE_W * SIDE_RATIO, VISIBLE_W * SIDE_RATIO,
               EDGE_L + VISIBLE_W * SIDE_RATIO, EDGE_R - VISIBLE_W * SIDE_RATIO
    end

    ws.current_user_data = user
    ws.current_season_status = nil

    left.draw(self_, {
        C = C, ui = ui, track = track, txtL = txtL, txtR = txtR,
        mkbtn = mkbtn, glass = glass, commas = commas, get_layout = get_layout,
        EDGE_L = EDGE_L, EDGE_R = EDGE_R, EDGE_B = EDGE_B, EDGE_T = EDGE_T,
    })
    out.self = self_
    return out
end

local function find(out, str)
    for _, n in ipairs(out.texts) do if n.text == str then return n end end
end
local function starts_with(out, prefix)
    for _, n in ipairs(out.texts) do
        if type(n.text) == "string" and n.text:sub(1, #prefix) == prefix then return n end
    end
end

local RANKED = { position = 4, rank = {
    { position = 1, username = "ADA",  points = 900 },
    { position = 2, username = "BEN",  points = 800 },
} }

----------------------------------------------------------------------
print("IT IS ON THE STANDINGS TITLE ROW, NOT IN THE RIGHT PANEL")
----------------------------------------------------------------------
local out = render(RANKED)
local title = find(out, "STANDINGS")
check("the STANDINGS title is drawn", title ~= nil)

local pos = starts_with(out, "YOU")
check("the player's own position is drawn", pos ~= nil, pos and pos.text)
if title and pos then
    check("it names the rank the server gave", pos.text:find("4", 1, true) ~= nil, pos.text)
    check("it is on the SAME row as the title",
          math.abs(pos.pos.y - title.pos.y) < 0.01,
          string.format("pos.y=%.1f title.y=%.1f", pos.pos.y, title.pos.y))
    check("the title stays hard left, the position goes hard right",
          title.align == "L" and pos.align == "R" and pos.pos.x > title.pos.x,
          string.format("title.x=%.1f pos.x=%.1f", title.pos.x, pos.pos.x))
end

-- THE CONVENTION IT COPIES. The season countdown sits on the SEASON BONUSES
-- title row exactly this way, and the two have to agree or the panel has two
-- spellings of one idea.
do
    local b_title = find(out, "SEASON BONUSES")
    local clock_n = out.self.bonus_clock_node
    check("the SEASON BONUSES title is drawn", b_title ~= nil)
    check("its countdown is on that title's row", b_title and clock_n
          and math.abs(clock_n.pos.y - b_title.pos.y) < 0.01)
    if b_title and clock_n and title and pos then
        check("both title rows inset their left edge identically",
              math.abs(title.pos.x - b_title.pos.x) < 0.01,
              string.format("%.1f vs %.1f", title.pos.x, b_title.pos.x))
        check("...and both right-hand values sit on the same right inset",
              math.abs(pos.pos.x - clock_n.pos.x) < 0.01,
              string.format("%.1f vs %.1f", pos.pos.x, clock_n.pos.x))
    end
end

----------------------------------------------------------------------
print("")
print("UNRANKED IS A FACT, NOT A BLANK OR A #-1")
----------------------------------------------------------------------
do
    local none = render({ rank = {} })
    local n = find(none, "UNRANKED")
    check("no position yet says so in words", n ~= nil)
    check("...and never prints a negative rank", starts_with(none, "YOU  #-") == nil)
    local t = find(none, "STANDINGS")
    check("...on the title row all the same", n and t and math.abs(n.pos.y - t.pos.y) < 0.01)

    -- Gold when ranked, dim when not: the colour carries the same fact as the
    -- word, which is what the right panel's version did.
    local ranked_n = starts_with(out, "YOU")
    check("ranked is gold", ranked_n and ranked_n.color
          and math.abs(ranked_n.color.x - C.COL_GOLD.x) < 0.01
          and math.abs(ranked_n.color.y - C.COL_GOLD.y) < 0.01)
    check("unranked is dim, not gold", n and n.color
          and math.abs(n.color.x - C.COL_DIM.x) < 0.01)
end

----------------------------------------------------------------------
print("")
print("AND THE PROFILE CARD'S STATS BOX IS GONE ENTIRELY")
----------------------------------------------------------------------
-- Source-read rather than rendered: what is being checked is that these rows
-- no longer EXIST over there. Two panels showing the same number in two places
-- is exactly the thing the position's move was for, and the form row followed
-- it out because nothing on this screen is about the last five games.
do
    local f = assert(io.open(here .. "/../modules/online_right.lua"))
    local RIGHT = f:read("*a"); f:close()
    local CODE = RIGHT:gsub("%-%-[^\n]*", "")
    check("the right panel no longer draws a YOUR POSITION row",
          CODE:find('"YOUR POSITION"', 1, true) == nil)
    check("...nor a YOUR CURRENT FORM row",
          CODE:find('"YOUR CURRENT FORM"', 1, true) == nil)
    check("...and the box that held them is gone with them",
          CODE:find("local list_h", 1, true) == nil
          and CODE:find("C.COL_STAT_BG", 1, true) == nil)

    -- UNMOUNTED, NOT DELETED. The server still sends the form and
    -- websocket_manager still tracks it, so putting the row back is a row of
    -- drawing code rather than an excavation — the same standing every other
    -- entry point taken off this screen has.
    local g = assert(io.open(here .. "/../modules/websocket_manager.lua"))
    local WS = g:read("*a"); g:close()
    check("the form data behind it is still tracked",
          WS:find("current_user_data.recentForm", 1, true) ~= nil)
end

----------------------------------------------------------------------
print("")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
