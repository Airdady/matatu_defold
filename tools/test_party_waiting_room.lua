-- FOUR CHAIRS, AND THE ONES THAT ARE STILL EMPTY.
--
--   Run: lua5.4 tools/test_party_waiting_room.lua
--
-- A party used to wait inside the OPPONENT SEARCH dialog: a spinning reel, a
-- rail of candidates "HELD FOR YOU", one of whom would be chosen when the
-- window closed. None of that is what a table does. Everybody who sits down is
-- in, in the order they arrived — and the one thing a player at a table is
-- actually watching, CHAIRS FILLING, was the one thing that surface could not
-- show, because it had no idea a chair could be empty.
--
-- So the request dialog draws it instead: the same plate an incoming challenge
-- uses, with the whole table in it. Every seat from the first frame, the open
-- ones drawn as open and breathing, the pot growing as they fill.
--
-- The logic is pure and is driven for real here. The drawing needs a running
-- Defold, so it is exercised through the gui stub the other dialog tests use —
-- enough to catch a draw that throws, which on this surface is a modal with
-- nothing in it.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

local SIM = require("defold_sim")
SIM.install_gui_stub()
local dlg = require("modules.dialog_incoming")

-- ── WHO IS IN, AND WHEN THEY SAT DOWN ───────────────────────────────────────
local party = {
  partyId = "p1",
  entry = 200,
  seats = {
    { userId = "h1", username = "Mubarak", avatar = 7 },
    { userId = "me", username = "Scovia", avatar = 3 },
  },
}

