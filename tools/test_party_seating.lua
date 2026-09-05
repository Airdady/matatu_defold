package.path = "/home/user/matatu_defold/?.lua;" .. package.path
-- Stub the Defold globals party_board's requires touch at load time.
_G.vmath = { vector3 = function(x,y,z) return {x=x,y=y,z=z} end,
             vector4 = function(a,b,c,d) return {a,b,c,d} end }
_G.go = { animate=function() end, set=function() end, delete=function() end,
          PLAYBACK_ONCE_FORWARD=1, EASING_OUTQUAD=1 }
_G.msg = { post = function() end }
_G.gui = {}
_G.hash = function(s) return s end
_G.sys = { get_sys_info = function() return {} end, get_config = function() return nil end }
package.loaded["modules.board_layout"] = { CARD_SCALE_F = 1, Z_HAND = 0.05 }
package.loaded["modules.game_util"]    = { notify_gui = function() end }

local PB = require "modules.party_board"
local function eq(a,b,m) if a~=b then error(m.." expected "..tostring(b).." got "..tostring(a)) end end

-- Everyone rotates the SAME server order to their own seat, and the result
-- must agree: the player to my left is the one who plays after me.
local order = {"a","b","c","d"}
local sa = PB.seating(order, "a")
eq(#sa, 3, "a sees 3 opponents")
eq(sa[1].id, "b", "next after a is b"); eq(sa[1].slot, "left", "b on a's left")
eq(sa[2].id, "c", "across"); eq(sa[2].slot, "top", "c across")
eq(sa[3].id, "d", "right"); eq(sa[3].slot, "right", "d right")

local sc = PB.seating(order, "c")
eq(sc[1].id, "d", "next after c is d"); eq(sc[1].slot, "left", "d on c's left")
eq(sc[3].id, "b", "b is c's right")

-- Three seats
local s3 = PB.seating({"a","b","c"}, "b")
eq(#s3, 2, "3-table has 2 opponents")
eq(s3[1].id, "c", "next after b"); eq(s3[1].slot, "left", "left")
eq(s3[2].id, "a", "then a"); eq(s3[2].slot, "right", "right")

-- Two seats: opponent opposite
local s2 = PB.seating({"a","b"}, "b")
eq(#s2, 1, "2-table has 1 opponent"); eq(s2[1].id, "a"); eq(s2[1].slot, "top", "opposite")

-- Not seated at this table at all: still draws everyone
local sx = PB.seating(order, "zzz")
eq(#sx, 3, "spectator still sees the table")

-- Junk in the order
local sj = PB.seating({"a","","b",false,"c"}, "a")
eq(#sj, 2, "blanks dropped")

-- A size the layout has no map for must still draw somebody
local s5 = PB.seating({"a","b","c","d","e"}, "a")
eq(#s5, 4, "five seats still draws four opponents")
eq(s5[1].slot, "top", "unmapped size falls back to opposite")

-- Empty / nil
eq(#PB.seating({}, "a"), 0, "empty table")
eq(#PB.seating(nil, "a"), 0, "nil order")

-- THE TABLE COLLAPSES AROUND WHOEVER IS LEFT, the way the offline chamber's
-- assign_slots does. The seat ORDER never shrinks — the server fixes it at the
-- deal and marks eliminations as a flag, because the turn arithmetic reads
-- through it — but the LAYOUT is keyed on the survivors, so three players sit
-- left/right with nobody across, exactly as they do offline.
local s3r = PB.seating(order, "a", { c = true })
eq(#s3r, 2, "one out leaves two opponents")
eq(s3r[1].id, "b", "turn order survives the drop"); eq(s3r[1].slot, "left", "b still left")
eq(s3r[2].id, "d", "then d"); eq(s3r[2].slot, "right", "d takes right, not across")

-- The rotation is taken first and the eliminated dropped after, so the chair
-- someone is promoted into is still decided by the server's order.
local sp = PB.seating(order, "a", { b = true })
eq(sp[1].id, "c", "the next in order is promoted"); eq(sp[1].slot, "left", "into the left chair")

local s1 = PB.seating(order, "a", { b = true, d = true })
eq(#s1, 1, "two left is one opponent"); eq(s1[1].slot, "top", "opposite, as a duel")

-- Omitted set means nobody is out, which is what a fresh deal wants.
eq(#PB.seating(order, "a"), 3, "no set given is a full table")

print("party_board.seating: all assertions passed")
