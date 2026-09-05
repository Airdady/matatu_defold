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
-- DOES IT REFLOW AS PLAYERS LEAVE? Yes, the way the chamber does. The seat
-- ORDER is fixed when the cards are dealt and the server never shrinks it
-- (elimination is a flag on the player, which is right: the turn arithmetic
-- reads through it) — but the LAYOUT is a different question, and it is
-- answered off the survivors. Four becoming three reseats the two who are
-- left to left/right and takes the chair across the table away, exactly as
-- tournament4's assign_slots does at three; two is not a table at all and the
-- ordinary duel board takes it.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path

_G.vmath = { vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
             vector4 = function(a, b, c, d) return { a, b, c, d } end }
_G.go  = { animate = function() end, set = function() end, delete = function() end,
           set_position = function() end,
           PLAYBACK_ONCE_FORWARD = 1, EASING_OUTQUAD = 1, EASING_OUTCUBIC = 1 }
_G.timer = { delay = function(_, _, fn) if fn then fn() end end }
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
        play_sound = function() end,
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

-- THE CHAMBER'S OWN ANCHORS, IN THE CHAMBER'S OWN ROLES.
--
-- Both modules read SEAT_LEFT / SEAT_RIGHT / AI_HAND_Y, and both offset by 66
-- and 46 — but they had the two ROLES swapped. The chamber puts the CARDS on
-- the seat anchor and the BADGE outboard of it; this module put the badge on
-- the anchor and pushed the cards out past it, and dropped the top badge
-- directly onto the top arch instead of 46px above it. So the same table drew
-- with its avatars beside its hands offline and on top of them online.
--
-- Fixture: SEAT_LEFT.x 120, SEAT_RIGHT.x 1160, CENTER.x 640, AI_HAND_Y 600.
check("the left badge sits outboard of the left seat, as the chamber's does",
    drawn[1].x, 120 - 66)
check("across sits on the centre line", drawn[2].x, 640)
check("...and ABOVE the opponent's row, not on it", drawn[2].y, 600 + 46)
check("the right badge outboard of the right seat", drawn[3].x, 1160 + 66)

-- And the cards take the anchors the badges just gave up. Read off the deal
-- plan, which is the same arithmetic the reconcile lays them out with.
do
    local bg = board()
    local plan = PB.deal_plan(bg, state(order, nil, "a"))
    local by_slot = {}
    for _, sl in ipairs(plan) do by_slot[sl.slot] = sl.slots end
    -- The middle card of a five-card hand: no offset along the row, so it
    -- lands on the anchor itself in the direction the hand runs.
    check("the left hand runs down the left seat anchor", by_slot.left[3].y, 360)
    check("...the right hand down the right one", by_slot.right[3].y, 360)
    check("...and the top hand across the opponent's row", by_slot.top[3].x, 640)
end

-- THE ARCH IS THE CHAMBER'S ARCH, NOT A FLAT LINE.
--
-- This was a fixed 18px pitch with every card at the seat's base rotation.
-- The chamber fans its opponents: the pitch opens to 32px for a small hand
-- and closes as the hand grows so a whole hand always spans about 150px, the
-- row bows towards the middle of the table, and each card turns a little
-- further than the one before. On a five-card hand that is 18px of flat stack
-- against 32px of fanned arch — the squeezed hand, squeezed for no reason
-- except that this file had invented its own spacing.
do
    local bg = board()
    local plan = PB.deal_plan(bg, state(order, nil, "a"))
    local top
    for _, sl in ipairs(plan) do if sl.slot == "top" then top = sl.slots end end

    -- spacing = min(32, 150/(n-1)); at five cards that is the 32px ceiling,
    -- so the hand spans 4 x 32. The old flat pitch would have given 4 x 18.
    check("five cards span 128, not the flat layout's 72",
        math.floor(top[5].x - top[1].x + 0.5), 128)
    ok("the row bows rather than lying flat", top[3].y ~= top[1].y)
    ok("...towards the middle of the table", top[3].y < top[1].y)
    ok("the hand fans", top[1].rot ~= top[5].rot)
    ok("...symmetrically about its middle",
        math.abs(top[1].rot + top[5].rot) < 1e-9)
    ok("...and the middle card is the upright one", math.abs(top[3].rot) < 1e-9)

    -- A side seat fans about its own base rotation, not about zero.
    local left
    for _, sl in ipairs(plan) do if sl.slot == "left" then left = sl.slots end end
    check("the left hand is turned onto its side", left[3].rot, 90)
    ok("...and fans about that, not about upright", left[1].rot > 90 and left[5].rot < 90)
    ok("...running down the edge rather than across it",
        math.abs(left[5].y - left[1].y) > 100 and math.abs(left[5].x - left[1].x) < 1e-9)

    -- One card cannot divide by zero, and must sit exactly on the anchor.
    local one = PB.deal_plan(bg, {
        seatOrder = { "a", "b", "c", "d" },
        players = { a = {}, b = { handCount = 1 }, c = { handCount = 1 }, d = { handCount = 1 } },
        currentTurn = "a",
    })
    check("a single card sits on the anchor itself", one[2].slots[1].x, 640)
    check("...unrotated", one[2].slots[1].rot, 0)
