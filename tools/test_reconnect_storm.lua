-- THREE FAULTS FROM ONE LOG, AND THEY FED EACH OTHER.
--
--   Run: lua tools/test_reconnect_storm.lua
--
-- The reported console, stripped to its repeating unit:
--
--   [WS] reconnecting in 1.5s (attempt 26)
--   SSLSocket mbedtls_ssl_handshake: -29312
--   ERROR:SCRIPT: modules/ui.lua:66: Out of nodes (max 1024)
--     main/lobby.gui_script:134: in function rebuild
--   ERROR:GAMESYS: ... RESULT_SCRIPT_ERROR. Message 'auth_state_changed'
--
-- 1. THE HANDSHAKE. -29312 is MBEDTLS_ERR_SSL_CONN_EOF: the peer closed the
--    connection part way through the TLS handshake. Not a certificate fault,
--    not a protocol mismatch — the other end hung up, which is what a tunnel
--    does when it is shedding connections.
--
-- 2. THE RETRY RATE. WAITING_RECONNECT_MAX capped the backoff at 1.5s while a
--    player was waiting to be identified, and never escalated past it. So the
--    app opened a fresh handshake every 1.5s for as long as the outage lasted,
--    feeding the thing it was retrying against.
--
-- 3. THE NODE BUDGET. Every one of those retries emitted auth_state_changed,
--    and the lobby rebuilt itself on each one — unconditionally, including
--    while it was disabled and the player was on another screen. That is tens
--    of full teardown-and-rebuild cycles a minute against a 1024-node budget.
--
-- The one that matters is 2: fix the retry rate and the other two stop having
-- anything to do.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local function read(rel)
    local base = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
    local f = assert(io.open(base .. "../" .. rel))
    local s = f:read("a")
    f:close()
    return s
end

-- Comments below NAME the values being asserted about, so anything checking
-- for absence has to run against code with the prose stripped out.
local function strip(s)
    return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

local ws_src    = read("modules/websocket_manager.lua")
local ws        = strip(ws_src)
local lobby     = strip(read("main/lobby.gui_script"))
local lobby_gui = read("main/lobby.gui")

print("THE RETRY RATE ESCALATES INSTEAD OF SITTING AT 1.5s")
check("the fast ceiling is still there for the blip it exists for",
    ws:find("WAITING_RECONNECT_MAX = 1.5", 1, true) ~= nil, true)
check("but it applies to a bounded number of attempts",
    ws:find("WAITING_FAST_ATTEMPTS", 1, true) ~= nil, true)
check("after which slower ceilings take over",
    ws:find("WAITING_RECONNECT_MID_MAX", 1, true) ~= nil
        and ws:find("WAITING_RECONNECT_SLOW_MAX", 1, true) ~= nil, true)
check("chosen by attempt count, not fixed",
    ws:find("reconnect_attempts <= WAITING_FAST_ATTEMPTS", 1, true) ~= nil, true)
check("with a late band for the case the log was in",
    ws:find("reconnect_attempts <= WAITING_LATE_ATTEMPTS", 1, true) ~= nil, true)

-- Each ceiling has to actually be an escalation on the one before, and all of
-- them well short of the 30s an idle app backs off to — a waiting player must
-- not be stranded, which is the whole point of the fast path.
local fast = tonumber(ws:match("WAITING_RECONNECT_MAX = ([%d%.]+)"))
local mid  = tonumber(ws:match("WAITING_RECONNECT_MID_MAX%s+= ([%d%.]+)"))
local slow = tonumber(ws:match("WAITING_RECONNECT_SLOW_MAX = ([%d%.]+)"))
print(string.format("      (ceilings: %ss then %ss then %ss)",
    tostring(fast), tostring(mid), tostring(slow)))
check("the middle ceiling is slower than the fast one", mid > fast, true)
check("and the late one slower again", slow > mid, true)
check("all still far short of the idle 30s", slow < 30, true)

-- THE PROMISE THE ESCALATION MUST NOT BREAK.
--
-- The first version of this escalated to 8s straight after the fast band,
-- which put a nine-failure sign-in at 35s — past the 30s that
-- tools/test_first_login_timing.lua pins, and that test caught it. The bands
-- are only allowed to be as aggressive as that promise permits, so the
-- arithmetic is asserted here rather than left to be rediscovered.
local INITIAL, BACKOFF = 1.0, 1.5
local total, ceiling_for = 0, nil
ceiling_for = function(n)
    if n <= 6 then return fast elseif n <= 20 then return mid else return slow end
end
for n = 1, 9 do
    total = total + math.min(INITIAL * BACKOFF ^ (n - 1), ceiling_for(n))
end
print(string.format("      (nine failed connects = %.1fs of backoff)", total))
check("nine failures still fit inside the 30s promise, with room for latency",
    total <= 20, true)

print("")
print("AND THE RETRIES ARE SPREAD OUT")
-- Every client that drops off a restarting server otherwise comes back on the
-- same schedule and arrives in one spike.
check("there is jitter", ws:find("RECONNECT_JITTER", 1, true) ~= nil, true)
check("applied to the delay", ws:find("current_reconnect_delay = current_reconnect_delay %*") ~= nil, true)
-- Applied BEFORE the clamp it would be flattened away by it, at exactly the
-- point every client is pinned to the same ceiling.
local clamp  = ws:find("current_reconnect_delay = math.min", 1, true)
local jitter = ws:find("current_reconnect_delay = current_reconnect_delay %*")
check("after the clamp, not before it", (jitter or 0) > (clamp or 0), true)

print("")
print("THE LOBBY DOES NOT REBUILD WHEN NOBODY IS LOOKING AT IT")
local handler = lobby:sub(lobby:find('hash("auth_state_changed")', 1, true) or 1)
handler = handler:sub(1, handler:find("\nend", 1, true) or #handler)
check("the branch exists", handler:find("rebuild(self)", 1, true) ~= nil, true)
check("and it is gated on the lobby being the screen on show",
    handler:find('app_state.current_screen == "lobby"', 1, true) ~= nil, true)
-- The gate has to come BEFORE the rebuild, not merely appear in the branch.
-- Guarded: with the gate deleted there is no position to compare, and a crash
-- here would mask the failure above rather than report it.
check("the gate precedes the rebuild",
    (handler:find('app_state.current_screen == "lobby"', 1, true) or math.huge)
        < (handler:find("rebuild(self)", 1, true) or 0), true)
check("and it also checks the screen was ever built",
    handler:find("self.nodes", 1, true) ~= nil, true)

print("")
print("WITH HEADROOM UNDER THE BUDGET IT WAS HITTING EXACTLY")
local max_nodes = tonumber(lobby_gui:match("max_nodes: (%d+)"))
print(string.format("      (lobby.gui max_nodes = %s)", tostring(max_nodes)))
check("raised above the 1024 it ran out at", max_nodes > 1024, true)
-- Same ceiling the other complex screens already use, rather than a number
-- picked to clear today's count by one.
check("to the size the other big screens use", max_nodes, 2048)

print("")
print("THE GATE IS NOT LOAD-BEARING FOR CORRECTNESS")
-- Skipping the rebuild must not leave a stale CTA behind: coming back to the
-- lobby has to repaint it from current state.
local enter = lobby:sub(lobby:find('hash("screen_enter")', 1, true) or 1)
enter = enter:sub(1, enter:find("elseif", 1, true) or #enter)
check("screen_enter still sets the state on the way back in",
    enter:find("set_state(self", 1, true) ~= nil, true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
