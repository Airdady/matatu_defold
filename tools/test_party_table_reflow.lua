-- THE PARTY BOARD IS THE OFFLINE CHAMBER'S BOARD, DRIVEN FROM THE SERVER.
--
--   Run: lua5.3 tools/test_party_table_reflow.lua
--
-- Two questions asked of the live table, and they have different answers.
--
-- IS IT THE SAME LAYOUT AS THE OFFLINE FOUR-PLAYER CHAMBER? Yes, and by
-- construction rather than by coincidence: party_board pushes the SAME
-- messages t4_ui already listens for (t4_seat, t4_active, t4_clear) at the
-- SAME anchors the chamber uses, so neither mode has its own idea of where
-- "left" is. Pinned here because the day one of those message names drifts,
-- the party board silently draws nothing.
--
-- DOES IT REFLOW AS PLAYERS LEAVE? No — and that is a real gap, pinned as it
-- actually behaves rather than as the comments claim. The seat order is fixed
-- when the cards are dealt and the server never shrinks it (elimination is a
-- flag on the player, which is right: the turn arithmetic reads through it).
-- So a table of four that drops to two keeps left/top/right with dead chairs
-- greyed, where the offline chamber collapses to heads-up at two survivors.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path

_G.vmath = { vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
             vector4 = function(a, b, c, d) return { a, b, c, d } end }
_G.go  = { animate = function() end, set = function() end, delete = function() end,
           PLAYBACK_ONCE_FORWARD = 1, EASING_OUTQUAD = 1 }
_G.msg = { post = function() end }
_G.gui = {}
_G.hash = function(s) return s end
_G.sys = { get_sys_info = function() return {} end, get_config = function() return nil end }
package.loaded["modules.board_layout"] = { CARD_SCALE_F = 1, Z_HAND = 0.05 }

-- Record what reaches the HUD, which is the whole interface between the party
-- and the chamber's renderer.
local sent = {}
package.loaded["modules.game_util"] = {
    notify_gui = function(target, id, payload)
        sent[#sent + 1] = { target = target, id = id, payload = payload }
    end,
}

local PB = require "modules.party_board"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond, detail) check(label .. (detail and ("  [" .. detail .. "]") or ""),
    cond and true or false, true) end