local seen = {}
local seats, fresh = dlg.party_seats(seen, party, "me", 10)
eq("both seats are drawn", #seats, 2)
eq("...in the order they joined", seats[1].username .. "," .. seats[2].username, "Mubarak,Scovia")
check("...with our own chair marked", seats[2].is_me and not seats[1].is_me)
eq("...and both are new the first time we look", fresh, 2)
eq("the arrival stamp is when we first saw them", seats[1].arrived_at, 10)

-- STAMPS DO NOT MOVE. This is what stops every chair popping again on every
-- rebuild — the dialog is redrawn whenever anything changes, and a stamp taken
-- at draw time would restart the animation each time.
local again = dlg.party_seats(seen, party, "me", 25)
eq("a chair already seen keeps its stamp", again[1].arrived_at, 10)
eq("...and is not counted as an arrival twice", select(2, dlg.party_seats(seen, party, "me", 30)), 0)

-- A NEW ARRIVAL IS THE EVENT THE WHOLE DIALOG EXISTS TO SHOW.
party.seats[3] = { userId = "c", username = "Akello", avatar = 5 }
local three, fresh3 = dlg.party_seats(seen, party, "me", 40)
eq("the third player is one new arrival", fresh3, 1)
eq("...stamped at the moment they landed", three[3].arrived_at, 40)
eq("...and the ones already seated are unchanged", three[1].arrived_at, 10)

-- A table nobody has been seated at yet still answers, rather than erroring on
-- the frame between the tap and PARTY_ROSTER.
eq("no table yet is no seats, not a crash", #dlg.party_seats({}, nil, "me", 0), 0)
eq("...and neither is a table with no seat list", #dlg.party_seats({}, { partyId = "x" }, "me", 0), 0)

-- ── WHAT THE ROOM SAYS ──────────────────────────────────────────────────────
local function line(d) return dlg.party_line(d) end
local function strip_dots(s) return (s:gsub("%.+$", "")) end

eq("alone at your own table, it says what it is waiting for",
   strip_dots(line({ seats = { {} }, now = 0, subtitle = "opening your table" })),
   "opening your table")
eq("...and two is enough to play, so it says so",
   strip_dots(line({ seats = { {}, {} }, now = 0 })), "2 at the table - it can start")
eq("...three too", strip_dots(line({ seats = { {}, {}, {} }, now = 0 })),
   "3 at the table - it can start")
eq("a table that dealt hands over rather than counting",
   line({ seats = { {}, {} }, found = true }), "dealing you in\226\128\166")
eq("a table called off says why", line({ failed = true, fail_msg = "Nobody else sat down in time" }),
   "Nobody else sat down in time")
eq("...and has words even when nothing said why",
   line({ failed = true }), "Nobody else sat down in time")

-- THE DOTS ARE A CLOCK. On a screen where nothing else moves between arrivals
-- they are the only proof the dialog has not frozen.
do
  local seen_forms = {}
  for i = 0, 6 do seen_forms[line({ seats = { {} }, now = i * 0.5 })] = true end
  local n = 0
  for _ in pairs(seen_forms) do n = n + 1 end
  check("the dots cycle rather than sitting still", n == 3, "distinct forms: " .. n)
end

-- ── WHEN TO REDRAW, AND WHEN NOT TO ─────────────────────────────────────────
-- Rebuilding the screen to advance a countdown digit is what tore the whole
-- lobby down sixty times a second the last time this was got wrong.
do
  local a = { seats = { {}, {} }, size = 4, now = 1 }
  local b = { seats = { {}, {} }, size = 4, now = 9 }
  eq("a second passing is not a reason to rebuild", dlg.party_key(a), dlg.party_key(b))
  check("a chair filling is", dlg.party_key(a) ~= dlg.party_key({ seats = { {}, {}, {} }, size = 4 }))
  check("...and so is the table dealing",
    dlg.party_key(a) ~= dlg.party_key({ seats = { {}, {} }, size = 4, found = true }))
  check("...and being called off",
    dlg.party_key(a) ~= dlg.party_key({ seats = { {}, {} }, size = 4, failed = true }))
end

-- ── THE EMPTY CHAIRS BREATHE ────────────────────────────────────────────────
-- The difference between "waiting for somebody" and "nothing is happening" is
-- the only thing a player staring at a gap wants to know.
do
  local lo, hi = 1, 0
  for i = 0, 100 do
    local v = dlg.seat_breath(i * 0.05, 1)
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  check("it stays faint", lo >= 0.17 and hi <= 0.29, ("%.3f..%.3f"):format(lo, hi))
  check("...but it does move", hi - lo > 0.05, ("%.3f"):format(hi - lo))
  check("each chair breathes out of step with its neighbour",
    dlg.seat_breath(0, 1) ~= dlg.seat_breath(0, 2))
end

-- ── AND IT DRAWS ────────────────────────────────────────────────────────────
-- A draw that throws on this surface is a modal with nothing in it, which is
-- the failure the overlay's own watchdog exists to catch.
local ui = require("modules.ui")
-- Declared before it is filled in: dlg_avatar below refers to the table it
-- lives in, and `local ctx = {...}` would have that name still be a global.
local ctx
ctx = {
  C = { COL_DIM = vmath.vector4(1,1,1,1), COL_MID = vmath.vector4(1,1,1,1),
        COL_GOLD = vmath.vector4(1,1,1,1), COL_WHITE = vmath.vector4(1,1,1,1),
        COL_GREEN = vmath.vector4(1,1,1,1), COL_RED = vmath.vector4(1,1,1,1),
        COL_CYAN = vmath.vector4(1,1,1,1) },
  ui = ui,
  -- The real ctx tracks onto the HOST, and draw_party reads self.nodes back to
  -- find the two nodes dlg_avatar just made. A track that collected them
  -- somewhere else would be testing a different function.
  track = function(host, n) host.nodes[#host.nodes + 1] = n; return n end,
  mkbtn = function() end,
  commas = function(n) return tostring(n) end,
  CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
  DLG_RED = vmath.vector4(1,1,1,1), DLG_SEARCH = vmath.vector4(1,1,1,1),
  with_a = function(c, a) return vmath.vector4(c.x, c.y, c.z, c.w * (a or 1)) end,
  -- Never called by draw_party — it draws its own chairs so it can HOLD the
  -- nodes it animates rather than fishing them back out of the node list by
  -- index. Present because the ctx the real screens build has it.
  dlg_avatar = function() end,
  dlg_timer = function() end,
  h2h_view = function() return nil end,
  draw_h2h_row = function() end,
}

for taken = 0, 4 do
  local s = {}
  for i = 1, taken do
    s[i] = { userId = "u" .. i, username = "P" .. i, avatar = i, is_me = i == 1, arrived_at = 0 }
  end
  local host = { nodes = {}, buttons = {} }
  local drew, why = pcall(dlg.draw_party, host, ctx, {
    seats = s, size = 4, entry = 200, secs = 12, now = 3,
  }, 1)
  check("draws a table with " .. taken .. " seated", drew, tostring(why))
  -- The scrim, so a tap cannot reach the screen behind a room the player has
  -- already paid to be in.
  check("...and blocks the screen behind it", #host.buttons == 1 and host.buttons[1].id == "dlg_block")
  -- Every chair is recorded for the per-frame update, filled or not: the empty
  -- ones breathe and the filled ones pop, and neither can happen through a
  -- rebuild.
  local seated_n, hole_n = 0, 0
  for _ in pairs(host.party_anim.seats) do seated_n = seated_n + 1 end
  for _ in pairs(host.party_anim.holes) do hole_n = hole_n + 1 end
  eq("...tracking " .. taken .. " filled chairs", seated_n, taken)
  eq("...and " .. (4 - taken) .. " open ones", hole_n, 4 - taken)
  check("...then animates without a rebuild",
    dlg.animate_party(host, { seats = s, size = 4, secs = 11, now = 4 }))
end

-- A practice table has no pot to draw, and a free entry must not read as 0.
do
  local host = { nodes = {}, buttons = {} }
  check("a free table draws too",
    pcall(dlg.draw_party, host, ctx, { seats = {}, size = 4, entry = 0, secs = 5, now = 1 }, 1))
end

print(("party waiting room: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
