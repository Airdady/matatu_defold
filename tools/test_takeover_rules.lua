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
--
-- THE SECOND HALF, added later: the same reconnect ended offline games down a
-- completely different path. auth_required and identify_error both finished
-- with an unconditional
--
--     if self.screen ~= "lobby" then show(self, "lobby") end
--
-- and show() posts `disable` to #game_logic — game_active = false, _seq
-- bumped, the game gone. An expired session and a refused IDENTIFY are both
-- about the SOCKET, and a match against the AI needs neither socket nor
-- session to finish; both fire from background retries the player never saw.
--
-- Reported as: "at times when its offline and the others are trying to
-- reconnect they end up terminating the offline game going on."
--
-- may_interrupt is that rule, and the sections at the bottom pin two things
-- about it: that an ONLINE game is still interruptible (there the session IS
-- the game), and that the session recovery still runs unconditionally — only
-- the navigation waits. Refusing the jump AND skipping the re-login would
-- leave the player in their game with a dead session and nothing rebuilding
-- it, which is worse than the bug being fixed.

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

print("\n== the OTHER way a reconnect ended an offline game ==")
do
    -- auth_required and identify_error both finished with an unconditional
    --     if self.screen ~= "lobby" then show(self, "lobby") end
    -- and show() posts `disable` to #game_logic: game_active = false, _seq
    -- bumped, the offline game gone mid-hand. Neither event is about an
    -- offline game — both are about the socket, and both fire from background
    -- retries the player never saw.
    local function may(state) local ok = T.may_interrupt(state); return ok end

    check("an offline game in progress is protected",
        may({ screen = "game", mode = "offline", game_active = true }), false)
    check("the offline game object alone is enough",
        may({ screen = "game", mode = "offline", offline_game = {} }), false)

    local ok, why = T.may_interrupt({ screen = "game", mode = "offline", game_active = true })
    check("and it says why", why, "an offline game is in progress")
    check("the reason comes with a false", ok, false)

    -- AN ONLINE GAME STAYS INTERRUPTIBLE, deliberately. There the session IS
    -- the game: a rejected identity means the server will take no more moves,
    -- so staying would show a board that cannot play.
    check("an online game is still sent to the lobby",
        may({ screen = "game", mode = "online", game_active = true }), true)

    check("from the lobby it is a no-op anyway",
        may({ screen = "lobby", mode = "offline" }), true)
    check("from the online screen", may({ screen = "online", mode = "online" }), true)
    check("an idle offline game screen allows it",
        may({ screen = "game", mode = "offline" }), true)

    -- Same asymmetry as may_take_over: being too eager here would strand a
    -- player who genuinely needs to be signed out.
    check("no state at all allows it", may(nil), true)
    check("an empty state allows it", may({}), true)
    check("a missing mode allows it", may({ screen = "game", game_active = true }), true)
    check("a missing screen allows it", may({ mode = "offline", game_active = true }), true)

    local cases = {
        { screen = "lobby" },
        { screen = "game", mode = "online" },
        { screen = "game", mode = "offline" },
        { screen = "game", mode = "offline", game_active = true },
    }
    local missing = 0
    for _, c in ipairs(cases) do
        local _, w = T.may_interrupt(c)
        if type(w) ~= "string" or w == "" then missing = missing + 1 end
    end
    check("every answer carries a reason", missing, 0)
end

print("\n== the two rules agree about the thing they both protect ==")
do
    -- They are one condition read two ways. If they ever disagree about an
    -- offline game in progress, the bug is back down whichever path drifted.
    local protected = {
        { screen = "game", mode = "offline", game_active = true },
        { screen = "game", mode = "offline", offline_game = {} },
        { screen = "game", mode = "offline", game_active = true, offline_game = {} },
    }
    local disagreements = 0
    for _, c in ipairs(protected) do
        if T.may_take_over(c) ~= false or T.may_interrupt(c) ~= false then
            disagreements = disagreements + 1
        end
    end
    check("both refuse every offline game in progress", disagreements, 0)

    -- And both allow everything that is not one, except the online-game case
    -- where they intentionally differ in wording but not in answer.
    local allowed_both = {
        { screen = "lobby" },
        { screen = "online", mode = "online" },
        { screen = "game", mode = "offline" },
        { screen = "game", mode = "online", game_active = true },
        {},
    }
    local mismatches = 0
    for _, c in ipairs(allowed_both) do
        if T.may_take_over(c) ~= true or T.may_interrupt(c) ~= true then
            mismatches = mismatches + 1
        end
    end
    check("and both allow everything else", mismatches, 0)
end

print("\n== the interrupt wrapper reads the same fields ==")
do
    local app_state = { mode = "offline", game_active = true, offline_game = nil }
    check("wrapper blocks the offline game",
        (T.may_interrupt_now(app_state, "game")), false)
    check("wrapper allows it from the lobby",
        (T.may_interrupt_now(app_state, "lobby")), true)

    app_state.mode = "online"
    check("wrapper allows an online game to be interrupted",
        (T.may_interrupt_now(app_state, "game")), true)

    check("a nil app_state does not throw",
        (T.may_interrupt_now(nil, "game")), true)
end

print("\n== the auth handlers guard the navigation, and ONLY the navigation ==")
do
    local f = assert(io.open(ROOT .. "main/controller.script"))
    local src = f:read("*a"); f:close()

    local guards = 0
    for _ in src:gmatch("takeover%.may_interrupt_now%(app_state, self%.screen%)") do
        guards = guards + 1
    end
    check("both auth handlers are guarded", guards, 2)

    -- Neither handler may still have a bare lobby jump: that is the exact line
    -- that was ending offline games.
    local auth = src:match('ws%.on%("auth_required".-end%)%)') or ""
    local ident = src:match('ws%.on%("identify_error".-\n    end%)%)') or ""
    check("the auth_required handler was found", #auth > 0, true)
    check("the identify_error handler was found", #ident > 0, true)

    for label, body in pairs({ auth_required = auth, identify_error = ident }) do
        -- The jump must be reached through the guard, never on its own.
        local guarded = body:find("may_interrupt_now", 1, true) ~= nil
        check(label .. " consults the rule", guarded, true)
        -- `if self.screen ~= "lobby" then show(...)` may now only appear as
        -- the elseif branch of that guard.
        local bare = body:match('\n%s*if self%.screen ~= "lobby" then show%(self, "lobby"%) end')
        check(label .. " has no unguarded lobby jump", bare == nil, true)
    end

    -- THE RECOVERY MUST NOT BE GATED. Refusing the navigation while also
    -- skipping the re-login would leave the player in their game with a dead
    -- session and nothing rebuilding it — a worse bug than the one fixed.
    local a_login = auth:find("try_device_login", 1, true)
    local a_guard = auth:find("may_interrupt_now", 1, true)
    check("auth_required re-logs in before it asks about leaving",
        (a_login ~= nil and a_guard ~= nil and a_login < a_guard), true)
    check("identify_error still clears the session",
        ident:find("clear_session()", 1, true) ~= nil, true)
    local i_login = ident:find("try_device_login", 1, true)
    local i_guard = ident:find("may_interrupt_now", 1, true)
    check("identify_error rebuilds before it asks about leaving",
        (i_login ~= nil and i_guard ~= nil and i_login < i_guard), true)
end

print("")
if failures == 0 then
    print(string.format("ALL %d CHECKS PASSED", checks))
else
    print(string.format("%d of %d CHECKS FAILED", failures, checks))
    os.exit(1)
end