----------------------------------------------------------------------
print("YOU ARE ALWAYS AT THE BOTTOM, AND YOUR LEFT IS WHO PLAYS NEXT")
----------------------------------------------------------------------
-- Every client is sent the same seatOrder and rotates it to its own id, so the
-- player drawn on your left is genuinely the one who plays after you — on
-- every device at the table.
local order = { "a", "b", "c", "d" }
local sa = PB.seating(order, "a")
check("four seats leave three opponents", #sa, 3)
check("the one who plays after me is on my left", sa[1].id .. sa[1].slot, "bleft")
check("...then across", sa[2].id .. sa[2].slot, "ctop")
check("...then right", sa[3].id .. sa[3].slot, "dright")

local sc = PB.seating(order, "c")
check("and it rotates for everybody", sc[1].id .. sc[1].slot, "dleft")
check("...so the table agrees about the order", sc[3].id .. sc[3].slot, "bright")

check("three at the table put the third across", PB.seating({"a","b","c"}, "b")[2].slot, "right")
check("two at the table sit opposite", PB.seating({"a","b"}, "b")[1].slot, "top")

----------------------------------------------------------------------
print("IT DRIVES THE OFFLINE CHAMBER'S RENDERER, NOT A SECOND ONE")
----------------------------------------------------------------------
local function board()
    return {
        my_player_id = "a",
        CENTER = { x = 640, y = 360 }, AI_HAND_Y = 600,
        SEAT_LEFT = { x = 120, y = 360 }, SEAT_RIGHT = { x = 1160, y = 360 },
        spawn_card = function() return { id = {} } end,
        set_back = function() end,
    }
end
local function state(seats, eliminated, turn)
    local players = {}
    for _, id in ipairs(seats) do
        players[id] = { username = id:upper(), avatar = 1, handCount = 5,
                        eliminated = eliminated and eliminated[id] or false }
    end
    return { seatOrder = seats, players = players, currentTurn = turn or seats[1] }
end
local function seats_sent()
    local out = {}
    for _, m in ipairs(sent) do if m.id == "t4_seat" then out[#out + 1] = m.payload end end
    return out
end
local function ids_sent(name)
    local out = {}
    for _, m in ipairs(sent) do if m.id == name then out[#out + 1] = m.payload end end
    return out
end

sent = {}
local b = board()
PB.sync(b, state(order, nil, "b"))
local drawn = seats_sent()
check("one seat message per opponent", #drawn, 3)
ok("...addressed to the game HUD, where t4_ui lives", sent[1].target == "#game")
ok("...as t4_seat, the message the chamber already understands",
    sent[1].id == "t4_seat")
local active = ids_sent("t4_active")
check("and exactly one turn ring", #active, 1)
check("...on whoever's turn it is", active[1].slot, "left")

-- The chamber's own anchors, not a second set of coordinates.
check("the left seat sits on the chamber's left anchor", drawn[1].x, 120)
check("across sits on the centre line", drawn[2].x, 640)
check("...at the opponent hand row", drawn[2].y, 600)
check("the right seat on the right anchor", drawn[3].x, 1160)

-- A game with no seatOrder is an ordinary duel: the two-player board is
-- already drawing it and a party redraw on top would be a second table.
sent = {}
PB.sync(board(), { players = {}, currentTurn = "a" })
check("a duel is left alone entirely", #sent, 0)

----------------------------------------------------------------------
print("AN ELIMINATED SEAT GOES GREY, AND LOSES ITS CARDS")
----------------------------------------------------------------------
sent = {}
local b2 = board()
PB.sync(b2, state(order, { c = true }, "b"))
drawn = seats_sent()
check("the table still draws every chair", #drawn, 3)
check("...with the one that went out marked", drawn[2].eliminated, true)
check("...and never shown as the active seat", drawn[2].active, false)
ok("...while the live seats stay live", drawn[1].eliminated == false)

-- THE TURN RING NEVER LANDS ON A CHAIR NOBODY IS IN.
--
-- Real rather than hypothetical: the server's nextTurn skips players who are
-- out, but PARTY_PLAYER_OUT carries currentTurn only when the turn actually
-- moved. A seat that drops out when it was NOT their turn leaves the client
-- holding "eliminated, and the turn is still theirs" until the next state
-- arrives — and a countdown was being started on it in that window.
sent = {}
PB.sync(board(), state(order, { c = true }, "c"))
check("no ring is drawn on an eliminated seat", #ids_sent("t4_active"), 0)
-- The control: the same state with that player still in gets one.
sent = {}
PB.sync(board(), state(order, nil, "c"))
check("...while a live seat still gets its ring", #ids_sent("t4_active"), 1)
check("...in the right chair", ids_sent("t4_active")[1].slot, "top")

----------------------------------------------------------------------
print("WHAT IT DOES NOT DO: RESEAT THE TABLE AS PLAYERS LEAVE")
----------------------------------------------------------------------
-- Pinned as it BEHAVES. The server fixes seatOrder when the cards are dealt
-- and marks eliminations as a flag rather than shrinking the list — which is
-- right, because the turn arithmetic reads through the flag — so the client is
-- handed four seats for the life of the table however many are still in it.
--
-- The offline chamber does collapse: tournament4 sets is_heads_up when two
-- survive and re-lays the opponent's hand across the centre. The party has no
-- equivalent, so a four-hander that comes down to two keeps a greyed chair on
-- either side rather than going face to face.
sent = {}
PB.sync(board(), state(order, { c = true, d = true }, "b"))
drawn = seats_sent()
check("two survivors still draw three chairs", #drawn, 3)
check("...the last opponent still on the LEFT, not opposite", drawn[1].slot, "left")
local chamber = io.open(ROOT .. "modules/tournament4.lua"):read("a")
ok("the offline chamber, by contrast, knows about heads-up",
    chamber:find("is_heads_up = %(#survivors == 2%)") ~= nil)
local party = io.open(ROOT .. "modules/party_board.lua"):read("a")
ok("...and the party board has no such switch yet",
    party:find("is_heads_up", 1, true) == nil)

----------------------------------------------------------------------
print("A SEAT THAT DROPS OUT MID-HAND REDRAWS THE TABLE")
----------------------------------------------------------------------
-- PARTY_PLAYER_OUT is the one elimination with no re-deal behind it: the hand
-- carries on a player short, so no PARTY_NEXT_HAND arrives to route through
-- start_game and redraw the seats. The socket marked the seat and moved the
-- turn on the live state, and nothing was listening — the badge stayed lit and
-- the turn ring sat on an empty chair until the next sync happened along.
local handler = io.open(ROOT .. "modules/online_handler.lua"):read("a")
ok("the handler listens for it at all",
    handler:find('ws%.on%("party_player_out"') ~= nil)
ok("...and re-syncs the seats when it lands",
    handler:match('ws%.on%("party_player_out".-PB%.sync') ~= nil)
ok("...from the state the socket actually mutated",
    handler:match('ws%.on%("party_player_out".-ws%.active_game_state') ~= nil)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
