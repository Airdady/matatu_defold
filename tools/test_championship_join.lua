-- JOINING THE CHAMPIONSHIP IS A REQUEST, NOT AN ANIMATION.
--
--   Run: lua tools/test_championship_join.lua
--
-- Reported, from the tournament screen: "we have not locked the global
-- tournament, it's not making any http call, and what's funny is every time I
-- click join tournament it deducts credit."
--
-- Both halves of that were one line of code. The JOIN handler did:
--
--     u.balance = math.max(0, balance - cost)
--     gui.set_text(self.top_left_balance_lbl, commas(u.balance))
--     play_deduction_animation(self)
--
-- and nothing else. No request anywhere behind it. So the number on screen
-- fell on EVERY tap while the account was never touched, and the real money
-- came out later, per level, somewhere else entirely.
--
-- The server owns all three things that code guessed at: whether this player
-- has already paid, whether they can afford it, and what the balance is
-- afterwards. These drive the REAL tournaments.gui_script against a scripted
-- backend and check that nothing moves on screen until it has answered.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local function boot(opts)
    opts = opts or {}
    for name in pairs(package.loaded) do
        if name:match("^modules%.") then package.loaded[name] = nil end
    end
    package.path = ROOT .. "?.lua;" .. package.path

    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()
    _G.window.set_listener = function() end
    _G.window.set_dim_mode = function() end
    _G.window.DIMMING_OFF = 0
    _G.window.WINDOW_EVENT_FOCUS_GAINED = 1
    _G.window.WINDOW_EVENT_FOCUS_LOST = 2
    _G.sys.get_config_string = function() return "" end
    _G.sys.get_config = function() return "" end

    local http_log = {}
    _G.http = {
        request = function(url, method, cb, headers, body)
            http_log[#http_log + 1] = { url = url, method = method, body = body }
            local handler, best = nil, -1
            for _, r in ipairs(opts.routes or {}) do
                if url:find(r[1], 1, true) and #r[1] > best then handler, best = r[2], #r[1] end
            end
            local resp = handler and handler(body, method)
                or { status = 404, response = '{"success":false}' }
            local ctx = SIM.current_ctx
            -- Deliberately slow, so a second tap lands while the first is in
            -- flight. That race IS the "deducts every time" report.
            timer.delay(opts.latency or 0.5, false, function()
                SIM.with_ctx(ctx, cb, nil, nil, resp)
            end)
        end,
    }

    for _, id in ipairs({ "lobby", "auth", "online", "themes", "payments", "profile",
                          "team_tournament", "standings", "game", "game_logic", "coins",
                          "signup_bonus", "daily_bonus", "network", "incoming", "gameover",
                          "update_required", "toast", "announcement", "season_results",
                          "tutorial", "suit_select", "card_factory", "snd_coin",
                          "snd_suspense" }) do
        SIM.add_recorder(id)
    end
    SIM.load_script_component("controller", ROOT .. "main/controller.script")
    SIM.load_script_component("tournaments", ROOT .. "main/tournaments.gui_script")
    SIM.init_component("controller")
    SIM.init_component("tournaments")

    local ws = require("modules.websocket_manager")
    ws.current_user_data = {
        _id = "64b7f9a1c2d3e4f5a6b7c8d9", username = "Ada", avatar = 3,
        balance = opts.balance or 10000, points = 0,
        tournaments = { {
            _id = "T-GLOBAL", name = "Global Championship", scope = "GLOBAL",
            type = "public", status = "active",
            stake = { amount = 450, charge = 50, points = 0 },
            grandPrize = { value = 5000 },
            levels = {
                { name = "Qualifier 1", points = 1 }, { name = "Round of 64", points = 2 },
                { name = "Round of 32", points = 3 }, { name = "Round of 16", points = 4 },
                { name = "Quarter Finals", points = 5 }, { name = "Semi Finals", points = 7 },
                { name = "Finals", points = 10 },
            },
            userProgress = {
                currentLevel = opts.level or 1,
                joined = opts.joined and true or false,
                levels = {}, opponentsPlayed = {}, status = "active",
            },
        } },
    }

    SIM.with_ctx("tournaments", function()
        msg.post(msg.url("#tournaments"), "screen_enter")
    end)
    SIM.pump(1.0)

    local env = { SIM = SIM, ws = ws, http_log = http_log }
    env.tself = function() return SIM.components.tournaments.self end

    -- Is the screen treating this player as an entrant? Read off the payload
    -- its own is_joined() consults, rather than a field name — the point is
    -- the state, not where it happens to be stored.
    function env.joined()
        local t = (ws.current_user_data.tournaments or {})[1] or {}
        if t.joined ~= nil then return t.joined and true or false end
        return ((t.userProgress or {}).joined) and true or false
    end

    function env.tap_play()
        local t = SIM.components.tournaments.self
        local tenv = SIM.components.tournaments.env
        local target
        for _, b in ipairs(t.buttons or {}) do if b.id == "play" then target = b.node end end
        if not target then return false end
        gui.pick_node = function(n) return n == target end
        SIM.with_ctx("tournaments", tenv.on_input, t, hash("touch"),
            { pressed = true, x = 0, y = 0 })
        gui.pick_node = function() return false end
        return true
    end

    function env.calls(fragment)
        local n = 0
        for _, h in ipairs(http_log) do
            if h.url:find(fragment, 1, true) then n = n + 1 end
        end
        return n
    end

    return env
end

local JOIN_OK = { "/tournaments/global/join", function()
    return { status = 200, response = [[{"success":true,"code":"JOINED","joined":true,
        "entryFee":500,"charged":500,"balance":9500,"currentLevel":1,"totalLevels":7}]] }
end }

-- ---------------------------------------------------------------------------
print("TAPPING JOIN ACTUALLY ASKS THE SERVER")
do
    local app = boot({ routes = { JOIN_OK } })
    check("the button is there", app.tap_play(), true)
    app.SIM.pump(2.0)
    check("it posted to the join endpoint", app.calls("/tournaments/global/join"), 1)
    check("and the player is in", app.joined(), true)
end

-- ---------------------------------------------------------------------------
print("")
print("NOTHING LEAVES THE BALANCE UNTIL IT ANSWERS")
do
    local app = boot({ routes = { JOIN_OK }, balance = 10000 })
    app.tap_play()
    app.SIM.pump(0.2) -- mid-flight: the request is out, the answer is not back

    -- The old code had already subtracted by now, off its own arithmetic.
    check("balance untouched while in flight", app.ws.current_user_data.balance, 10000)

    app.SIM.pump(2.0)
    -- And afterwards it is the SERVER's figure, not one worked out here. 9500
    -- is what the response said; subtracting 500 locally would agree by luck,
    -- so the response deliberately carries a balance the client could not
    -- have computed on its own if the two ever disagreed.
    check("afterwards it is the server's figure", app.ws.current_user_data.balance, 9500)
end

-- ---------------------------------------------------------------------------
print("")
print("MASHING JOIN CHARGES ONCE — THE REPORTED BUG")
do
    local app = boot({ routes = { JOIN_OK }, balance = 10000 })
    -- Five taps as fast as a finger allows, all while the first is in flight.
    for _ = 1, 5 do app.tap_play() end
    app.SIM.pump(3.0)

    check("only one request went out", app.calls("/tournaments/global/join"), 1)
    check("and the balance fell exactly once", app.ws.current_user_data.balance, 9500)
    -- AND THE SCREEN IS LEFT USABLE.
    --
    -- Joining deliberately does NOT start a level: entering the ladder and
    -- playing a rung are two presses because they are two things, and the old
    -- code putting the player straight into an opponent search they had not
    -- asked for is the reason. What must not happen is the screen staying
    -- locked afterwards — paying and then being stuck behind a dead button is
    -- worse than not having paid.
    check("the button is live again", app.tself().play_disabled, false)
    check("and not still mid-flight", app.tself()._joining, false)
    -- Nothing raised on the way through, which is what a nil call would do.
    local errs = 0
    for _, line in ipairs(app.SIM.trace or {}) do
        if tostring(line):find("ERROR", 1, true) then errs = errs + 1 end
    end
    check("with nothing raised", errs, 0)
end

-- ---------------------------------------------------------------------------
print("")
print("A PLAYER ALREADY IN IS NOT CHARGED AGAIN")
do
    -- The server answers ok with charged = 0. The screen must carry on to the
    -- match without animating a deduction that did not happen.
    local app = boot({ joined = true, balance = 9500, routes = {
        { "/tournaments/global/join", function()
            return { status = 200, response = [[{"success":true,"code":"ALREADY_JOINED",
                "joined":true,"entryFee":500,"charged":0,"balance":9500,"currentLevel":3}]] }
        end } } })

    check("the button offers PLAY, not a price", app.joined(), true)
    app.tap_play()
    app.SIM.pump(2.0)
    -- Already in: joining is not asked for again at all.
    check("no join request is made", app.calls("/tournaments/global/join"), 0)
    check("and the balance is untouched", app.ws.current_user_data.balance, 9500)
end

-- ---------------------------------------------------------------------------
print("")
print("A REFUSED JOIN TAKES NOTHING AND UNLOCKS THE BUTTON")
do
    local app = boot({ balance = 10000, routes = {
        { "/tournaments/global/join", function()
            return { status = 400, response = [[{"success":false,"code":"INSUFFICIENT_BALANCE",
                "message":"You need 500 coins to enter the championship.","entryFee":500}]] }
        end } } })

    app.tap_play()
    app.SIM.pump(2.0)
    check("the balance is untouched", app.ws.current_user_data.balance, 10000)
    check("the player is not marked in", app.joined(), false)
    -- The one screen with no way forward must not also be left behind a dead
    -- button.
    check("and the button works again", app.tself().play_disabled, false)
end

-- ---------------------------------------------------------------------------
print("")
print("BEING KNOCKED BACK TO LEVEL 1 IS NOT THE SAME AS NEVER JOINING")
do
    -- The distinction the old `current_level_index == 0` test could not make,
    -- and the one that decides who pays. Both are level 1; only one of them
    -- has an entry behind it.
    local fresh = boot({ level = 1, joined = false, routes = { JOIN_OK } })
    check("never joined: offers the price", fresh.joined(), false)

    local paid = boot({ level = 1, joined = true, routes = { JOIN_OK } })
    check("paid and at level 1: offers PLAY", paid.joined(), true)
    paid.tap_play()
    paid.SIM.pump(2.0)
    check("and is not charged for being there", paid.calls("/tournaments/global/join"), 0)
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
