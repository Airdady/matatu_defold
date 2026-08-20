-- THE RECONNECT THAT KEPT KILLING OFFLINE GAMES.
--
--   Run: lua tools/test_takeover_rules.lua
--
-- Reported as: "whenever it happens, any offline game which was going on
-- closes and it's terminated."
--
-- Every reconnect runs IDENTIFY, and IDENTIFY's reply carries the account's
-- active online game when there is one. websocket_manager turns that into a
-- `game_request_accepted` event — the SAME event a freshly accepted invite
-- fires, with nothing on it to say which of the two it is. The controller's
-- handler ended with:
--
--     if self.screen ~= "game" then show(self, "game")
--     else msg.post("#game_logic", "ws_new_game_start") end
--
-- Read that second branch with an OFFLINE game on screen. The player is in a
-- Quick Play match, the socket comes back by itself in the background, and
-- their game is torn down mid-hand and replaced by an online one they
-- abandoned an hour ago. Nothing they did asked for it.
--
-- The rule is narrow on purpose. It has to refuse the background case without
-- touching the ordinary one — tap PLAY ONLINE, get matched, go to the game —
-- which is the same event arriving for a completely different reason. So it
-- bites only when all three are true: on the game screen, in offline mode,
-- with a live game.
--
-- What is refused is the NAVIGATION and only that. ws.active_game_state is set
-- by the parser before the event is emitted, so the online game is still there
-- to resume the moment the player leaves the offline one.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path

local T = require("modules.takeover_rules")

local function allowed(state) local ok = T.may_take_over(state); return ok end

print("\n== the bug: a background reconnect during Quick Play ==")
do
    check("an offline game in progress is protected",
        allowed({ screen = "game", mode = "offline", game_active = true }), false)
    check("the offline game object alone is enough",
        allowed({ screen = "game", mode = "offline", offline_game = {} }), false)
    -- game_active and offline_game are set at slightly different moments, and a
    -- takeover landing in the gap between them is exactly the timing this has
    -- to survive. Either one present means there is a match to protect.
    check("both together, still protected",
        allowed({ screen = "game", mode = "offline", game_active = true, offline_game = {} }), false)

    local ok, why = T.may_take_over({ screen = "game", mode = "offline", game_active = true })
    check("and it says why", why, "an offline game is in progress")
    check("the reason comes with a false", ok, false)
end

print("\n== the ordinary paths are untouched ==")
do
    -- Tap PLAY ONLINE from the lobby, get matched: the same event, and it must
    -- still navigate.
    check("from the lobby", allowed({ screen = "lobby", mode = "offline" }), true)
    check("from the online screen", allowed({ screen = "online", mode = "online" }), true)
    check("from the tournaments screen", allowed({ screen = "tournaments", mode = "online" }), true)

    -- An ONLINE game already on screen is the round-continuation case, which
    -- is the whole reason the ws_new_game_start branch exists.
    check("a round continuation is never blocked",
        allowed({ screen = "game", mode = "online", game_active = true }), true)

    -- The game screen in offline mode with nothing running — a torn-down game,
    -- or the moment before one starts. Nothing to protect.
    check("an idle offline game screen allows it",
        allowed({ screen = "game", mode = "offline" }), true)
    check("and explicitly not-active is the same",
        allowed({ screen = "game", mode = "offline", game_active = false, offline_game = nil }), true)
end

print("\n== nothing missing is treated as a game worth protecting ==")
do
    -- A missing snapshot must not block the ordinary path: the failure mode of
    -- being too eager here is a player who taps PLAY ONLINE and goes nowhere,
    -- which is worse than the bug this fixes.
    check("no state at all allows it", allowed(nil), true)
    check("an empty state allows it", allowed({}), true)
    check("a missing mode allows it", allowed({ screen = "game", game_active = true }), true)
    check("a missing screen allows it", allowed({ mode = "offline", game_active = true }), true)

    local _, why = T.may_take_over({})
    check("and says which test it failed", why, "not on the game screen")
end

print("\n== every answer carries a reason ==")
do
    local cases = {
        { screen = "lobby" },
        { screen = "game", mode = "online" },
        { screen = "game", mode = "offline" },
        { screen = "game", mode = "offline", game_active = true },
    }
    local missing = 0
    for _, c in ipairs(cases) do
        local _, why = T.may_take_over(c)
        if type(why) ~= "string" or why == "" then missing = missing + 1 end
    end
    check("no case answers without one", missing, 0)
end

print("\n== the convenience wrapper reads the same fields ==")
do
    -- The two call sites in controller.script go through this, so it must not
    -- quietly disagree with the function it wraps.
    local app_state = { mode = "offline", game_active = true, offline_game = nil }
    check("wrapper blocks the offline game",
        (T.may_take_over_now(app_state, "game")), false)
    check("wrapper allows it from the lobby",
        (T.may_take_over_now(app_state, "lobby")), true)

    app_state.mode = "online"
    check("wrapper allows a round continuation",
        (T.may_take_over_now(app_state, "game")), true)

    check("a nil app_state does not throw",
        (T.may_take_over_now(nil, "game")), true)
end

print("\n== the call sites actually use it ==")
do
    local f = assert(io.open(ROOT .. "main/controller.script"))
    local src = f:read("*a"); f:close()

    -- Both socket events that can navigate into a game must be guarded. The
    -- accept one is the one that was doing the damage; the start one is the
    -- same shape and would do it the moment the server sent a START on a
    -- reconnect.
    local guards = 0
    for _ in src:gmatch("takeover%.may_take_over_now%(app_state, self%.screen%)") do guards = guards + 1 end
    check("both handlers are guarded", guards, 2)

    -- The guard must come BEFORE app_state.mode is written: writing it is
    -- itself part of the takeover, and an offline game whose mode has been
    -- flipped to "online" underneath it stops behaving like one.
    local accept = src:match('ws%.on%("game_request_accepted".-end%)%)') or ""
    local g_at = accept:find("may_take_over_now", 1, true)
    local m_at = accept:find('app_state%.mode = "online"')
    check("the accept handler checks before it writes the mode",
        (g_at ~= nil and m_at ~= nil and g_at < m_at), true)

    local start = src:match('ws%.on%("game_start".-end%)%)') or ""
    local sg_at = start:find("may_take_over_now", 1, true)
    local sm_at = start:find('app_state%.mode = "online"')
    check("the start handler checks before it writes the mode",
        (sg_at ~= nil and sm_at ~= nil and sg_at < sm_at), true)

    -- The state must still be stored, or the online game is not resumable
    -- after the offline one ends.
    check("the accept handler still stores the game state",
        accept:find("ws%.active_game_state = gs") ~= nil, true)
end

print("")
if failures == 0 then
    print(string.format("ALL %d CHECKS PASSED", checks))
else
    print(string.format("%d of %d CHECKS FAILED", failures, checks))
    os.exit(1)
end
