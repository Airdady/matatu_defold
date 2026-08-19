-- THE SAVINGS PROMO HAS TO HAVE WORDS IN IT.
--
-- Reported: the card opens with a coin bundle, two buttons and nothing else.
--
-- The copy types itself out character by character, and the budget for how
-- much to show was read from self._savings_type_t — an accumulator that
-- online.gui_script's update() was supposed to advance and never did. Nothing
-- anywhere assigned it. So the budget was floor(nil / 0.015) = 0 on every
-- frame, typed() returned the empty string for every line, and the promo that
-- introduces a whole feature to a first-time player opened blank.
--
-- The fix measures elapsed time from the clock instead, so the words cannot be
-- hidden by a timer nobody is ticking. This test is written against that
-- property rather than against the animation: at t=0 there may legitimately be
-- almost nothing on screen, but a moment later there must be real text, and a
-- few seconds later there must be all of it.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local SIM = require("defold_sim")
SIM.install_gui_stub()

local pass, fail = 0, 0
local function ok(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

local right = require("modules.online_right")

-- The clock the module reads. Driven by hand so the test is not at the mercy
-- of how long it itself takes to run.
local fake_now = 1000.0
socket = socket or {}
socket.gettime = function() return fake_now end

local ui = require("modules.ui")

-- Every string the panel drew, in order. ui.text is the only thing that puts
-- words on screen, so wrapping it is enough to see the whole card.
local drawn = {}
local real_text = ui.text
ui.text = function(pos, str, font, col)
  drawn[#drawn + 1] = tostring(str or "")
  return real_text(pos, str, font, col)
end
local real_textL = ui.textL
if real_textL then
  ui.textL = function(...) local a = select(2, ...); drawn[#drawn + 1] = tostring(a or ""); return real_textL(...) end
end

local function v4(r, g, b, a) return vmath.vector4(r, g, b, a or 1) end

-- The panel reads two kinds of constant off C: colours and sizes. A single
-- fallback cannot serve both (a vector4 will not do arithmetic), so colours are
-- recognised by name and everything else answers as a number.
local C = setmetatable({ SIDE_MARGIN = 20, INNER_PAD = 14 }, {
  __index = function(_, k)
    k = tostring(k)
    if k:match("^COL_") or k:match("^ROW_EVEN") or k:match("^ROW_ODD")
       or k:match("^ROW_YOU") or k:match("^TIER_") then
      return v4(1, 1, 1, 1)
    end
    return 20
  end,
})

local function draw_promo(self)
  drawn = {}
  local ctx = {
    C = C, ui = ui,
    track = function(_, n) return n end,
    txtL = function(_, x, y, str) drawn[#drawn + 1] = tostring(str or "") end,
    txtR = function(_, x, y, str) drawn[#drawn + 1] = tostring(str or "") end,
    mkbtn = function() end,
    commas = function(n) return tostring(n) end,
    glass = function() end,
    CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
    INNER_PAD = 14,
    -- The panel lays itself out between the divider and the right edge.
    EDGE_B = 0, EDGE_T = 700, EDGE_R = 1280, EDGE_L = 0,
    get_layout = function() return 0, 400, 0, 880 end,
    with_a = function(c, a) return vmath.vector4(c.x, c.y, c.z, c.w * (a or 1)) end,
  }
  -- draw_savings_info is local to the module; M.draw is the door to it. The
  -- rest of the panel is allowed to fall over — this test is about the card.
  local okd, err = pcall(right.draw, self, ctx, nil)
  if not okd and os.getenv('DEBUG_DRAW') then print('DRAW ERROR: ' .. tostring(err)) end
  return table.concat(drawn, "\n")
end

local function shows(text, needle) return text:find(needle, 1, true) ~= nil end

-- ── the bug, stated as a test ───────────────────────────────────────────────
local self_ = { buttons = {}, nodes = {}, savings_info_open = true }

fake_now = 1000.0
local at_open = draw_promo(self_)      -- first frame: starts the clock
fake_now = 1000.5                      -- half a second later
local half_sec = draw_promo(self_)

ok("the card has real copy on it shortly after opening",
   shows(half_sec, "SAVINGS"),
   "the promo drew no text at all — this is the reported bug")

ok("and the body copy, not just the heading",
   shows(half_sec, "Savings are long"),
   "heading only")

-- ── and ALL of it, without waiting on anyone's accumulator ──────────────────
fake_now = 1010.0
local later = draw_promo(self_)

for _, line in ipairs({
  "SAVINGS",
  "Savings are long-term coins earned from",
  "build up over time.",
  "WHY IT'S WORTH IT",
  "Never resets or expires, it only grows",
  "Rewards you just for playing through the Season",
  "SAVINGS PERIOD PROGRESS",
}) do
  ok("fully typed out: " .. line:sub(1, 32), shows(later, line))
end

check("typing is marked finished once it has run its course",
      self_._savings_type_done, true)

-- ── the backstop ────────────────────────────────────────────────────────────
-- Even if something goes wrong with the redraws, the words appear. Typing is
-- a flourish; the copy is the point.
local stuck = { buttons = {}, nodes = {}, savings_info_open = true }
fake_now = 2000.0
draw_promo(stuck)          -- opens, starts its clock
fake_now = 2000.0 + 3.5    -- past the give-up
local backstop = draw_promo(stuck)
ok("a card open past the give-up shows everything",
   shows(backstop, "Rewards you just for playing through the Season"))
ok("...and stops trying to type", stuck._savings_type_done == true)

-- ── re-opening types it again ───────────────────────────────────────────────
-- The open paths clear the state, so a player who taps the info button gets
-- the animation rather than an instantly-complete card.
self_._savings_type_t0, self_._savings_type_done = nil, nil
fake_now = 3000.0
draw_promo(self_)
ok("re-opening restarts the clock", self_._savings_type_t0 == 3000.0)
ok("...and un-finishes the typing", not self_._savings_type_done)

-- ── closed means closed ─────────────────────────────────────────────────────
local shut = { buttons = {}, nodes = {}, savings_info_open = false }
local nothing = draw_promo(shut)
ok("a closed card draws no promo copy", not shows(nothing, "WHY IT'S WORTH IT"))

-- ── the wiring that feeds it ────────────────────────────────────────────────
local function source(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close(); return s
end
local function strip(s)
  return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

local gui_src = strip(source("main/online.gui_script"))
local mod_src = strip(source("modules/online_right.lua"))

ok("update() asks for redraws while the card is typing",
   gui_src:find("savings_info_open and not self%._savings_type_done") ~= nil,
   "nothing drives the animation")

ok("the dead accumulator is gone for good",
   mod_src:find("_savings_type_t[^0]") == nil,
   "_savings_type_t is being read again, and nothing assigns it")

ok("both doors into the card reset the animation",
   select(2, gui_src:gsub("_savings_type_t0, self%._savings_type_done = nil, nil", "")) >= 2)

print()
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
