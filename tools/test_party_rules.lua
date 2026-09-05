-- A PARTY PLAYS BY THE OFFLINE CHAMBER'S RULES, OR IT IS A DIFFERENT GAME.
--
--   Run: lua5.4 tools/test_party_rules.lua
--
-- tournament4.lua has played three- and four-handed matatu since it shipped:
--
--     apply_skip(rec):
--       if v == 11 and survivors > 2 -> direction = -direction, "REVERSE!"
--       else                         -> step one extra seat
--
-- A jack REVERSES with three or more still in, and only skips heads-up, where
-- reversing would be invisible. An eight always skips. And in both cases the
-- seat that played it is DONE — game_flow's SKIP_TURN branch hands straight to
-- apply_skip and returns without reopening the hand.
--
-- The ONLINE party ran the two-player path instead: a skip kept the turn and
-- the player was asked to play again, while the server had already passed the
-- turn on. Same card, two behaviours, depending on whether the opponents were
-- people or bots.
--
-- Two halves: the rule driven for real, and the RULE READ OUT OF THE CHAMBER'S
-- OWN SOURCE — because "matches the offline game" is the whole requirement,
-- and a copy of the rule in a test would agree with itself forever.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end
local function eq(name, got, want)
  check(name, got == want, ("got %s want %s"):format(tostring(got), tostring(want)))
end

local PR = require "modules.party_rules"

-- ── THE JACK ────────────────────────────────────────────────────────────────
for _, live in ipairs({ 3, 4 }) do
  local e = PR.effect(PR.REVERSE_CARD, live)
  check("a jack reverses at " .. live .. " players", e.reverse == true)
  eq("...and the turn moves one seat, into the player who went before", e.steps, 1)
  eq("...and the table says so", e.flash, "REVERSE!")
end

do
  -- Heads-up: the player behind you and the player in front of you are the
  -- same person, so the chamber falls through to the skip branch.
  local e = PR.effect(PR.REVERSE_CARD, 2)
  check("a jack heads-up does not reverse", e.reverse == false)
  eq("...it skips, which round a table of two is play again", e.steps, 2)
end

-- ── THE EIGHT ───────────────────────────────────────────────────────────────
for _, live in ipairs({ 2, 3, 4 }) do
  local e = PR.effect(PR.SKIP_CARD, live)
  eq("an eight skips at " .. live .. " players", e.steps, 2)
  check("...and never reverses", e.reverse == false)
end

-- ── EVERYTHING ELSE ─────────────────────────────────────────────────────────
for _, v in ipairs({ 1, 2, 3, 5, 7, 10, 12, 13, 14, 50 }) do
  local e = PR.effect(v, 4)
  eq("card " .. v .. " leaves the rotation alone", e.steps, 1)
  check("...and does not turn the table", e.reverse == false)
end
do
  local e = PR.effect(nil, 4)
  eq("a missing card value never turns the table", e.steps, 1)
  check("...nor reverses it", e.reverse == false)
end

-- ── WHOSE TURN IT STAYS ─────────────────────────────────────────────────────
-- The one question the online party was answering wrong.
check("an eight ENDS the turn at a table of four", PR.keeps_turn(8, 4) == false)
check("...and so does a jack", PR.keeps_turn(11, 3) == false)
check("but heads-up a skip means play again", PR.keeps_turn(8, 2) == true)
check("...and so it does with no party at all", PR.keeps_turn(8, nil) == true)
check("an ordinary card never keeps the turn", PR.keeps_turn(5, 4) == true)

-- ── WHO IS STILL IN ─────────────────────────────────────────────────────────
do
  local st = {
    seatOrder = { "a", "b", "c", "d" },
    players = {
      a = { eliminated = false }, b = { eliminated = true },
      c = {}, d = { eliminated = false },
    },
  }
  eq("eliminated seats are not counted", PR.live_count(st), 3)
  eq("a game with no seat order is not a party", PR.live_count({ players = {} }), nil)
  eq("...and neither is nothing at all", PR.live_count(nil), nil)
  st.players.d.eliminated = true
  eq("a four-seat table down to two counts two", PR.live_count(st), 2)
  check("...and plays the heads-up rule", PR.keeps_turn(11, PR.live_count(st)) == true)
end

-- ── AND IT IS THE CHAMBER'S RULE, READ OUT OF THE CHAMBER ───────────────────
local function source(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close(); return s
end

do
  local t4 = source("modules/tournament4.lua")
  -- The line this module exists to match. If the chamber's rule is edited,
  -- this fails and the two are reconciled deliberately rather than drifting.
  check("the chamber still reverses on 11 above two survivors",
    t4:find("tonumber%(rec%.v%) == 11 and survivors > 2") ~= nil,
    "tournament4.apply_skip changed — party_rules.effect must be reconciled")
  check("...and flashes REVERSE!", t4:find('text = "REVERSE!"') ~= nil)
  check("...and otherwise steps one extra seat",
    t4:match("apply_skip.-else.-step_index%(self, self%.t4%.turn_idx%)") ~= nil)

  local flow = source("modules/game_flow.lua")
  check("an offline skip ends the turn rather than reopening the hand",
    flow:match("NA%.SKIP_TURN.-if self%.t4 then.-apply_skip%(self, rec%).-return") ~= nil)
  -- ...and now the online party does the same.
  check("and an online party of three or more does too",
    flow:find("PartyRules%.keeps_turn%(rec and rec%.v, self%.party_live_count%)") ~= nil)

  local board = source("modules/party_board.lua")
  check("the board keeps the live count the rule reads",
    board:find("self%.party_live_count = live") ~= nil)
  check("...flashes what the table just did", board:find('"t4_flash"') ~= nil)
  check("...only once per action, so a resync does not repeat it",
    board:find("stamp ~= self%._party_flash_at") ~= nil)

  local bl = source("modules/board_layout.lua")
  check("the deck sits where the chamber puts it at three or more",
    bl:find("or party_live >= 3") ~= nil)
  check("...and the hand is arched the same way",
    bl:find("tonumber%(self%.party_live_count%) or 0%) >= 3") ~= nil)
  check("...without editing the chamber's own condition",
    bl:find("self%.t4 ~= nil and self%.t4%.human_alive") ~= nil)
end

print(("party rules: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
