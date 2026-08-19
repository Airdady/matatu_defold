-- WHAT BADGE A WIN RATE EARNS, AND THAT EVERY SURFACE ASKS THE SAME QUESTION.
--
-- Two halves, for two different ways this can go wrong.
--
-- The first is the bands themselves. They are written with inclusive maxima —
-- 0-44.9, 45-49.9, 50-54.9, 55-100 — which leaves a tenth of a point between
-- every pair of them. A lookup that tested `wr >= min and wr <= max` would
-- answer nil for a win rate of 44.95, and a real player would wear no badge for
-- a reason nobody could see. So both ends of every band are checked, and so are
-- the gaps between them.
--
-- The second is drift. Five surfaces show a player's standing: the incoming and
-- outgoing request dialogs, the online screen's inline invite strip, the global
-- overlay's strip, and the game-over panel. They used to each render it their
-- own way — three of them printed "WR nn%" with their own colour thresholds and
-- two showed nothing at all — which is exactly how the same opponent could look
-- like two different players on two screens. Those checks are source-level,
-- because the drawing lives inside gui_scripts whose nodes only exist in a
-- running Defold context.
--
-- Runs under plain Lua: modules/rank_badge.lua requires nothing and touches no
-- vmath at load time, deliberately, for this test.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local rank = require("modules.rank_badge")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end
local function ok(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end

-- ── the bands, at both ends ─────────────────────────────────────────────────
check("floor of amateur",       rank.label(0.0),   "AMATEUR")
check("ceiling of amateur",     rank.label(44.9),  "AMATEUR")
check("floor of pro",           rank.label(45.0),  "PRO")
check("ceiling of pro",         rank.label(49.9),  "PRO")
check("floor of master",        rank.label(50.0),  "MASTER")
check("ceiling of master",      rank.label(54.9),  "MASTER")
check("floor of grandmaster",   rank.label(55.0),  "GRANDMASTER")
check("ceiling of grandmaster", rank.label(100.0), "GRANDMASTER")

-- THE GAPS. A tenth of a point between every written band.
check("44.95 is still an amateur", rank.label(44.95), "AMATEUR")
check("49.95 is still a pro",      rank.label(49.95), "PRO")
check("54.95 is still a master",   rank.label(54.95), "MASTER")

-- Off the ends. A rate outside 0-100 is a server bug, not a reason to crash or
-- to answer nil on a screen that is about to draw the answer.
check("above 100 is a grandmaster", rank.label(140),  "GRANDMASTER")
check("below zero is an amateur",   rank.label(-12), "AMATEUR")

-- ZERO IS A WIN RATE; NIL IS NOT.
--
-- A player with games played and no wins is an AMATEUR. A player the server
-- rated nothing for has not been shown to be bad at this, and badging them as
-- the bottom tier would invent a fact about a stranger — and would do it for
-- every player at once on any build whose server does not send ratings.
check("zero is the bottom tier", rank.label(0), "AMATEUR")
check("nil is no badge at all",  rank.label(nil), nil)
check("a non-number is no badge", rank.label({}), nil)
check("a numeric string still reads", rank.label("62"), "GRANDMASTER")
check("nil tier is nil", rank.tier(nil), nil)

-- Keys travel with the labels: the colour table is keyed by them.
check("key for amateur",     (rank.tier(10)  or {}).key, "amateur")
check("key for pro",         (rank.tier(47)  or {}).key, "pro")
check("key for master",      (rank.tier(52)  or {}).key, "master")
check("key for grandmaster", (rank.tier(88)  or {}).key, "grandmaster")

-- Every band has a colour pair, and no pill is drawn in the same colour as the
-- text written on it.
for _, t in ipairs(rank.TIERS) do
  local c = rank.COLORS[t.key]
  ok("colours for " .. t.key, type(c) == "table" and #c.bg == 4 and #c.tx == 4)
  ok("colours for " .. t.key .. " are not identical",
     not (c.bg[1] == c.tx[1] and c.bg[2] == c.tx[2] and c.bg[3] == c.tx[3]))
end

-- The four bands are contiguous and ordered, so no rate can fall between them.
for i = 2, #rank.TIERS do
  ok(("band %d starts where band %d ends"):format(i, i - 1),
     rank.TIERS[i].min > rank.TIERS[i - 1].max
       -- 45.0 - 44.9 is 0.10000000000000142 in a double, so the tolerance has
       -- to be a shade over a tenth or this asserts a floating-point artefact.
       and rank.TIERS[i].min - rank.TIERS[i - 1].max <= 0.1001,
     ("%s..%s then %s"):format(rank.TIERS[i-1].min, rank.TIERS[i-1].max, rank.TIERS[i].min))
end

-- A returned tier must be a copy: a caller that keeps one and edits it must not
-- redefine the band for every other screen.
local t = rank.tier(80)
t.label = "MUTATED"
check("tiers are handed out as copies", rank.label(80), "GRANDMASTER")

-- ── widths ──────────────────────────────────────────────────────────────────
-- Nothing in the Defold GUI measures text at build time, so a pill is sized
-- from its character count. The longest label must fit the rule, and the
-- shortest must not collapse to nothing.
-- EVERY pill carries padding on both sides. Without it the word ran to both
-- edges of its own rectangle, which is what "the badges have no horizontal
-- padding" was.
check("GRANDMASTER is the widest label",
      rank.width("GRANDMASTER"), 11 * rank.CHAR_W + 2 * rank.PAD_X)
check("PRO takes the floor",            rank.width("PRO"),       rank.MIN_W)
ok("the floor is wide enough for PRO",  rank.MIN_W >= 3 * rank.CHAR_W + 2 * rank.PAD_X)
check("no rate, no width",              rank.badge_width(nil),   0)
check("a rate gives its label's width", rank.badge_width(47),    rank.width("PRO"))
ok("there is padding at all",           rank.PAD_X > 0)
for _, t in ipairs(rank.TIERS) do
  ok("padding survives the floor for " .. t.label,
     rank.width(t.label) >= #t.label * rank.CHAR_W + 2 * rank.PAD_X)
end

-- ── every surface asks the one module ───────────────────────────────────────
local function source(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close()
  return s
end
-- Comments name the very things these checks look for — "WR 48%" appears in
-- three of the explanations of why it is gone — so they are stripped first. A
-- test a comment can fail is a test nobody trusts.
local function strip(s)
  return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

local SURFACES = {
  "modules/dialog_incoming.lua",
  "modules/dialog_outgoing.lua",
  "modules/champ_banner.lua",
  "main/online.gui_script",
  "main/incoming.gui_script",
  "main/gameover.gui_script",
}

for _, path in ipairs(SURFACES) do
  local code = strip(source(path))
  local tag = path:match("([^/]+)$")
  ok(tag .. ": requires the shared module",
     code:find('require%("modules%.rank_badge"%)') ~= nil)

  -- THE THING THIS REPLACED. No surface may print a raw percentage next to a
  -- player again — that is the whole point of the tier.
  ok(tag .. ": no hand-rolled WR percentage left",
     code:find('"WR ') == nil and code:find("WR \"") == nil,
     "a raw win-rate readout is back")
end

-- The two invite strips draw the same strip, so their rank-pill geometry has to
-- agree — the same reason test_banner_layout checks the badge constants.
local function const(path, name)
  return tonumber(strip(source(path)):match("local " .. name .. "%s*=%s*(%-?%d+)"))
end
check("both strips use the same pill height",
      const("main/online.gui_script", "BAN_RANK_H"),
      const("main/incoming.gui_script", "BAN_RANK_H"))
check("both strips use the same gap to the name",
      const("main/online.gui_script", "BAN_RANK_GAP"),
      const("main/incoming.gui_script", "BAN_RANK_GAP"))
-- ...and the championship strip, which is a third drawing of the same invite.
local cb = strip(source("modules/champ_banner.lua"))
check("the championship strip matches too",
      tonumber(cb:match("M%.RANK_H%s*=%s*(%d+)")),
      const("main/online.gui_script", "BAN_RANK_H"))
check("...including the gap",
      tonumber(cb:match("M%.RANK_GAP%s*=%s*(%d+)")),
      const("main/online.gui_script", "BAN_RANK_GAP"))

-- The game-over panel draws at its own text size, so it must scale the width
-- rule rather than using the strips' figure raw — otherwise a 14px word sits in
-- a pill sized for an 18px one.
local go = strip(source("main/gameover.gui_script"))
ok("game-over scales the pill width to its own text size",
   go:find("rank%.width%(t%.label%) %* RANK_TXT / RANK_NATIVE") ~= nil)
ok("game-over badges both players",
   go:find("n_you_rank_bg") ~= nil and go:find("n_opp_rank_bg") ~= nil)
ok("game-over reads winRate from the payload it already gets",
   go:find("mi%.winRate") ~= nil and go:find("oi%.winRate") ~= nil)
-- The pills are not in score_nodes: apply_layout blanket-enables that list, and
-- an unrated player would get an empty coloured pill beside their name.
-- Matched against the table literal alone — `.-` spans newlines in Lua, so a
-- pattern reaching past the closing brace would find the pills in the helper
-- that positions them and fail for the wrong reason.
local score_nodes = go:match("score_nodes = {(.-)}") or ""
ok("the score_nodes list is findable", score_nodes ~= "")
ok("the pills stay out of score_nodes", not score_nodes:find("rank"))

-- ── and that the drawing actually runs ──────────────────────────────────────
--
-- Source-level checks catch a surface that stopped asking the module. They do
-- not catch a call that raises the moment it is made — and on the invite strips
-- that failure is not visible as an error: incoming.gui_script wraps rebuild()
-- in a pcall and DROPS the request on a draw error, so a broken pill would show
-- up as challenges that silently never appear.
--
-- So the paths are run, under the simulator, with a rating and without one.
package.path = here .. "/?.lua;" .. package.path
local SIM = require("defold_sim")
SIM.install_gui_stub()

local ui = require("modules.ui")
local nodes = {}
local function track(n) nodes[#nodes + 1] = n; return n end

for _, wr in ipairs({ 0, 30, 47, 52, 90 }) do
  ok("a pill is drawn for " .. wr,
     rank.draw({ track = track, ui = ui }, wr, 100, 50, 22, 1) > 0)
end
check("no rating draws nothing", rank.draw({ track = track, ui = ui }, nil, 100, 50, 22, 1), 0)

-- The championship strip, which draws the pill on its own name line.
local champ_banner = require("modules.champ_banner")
-- `{ 62, nil }` would NOT work here: ipairs stops at the first nil, so the
-- unrated case — the one that has to draw nothing without falling over — would
-- silently never run. Boxed one per table so both are visited.
for _, case in ipairs({ { wr = 62 }, {} }) do
  local wr = case.wr
  local anim = champ_banner.draw({
    track = track, ui = ui,
    box = { L = 0, R = 1280, CX = 640 },
    button = function() end,
  }, { opponent_name = "RIVAL", desc = "Best of 3", avatar = 1, prize = 5000,
       joining = true, entry_fee = 500, opp_winrate = wr }, 360, 1)
  ok("the championship strip draws with winrate=" .. tostring(wr),
     anim ~= nil and anim.fill ~= nil)
end

-- Both request dialogs, through the shape of ctx the two screens build.
local ctx = {
  C = { COL_DIM = vmath.vector4(1,1,1,1), COL_MID = vmath.vector4(1,1,1,1),
        COL_GOLD = vmath.vector4(1,1,1,1), COL_WHITE = vmath.vector4(1,1,1,1),
        COL_GREEN = vmath.vector4(1,1,1,1), COL_RED = vmath.vector4(1,1,1,1),
        COL_CYAN = vmath.vector4(1,1,1,1) },
  ui = ui,
  track = function(_, n) nodes[#nodes + 1] = n; return n end,
  mkbtn = function() end,
  commas = function(n) return tostring(n) end,
  CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
  DLG_RED = vmath.vector4(1,1,1,1), DLG_SEARCH = vmath.vector4(1,1,1,1),
  with_a = function(c, a) return vmath.vector4(c.x, c.y, c.z, c.w * (a or 1)) end,
  dlg_avatar = function() end, dlg_timer = function() end,
  h2h_view = function(h) return h and { p = 1, o = 2, total = 3, form = { "W", "L" },
                                        opp_winrate = h.wr } or nil end,
  draw_h2h_row = function() end,
}
for _, mod in ipairs({ "modules.dialog_incoming", "modules.dialog_outgoing" }) do
  local dlg = require(mod)
  for _, wr in ipairs({ 33, 47, 51, 77 }) do
    ok(mod .. " draws at " .. wr, pcall(dlg.draw, { nodes = {}, buttons = {} }, ctx,
      { name = "RIVAL", stake = { amount = 200 }, time_left = 7, avatar = 1,
        h2h = { wr = wr } }, 1))
  end
  -- A FIRST MEETING sends no head-to-head at all, which is the case that would
  -- have taken the whole dialog down with it.
  ok(mod .. " draws with no head-to-head", pcall(dlg.draw, { nodes = {}, buttons = {} }, ctx,
    { name = "STRANGER", stake = {}, time_left = 3, avatar = 2 }, 1))
end

-- ── the game-over panel, driven by real messages ────────────────────────────
SIM.load_script_component("gui_over", "main/gameover.gui_script")
SIM.init_component("gui_over")
local S = SIM.components["gui_over"].self

local function result(my_wr, opp_wr)
  msg.post("#gui_over", "setup_avatars", {
    my_info = { id = "me",  username = "Me",    avatar = 1, winRate = my_wr },
    op_info = { id = "opp", username = "AVeryLongOpponentName", avatar = 2, winRate = opp_wr },
  })
  msg.post("#gui_over", "game_over", {
    won = true, my_id = "me",
    results = { reason = "", gameType = "NORMAL", stake = { amount = 200 },
                currentScores = { me = 3, opp = 1 } },
  })
  SIM.pump(0.5)
end

result(62, 47)
check("game-over badges the player",   gui.get_text(S.n_you_rank_tx), "GRANDMASTER")
check("game-over badges the opponent", gui.get_text(S.n_opp_rank_tx), "PRO")
ok("the player's pill is shown",   gui.is_enabled(S.n_you_rank_bg))
ok("the opponent's pill is shown", gui.is_enabled(S.n_opp_rank_bg))
-- OUTBOARD, both of them: away from the centre line, where the PRIZE / POINTS
-- strip already sits at almost the same height.
ok("the player's pill sits left of its name",
   gui.get_position(S.n_you_rank_bg).x < gui.get_position(S.n_you_name).x,
   ("pill %.1f vs name %.1f"):format(gui.get_position(S.n_you_rank_bg).x,
                                     gui.get_position(S.n_you_name).x))
ok("the opponent's pill sits right of its name",
   gui.get_position(S.n_opp_rank_bg).x > gui.get_position(S.n_opp_name).x,
   ("pill %.1f vs name %.1f"):format(gui.get_position(S.n_opp_rank_bg).x,
                                     gui.get_position(S.n_opp_name).x))

result(nil, nil)
ok("an unrated player gets no pill",   not gui.is_enabled(S.n_you_rank_bg))
ok("an unrated opponent gets no pill", not gui.is_enabled(S.n_opp_rank_bg))

-- ...and a rating arriving after an unrated result brings the pill back, rather
-- than the panel staying stuck on whatever the last game left behind.
result(20, 90)
check("a later result re-badges the player",   gui.get_text(S.n_you_rank_tx), "AMATEUR")
check("a later result re-badges the opponent", gui.get_text(S.n_opp_rank_tx), "GRANDMASTER")

print()
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