end

-- The numbers themselves, pinned against the chamber's own source: the day
-- one of them is tuned there, this one has to be tuned with it or the two
-- modes are two different tables again.
do
    local chamber = io.open(ROOT .. "modules/tournament4.lua"):read("a")
    local party   = io.open(ROOT .. "modules/party_board.lua"):read("a")
    for _, expr in ipairs({
        "math.min(32, (n > 1 and 150 / (n - 1) or 0))",
        "math.min(9, n * 1.4)",
        "math.min(24, n * 3.4)",
        "(0.25 - t * t) * arc * toward",
        "br - t * fan * 2 * toward",
    }) do
        ok("the arch shares the chamber's `" .. expr .. "`",
            chamber:find(expr, 1, true) ~= nil and party:find(expr, 1, true) ~= nil)
    end
end

-- A game with no seatOrder is an ordinary duel: the two-player board is
-- already drawing it and a party redraw on top would be a second table.
sent = {}
PB.sync(board(), { players = {}, currentTurn = "a" })
check("a duel is left alone entirely", #sent, 0)

----------------------------------------------------------------------
print("THE TABLE COLLAPSES AROUND WHOEVER IS LEFT")
----------------------------------------------------------------------
-- THE LAYOUT IS A QUESTION ABOUT SURVIVORS, NOT ABOUT THE SEAT ORDER.
--
-- The order is fixed at the deal and never shrinks. The layout used to be read
-- off its LENGTH, so a table of four that lost a player kept left/top/right
-- with a dead chair greyed where the fourth had been, for the rest of the
-- game. The offline chamber has never done that: assign_slots reseats the
-- survivors, so three players sit bottom/left/right and there is nobody
-- across. Three players online are playing the same game on the same board.
check("four at the table seat three opponents",
    #PB.seating(order, "a", {}), 3)
local three = PB.seating(order, "a", { c = true })
check("...and three seat two", #three, 2)
check("the one who plays after me is still on my left", three[1].id .. three[1].slot, "bleft")
check("...and the other takes the RIGHT chair, not the one across",
    three[2].id .. three[2].slot, "dright")
ok("nobody is left sitting across the table",
    three[1].slot ~= "top" and three[2].slot ~= "top")

-- The rotation is taken first and the eliminated dropped after, so who plays
-- after whom is still the server's order rather than whoever is left.
local skipped = PB.seating(order, "a", { b = true })
check("dropping the player on my left promotes the next one", skipped[1].id, "c")
check("...to the left chair", skipped[1].slot, "left")
check("...and the rest keep their order", skipped[2].id .. skipped[2].slot, "dright")

-- Omitting the set is "nobody is out", which is what a fresh deal wants.
check("no set given means a full table", #PB.seating(order, "a"), 3)

-- AND THE BOARD ITSELF REFLOWS.
sent = {}
local b2 = board()
PB.sync(b2, state(order, nil, "b"))
check("four in draws three chairs", #seats_sent(), 3)

sent = {}
PB.sync(b2, state(order, { c = true }, "b"))
local drawn = seats_sent()
check("one out draws two", #drawn, 2)
ok("...and neither of them is the one who went", drawn[1].name ~= "C" and drawn[2].name ~= "C")
ok("...nor is any chair marked OUT — it is gone, not greyed",
    drawn[1].eliminated == false and drawn[2].eliminated == false)
check("they sit left and right, as three players do",
    drawn[1].slot .. "," .. drawn[2].slot, "left,right")

-- t4_ui keys badges by SLOT, so the chair that vanished has to be wiped: it is
-- never addressed again, and nothing else would take it off the screen.
check("the badges are rebuilt so no empty chair is left behind",
    #ids_sent("t4_clear"), 1)
-- But only when the arrangement actually CHANGES. This runs on every state
-- push — a wipe per move is a table that flickers all game.
sent = {}
PB.sync(b2, state(order, { c = true }, "d"))
check("an ordinary move rebuilds nothing", #ids_sent("t4_clear"), 0)
check("...and still draws the same two chairs", #seats_sent(), 2)

-- Their cards go with them, or an arch belonging to nobody sits face down on
-- the board for the rest of the game.
ok("the seat that went is no longer held", b2.party_seats["c"] == nil)
ok("...while the survivors still are", b2.party_seats["b"] ~= nil and b2.party_seats["d"] ~= nil)

-- THE TURN RING NEVER LANDS ON A CHAIR NOBODY IS IN.
--
-- Real rather than hypothetical: the server's nextTurn skips players who are
-- out, but PARTY_PLAYER_OUT carries currentTurn only when the turn actually
-- moved. A seat that drops out when it was NOT their turn leaves the client
-- holding "eliminated, and the turn is still theirs" until the next state
-- arrives — and a countdown was being started on it in that window.
sent = {}
PB.sync(board(), state(order, { c = true }, "c"))
check("no ring is drawn on a seat that is not there", #ids_sent("t4_active"), 0)
-- The control: the same state with that player still in gets one.
sent = {}
PB.sync(board(), state(order, nil, "c"))
check("...while a live seat still gets its ring", #ids_sent("t4_active"), 1)
check("...in the right chair", ids_sent("t4_active")[1].slot, "top")

----------------------------------------------------------------------
print("DOWN TO TWO IS NOT A TABLE ANY MORE - IT IS AN ORDINARY DUEL")
----------------------------------------------------------------------
-- A party seats its opponents in arches: backs at 85% scale, capped at ten, on
-- 18px spacing. That is the right drawing for three people round a table and
-- the wrong one for the last two players in the game, who are playing an
-- ordinary duel — and the app already has a board for that, with its own hand
-- spacing and its own card size, which every other two-player match uses.
--
-- So heads-up is not a party layout with two chairs hidden. The party board
-- stands down entirely and the ordinary renderer takes the opponent back.
check("four in, nobody out, is still a table", PB.is_heads_up(state(order)), false)
check("one eliminated is still a table", PB.is_heads_up(state(order, { d = true })), false)
check("two left is a duel", PB.is_heads_up(state(order, { c = true, d = true })), true)
check("a table dealt as two is a duel from the first card",
    PB.is_heads_up(state({ "a", "b" })), true)
check("...and so is the moment before it ends",
    PB.is_heads_up(state(order, { b = true, c = true, d = true })), true)
check("a duel with no seat order is not a party at all",
    PB.is_heads_up({ players = {} }), false)

-- Survivors are read off the FLAGS, because the seat order never shrinks: the
-- server fixes it at the deal and marks eliminations, which is right — the
-- turn arithmetic reads through the flag.
local live = PB.survivors(state(order, { b = true, d = true }))
check("the survivors are the unflagged seats", table.concat(live, ","), "a,c")
check("...in seat order", PB.survivors(state(order))[1], "a")

-- THE BOARD ITSELF: no seats drawn, and any it had are torn down.
sent = {}
local b3 = board()
PB.sync(b3, state(order, nil, "b"))
ok("a full table drew its chairs", #seats_sent() > 0)
sent = {}
PB.sync(b3, state(order, { c = true, d = true }, "b"))
check("coming down to two draws no party seats at all", #seats_sent(), 0)
ok("...and clears the ones it had", #ids_sent("t4_clear") == 1)
ok("...leaving nothing behind to redraw", b3.party_seats == nil)
-- Idempotent: every later sync must not keep re-posting the teardown.
sent = {}
PB.sync(b3, state(order, { c = true, d = true }, "b"))
check("and it does not keep tearing down what is already gone", #sent, 0)

-- A table that was only ever two never draws a chair in the first place.
sent = {}
PB.sync(board(), state({ "a", "b" }, nil, "a"))
check("two who turned up alone get no party board either", #sent, 0)

-- AND IT DEALS NO PARTY CARDS EITHER — the bug that put two hands on one
-- opponent.
--
-- The board stands down at heads-up and online_handler hands the opponent to
-- the ordinary duel renderer, but the DEAL is planned before either of those
-- runs, and it was planned off the seats alone. So the last two players got
-- BOTH: the duel's arch at the ordinary spacing and card size, and a party
-- arch of squeezed 85%-scale backs on 18px spacing flown to whichever chair
-- that opponent had been sitting in. Two hands, two card designs, one
-- opponent — which is exactly how it was reported.
do
    local b4 = board()
    b4.my_player_id = "a"
    check("four in still plans a party deal",
        PB.deal_plan(b4, state(order, nil, "a")) ~= nil, true)
    check("three in still plans one",
        PB.deal_plan(b4, state(order, { d = true }, "a")) ~= nil, true)
    check("but a table down to two plans NO party backs at all",
        PB.deal_plan(b4, state(order, { c = true, d = true }, "a")), nil)
    check("...and neither does a table that was only ever two",
        PB.deal_plan(b4, state({ "a", "b" }, nil, "a")), nil)
    check("...nor a game already decided, with one player left",
        PB.deal_plan(b4, state(order, { b = true, c = true, d = true }, "a")), nil)

    -- Which is what makes the mock deck the right size: the deal spawns a back
    -- for every party card it plans, so a plan that should not exist is a
    -- fistful of extra cards flying to a chair that is not there.
    check("so the deal spawns nothing extra for a duel",
        PB.deal_card_count(PB.deal_plan(b4, state(order, { c = true, d = true }, "a"))), 0)
end

----------------------------------------------------------------------
print("AND THE ORDINARY BOARD TAKES THE OPPONENT BACK")
----------------------------------------------------------------------
local handler = io.open(ROOT .. "modules/online_handler.lua"):read("a")
ok("a heads-up party is not treated as a party by the board builder",
    handler:match("local is_party = looks_like_party and duel_with == nil") ~= nil)
-- ONE survivor is a game that has just ended, not a duel. Falling through to
-- the ordinary path there would find no opponent, take the seven-card default,
-- and deal a phantom arch across a board whose game is over — so the duel path
-- is taken only when a surviving opponent was actually found.
ok("...and only when a surviving opponent was actually found",
    handler:match("if #live == 2 then") ~= nil)
-- The eliminated players are still in the players map, so "the first who is
-- not me" would hand the duel board a knocked-out player and their empty hand,
-- at random, on a table that came down to two.
ok("...and the opponent it picks is the SURVIVOR, not whoever pairs() yields",
    handler:find("local duel_with", 1, true) ~= nil
    and handler:match("not looks_like_party or pid == duel_with") ~= nil)
ok("...chosen from the survivors rather than the seat order",
    handler:match("PB%.survivors%(state%)") ~= nil)
-- A drop-out that takes the table to two changes what game this is, so the
-- duel board has to be built — syncing the seats alone would tear the party
-- chairs down and leave nothing in their place.
ok("a drop-out down to two rebuilds the board rather than only clearing it",
    handler:match('ws%.on%("party_player_out".-PB%.is_heads_up%(live%).-M%.start_game') ~= nil)

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

----------------------------------------------------------------------
print("THE TABLE IS DEALT ROUND, NOT JUST TO YOU")
----------------------------------------------------------------------
-- online_handler's deal loop was written for a duel: a card to you, a card to
-- the opponent, round after round. A party has no "the opponent" — opp_count
-- deliberately falls to zero there — so the loop dealt the local hand and
-- nothing else, and the other seats' cards did not fly anywhere. They were
-- popped into their arches fully formed the moment the roster synced.
--
-- The offline chamber has always dealt properly: for each round, one card to
-- every surviving seat IN TURN, each a stagger behind the last. Same table,
-- same shape.
do
    sent = {}
    local b = board()
    b.my_player_id = "a"
    local plan = PB.deal_plan(b, state(order, nil, "a"))
    ok("a party produces a deal plan", plan ~= nil)
    check("one entry per opponent seat", #plan, 3)
    check("...in turn order from your left", plan[1].id .. plan[1].slot, "bleft")
    check("...then across", plan[2].slot, "top")
    check("...then right", plan[3].slot, "right")
    check("each getting the hand the server dealt them", plan[1].count, 5)
    check("and a slot per card to fly to", #plan[1].slots, 5)

    -- The mock deck is sized off this. A card short and the deal runs out half
    -- way round the table.
    check("the deal knows how many backs it has to spawn", PB.deal_card_count(plan), 15)

    -- CAPPED AT WHAT THE ARCH ACTUALLY SHOWS. The mock deck is sized off this
    -- plan, so an uncapped hand spawns backs that fly to a slot that does not
    -- exist, land stacked on the tenth, and are deleted by the next
    -- reconcile — real cards, spawned and thrown away, on every big hand.
    do
        local big = { seatOrder = order, currentTurn = "a", players = {
            a = {}, b = { handCount = 14 }, c = { handCount = 3 }, d = { handCount = 9 },
        } }
        local capped = PB.deal_plan(b, big)
        check("a hand past the cap deals only what the arch shows", capped[1].count, 10)
        check("...with a slot for each of them", #capped[1].slots, 10)
        ok("...and hands under it are untouched", capped[2].count == 3 and capped[3].count == 9)
    end
    check("...and nothing to spawn for a duel", PB.deal_card_count(nil), 0)

    -- A duel has no plan at all, so the ordinary two-player deal is untouched.
    check("a game with no seat order deals the old way",
        PB.deal_plan(board(), { players = {}, currentTurn = "a" }), nil)
    -- Nor does a seat that is out get dealt to.
    local out_plan = PB.deal_plan(b, state(order, { c = true }, "a"))
    check("an eliminated seat is not dealt a hand", #out_plan, 2)
    for _, s in ipairs(out_plan) do
        ok("...and it is not the one who went out", s.id ~= "c")
    end
end

do
    -- The cards actually fly, from the middle to their own seat, and end up
    -- held by that seat so the reconcile does not deal them a second time.
    sent = {}
    local b = board()
    b.my_player_id = "a"
    local plan = PB.deal_plan(b, state(order, nil, "a"))
    for i = 1, plan[1].count do
        PB.deal_back(b, plan[1], { id = {} }, i, 0, nil)
    end
    check("the seat is holding what it was dealt", #b.party_seats["b"].cards, 5)
    check("...at the slot the plan gave it", b.party_seats["b"].slot, "left")

    -- And a fresh deal takes the old cards off first, or a hand shows twice.
    PB.clear_cards(b)
    check("clear_cards empties the seats", #b.party_seats["b"].cards, 0)
    ok("...but leaves the seats themselves", b.party_seats["b"] ~= nil)
end

do
    -- The wiring, in the handler that drives it.
    local handler = io.open(ROOT .. "modules/online_handler.lua"):read("a")
    ok("the deal loop deals to every party seat",
        handler:match("if party_plan then.-PB%.deal_back") ~= nil)
    ok("...staggered, like the chamber's",
        handler:match("PB%.deal_back.-delay = delay %+ deal_step") ~= nil)
    ok("...with the mock deck sized for their cards",
        handler:find("PB.deal_card_count(party_plan)", 1, true) ~= nil)
    ok("...and the loop running as long as the widest hand at the table",
        handler:match("for _, s in ipairs%(party_plan or {}%) do.-max_deal = s%.count") ~= nil)
    ok("...clearing the synced backs before it deals them again",
        handler:match("if party_plan then pcall%(PB%.clear_cards, self%) end") ~= nil)
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
