-- THE BADGE AND THE TILE MUST NOT DISAGREE.
--
--   Run: lua tools/test_online_status.lua
--
-- Reported: "the connecting… and online badges are very effective — how come
-- the badges work but PLAY ONLINE stays on connecting? It successfully
-- connects but the tile still says signing in with Firebase, yet the user data
-- exists in the cache."
--
-- Both are true at once, and that is the whole bug. The badge reads the
-- connection: socket opened, go green. The tile read app_state.auth_state,
-- which is not a fact about the connection — it is a note left by whichever
-- code path last STARTED a sign-in, set in nine places, and identify_success
-- cleared it on exactly one branch (_restore_pending). Any sign-in that
-- finished another way left it pinned at "verifying" for the rest of the
-- session.
--
-- What made it invisible in review: with a cached user the tile's own
-- `waiting_for_connect` branch normally wins and shows "Verifying your
-- account…". It only falls through to "Signing in with Firebase…" once
-- ws.is_identified goes TRUE — so the stuck message appears precisely when the
-- app is fully connected. The more successful the connection, the more
-- confidently the tile reported the opposite.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local S = require("modules.lobby.online_status")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

print("THE REPORTED STATE: connected, identified, and a stale note")
-- Exactly what was on screen. Badge green, session cached, server has
-- accepted us — and auth_state still reading "verifying" from an attempt
-- nobody cleared.
check("identified beats a stale 'verifying'",
    S.tile_state({ is_identified = true, has_cached_user = true, auth_state = "verifying" }), "ready")
check("...and a stale 'sending'",
    S.tile_state({ is_identified = true, has_cached_user = true, auth_state = "sending" }), "ready")
check("...and a stale 'error'",
    S.tile_state({ is_identified = true, has_cached_user = true, auth_state = "error" }), "ready")
-- The note is CLEARED, not merely out-voted. go_online() refuses to act while
-- auth_state reads busy, so leaving it set would give a tile that says PLAY
-- NOW and ignores the tap.
check("and the note is recognised as stale", S.stale_auth("verifying", true), true)
check("so is a stale error", S.stale_auth("error", true), true)
check("a live attempt is NOT stale", S.stale_auth("verifying", false), false)
check("nor is an ordinary idle", S.stale_auth("idle", true), false)

print("")
print("Everything below that first rule keeps the order it had")
-- These are the existing behaviours; the fix is a rule ADDED on top, not a
-- rewrite, and this is what says so.
check("cached but not yet accepted: verifying",
    S.tile_state({ has_cached_user = true }), "verifying")
check("no session, attempt running: signing in",
    S.tile_state({ auth_state = "sending" }), "signing_in")
check("no session, nothing running: ready to play",
    S.tile_state({}), "ready")
check("a failed attempt with no session: error",
    S.tile_state({ auth_state = "error" }), "error")
-- Kept last deliberately: a cached player being reconnected should not be
-- shown a failure the reconnect is already recovering from.
check("a cached player mid-verify is not shown the error",
    S.tile_state({ has_cached_user = true, auth_state = "error" }), "verifying")

print("")
print("Exhausted outranks everything except being connected")
check("retries given up on", S.tile_state({ reconnect_exhausted = true }), "offline")
check("even with a cached session",
    S.tile_state({ reconnect_exhausted = true, has_cached_user = true }), "offline")
check("even mid-attempt",
    S.tile_state({ reconnect_exhausted = true, auth_state = "sending" }), "offline")
-- If the socket came back and the server accepted us, we are not offline,
-- whatever a stale exhausted flag says.
check("but an accepted identity means we are back",
    S.tile_state({ reconnect_exhausted = true, is_identified = true }), "ready")

print("")
print("It agrees with the badge on the thing the badge is right about")
-- The badge's rule is "socket open = ONLINE". The tile is stricter on purpose
-- — it leads into matchmaking, and matchmaking down a socket the server has
-- not registered is what this gate exists to stop. So connected-but-not-yet-
-- identified is still "verifying" here, and that is a real state, not the bug.
check("socket up, identity not yet accepted, session cached",
    S.tile_state({ has_cached_user = true, socket_connected = true }), "verifying")
-- What must never happen again: the two disagreeing in the OTHER direction,
-- where the connection is fully established and the tile still doubts it.
local established = { is_identified = true, socket_connected = true, has_cached_user = true }
for _, note in ipairs({ "sending", "verifying", "error", "idle", "done" }) do
    established.auth_state = note
    check("established + auth_state=" .. note, S.tile_state(established), "ready")
end

print("")
print("Nothing here can raise")
-- It runs inside the lobby rebuild, which repaints on every auth event.
check("no facts at all", S.tile_state(nil), "ready")
check("empty facts", S.tile_state({}), "ready")
check("junk auth_state", S.tile_state({ auth_state = 42 }), "ready")
check("stale_auth on nil", S.stale_auth(nil, true), false)
check("stale_auth on nothing", S.stale_auth(nil, nil), false)

print("")
print("The tile and the tap gate read the SAME predicate")
-- go_online() used to inline its own `sending or verifying` test. Two copies
-- of one rule is how the label and the behaviour drifted apart in the first
-- place: the tile could be fixed while the tap stayed dead.
local lobby = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../main/lobby.gui_script"):read("a")
check("the tile asks the module", lobby:find("online_status.tile_state", 1, true) ~= nil, true)
check("and so does the tap gate", lobby:find("online_status.auth_is_busy", 1, true) ~= nil, true)
check("the tap is not blocked once identified",
    lobby:find("not ws.is_identified and online_status.auth_is_busy", 1, true) ~= nil, true)
check("no open-coded copy of the rule is left behind",
    lobby:find('app_state.auth_state == "sending"', 1, true), nil)

local ctrl = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../main/controller.script"):read("a")

-- The handler body, not the whole file. WHERE the clear sits inside it is the
-- entire point: the original code did clear auth_state, but only on the
-- _restore_pending branch, so every other way of completing a sign-in left the
-- note behind. Asserting merely that the call exists somewhere would have gone
-- green against exactly the bug being fixed.
local handler = ctrl:match('ws%.on%("identify_success".-\n    end%)%)')
check("found the identify_success handler", handler ~= nil, true)
handler = handler or ""

local cleared = handler:find("online_status.stale_auth", 1, true)
local restore = handler:find("self._restore_pending", 1, true)
check("identify_success clears the stale note", cleared ~= nil, true)
check("...on EVERY path, not only the _restore_pending one",
    (cleared or math.huge) < (restore or 0), true)
-- A predicate that is only read and never acted on would satisfy the above.
local acts = handler:find('app_state%.auth_state%s*=%s*"idle"', cleared or 1)
check("...and actually assigns idle", acts ~= nil and acts < (restore or 0), true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
