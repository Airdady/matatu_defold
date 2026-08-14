-- FROM A HANDSET THE BACKEND HAS NEVER SEEN, TO A PLAYABLE ACCOUNT.
--
--   Run: lua tools/test_phone_signup_flow.lua
--
-- Reported: "for the phone number input, when I punch in the phone number it
-- still doesn't redirect me to the profile creation where we have username and
-- avatar selector."
--
-- Two different first launches share this one screen, and both ended somewhere
-- they should not have:
--
--   MATATU   /auth/device answers 404 DEVICE_UNKNOWN, so the number is the
--            sign-in. It worked, the server said yes — and the screen stayed
--            on the keypad, because it re-derived which step to show from
--            `phoneNumber` in the response payload rather than from the fact
--            that the request had succeeded. A response that did not carry the
--            field back (the builder strips keys it has no value for, an
--            account matched on a secondary number answers with a different
--            default, a degraded build returns a bare row) put the player
--            straight back where they started, with no error to explain it and
--            no way to make retyping it help.
--
--   WHOT     there is no phone step at all — Nigeria has no mobile-money
--            identity check to run against a number, so asking for one buys
--            nothing (app_state.phone_required). That part was already right.
--            What was not: the username/avatar screen it goes to instead had
--            nowhere to save. /auth/device signs in but deliberately never
--            creates, so there was no account id, and update_profile refused
--            its own request with "User ID required".
--
-- This drives the REAL controller.script and profile.gui_script through the
-- headless runtime in tools/defold_sim.lua, taps the REAL buttons the screen
-- builds, and answers scripted HTTP. Nothing here asserts against source text.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- ── one full app boot, with a scripted backend ──────────────────────────────
--
-- Everything is reloaded per case: controller.script, the gui script and every
-- module keep state in file locals (the socket's reconnect budget, the cached
-- session, the module-level `identify_ok`) with no public way to reset it, so
-- a case that ended mid-flight would otherwise hand its state to the next one.
local function boot(opts)
    opts = opts or {}

    for name in pairs(package.loaded) do
        if name:match("^modules%.") or name == "tools.defold_sim" then
            package.loaded[name] = nil
        end
    end
    package.path = ROOT .. "?.lua;" .. package.path

    local SIM = dofile(ROOT .. "tools/defold_sim.lua")
    SIM.install_gui_stub()

    -- The build-time game switch, chosen per case instead of per build.
    --
    -- The phone rules are the REAL ones from modules/game_mode.lua rather than
    -- invented here: the keypad's digit cap and the CONTINUE button's enable
    -- both come off them, so a stub that got them wrong would test a keypad
    -- this app does not ship.
    local GAME = opts.game or "MATATU"
    local PHONE = {
        MATATU = { code = "256", digits = 9,  pattern = "^[73]%d%d%d%d%d%d%d%d$",     country = "Uganda"  },
        WHOT   = { code = "234", digits = 10, pattern = "^[789][01]%d%d%d%d%d%d%d%d$", country = "Nigeria" },
        KADI   = { code = "254", digits = 9,  pattern = "^[71]%d%d%d%d%d%d%d%d$",     country = "Kenya"   },
    }
    local ph = PHONE[GAME]
    package.loaded["modules.game_mode"] = {
        GAME = GAME,
        PATH = (GAME == "WHOT") and "whot" or ((GAME == "KADI") and "kadi" or "matatu"),
        BRAND = "Test", TITLE = "TEST", TAGLINE = "", BOT = "Test Bot",
        COUNTRY = ph.country, CURRENCY_CODE = "UGX", CURRENCY_SYMBOL = "UGX",
        PHONE_COUNTRY_CODE = ph.code,
        PHONE_PLACEHOLDER = "",
        PHONE_DIGITS = ph.digits,
        PHONE_PATTERN = ph.pattern,
        phone_valid = function(digits)
            return type(digits) == "string" and digits:match(ph.pattern) ~= nil
        end,
        DEFAULT_STAKE_AMOUNT = 200,
        def = function() return { how_to = {}, specials = {} } end,
        is_whot   = function() return GAME == "WHOT" end,
        is_matatu = function() return GAME == "MATATU" end,
        is_kadi   = function() return GAME == "KADI" end,
    }

    _G.window.set_listener = function() end
    _G.window.set_dim_mode = function() end
    _G.window.DIMMING_OFF = 0
    _G.window.WINDOW_EVENT_FOCUS_GAINED = 1
    _G.window.WINDOW_EVENT_FOCUS_LOST = 2
    _G.sys.get_config_string = function() return "" end
    _G.sys.get_config = function() return "" end

    local http_log = {}
    _G.http = {
        request = function(url, method, cb, headers, body, options)
            http_log[#http_log + 1] = { url = url, method = method, body = body }
            -- Longest pattern wins, so "/auth/device/profile" is not swallowed
            -- by the "/auth/device" entry that every case registers.
            local handler, best = nil, -1
            for _, route in ipairs(opts.routes or {}) do
                if url:find(route[1], 1, true) and #route[1] > best then
                    handler, best = route[2], #route[1]
                end
            end
            local resp = handler and handler(body, method)
                or { status = 404, response = '{"success":false}' }
            local ctx = SIM.current_ctx
            timer.delay(0.1, false, function() SIM.with_ctx(ctx, cb, nil, nil, resp) end)
        end,
    }

    -- Every sibling the controller posts to. Only the two under test run real
    -- code; the rest just have to exist so nothing is dropped on the floor.
    for _, id in ipairs({ "lobby", "auth", "themes", "payments",
                          "tournaments", "team_tournament", "standings", "game",
                          "game_logic", "coins", "signup_bonus", "daily_bonus",
                          "network", "incoming", "gameover", "update_required",
                          "toast", "announcement", "season_results", "tutorial",
                          "suit_select", "card_factory" }) do
        SIM.add_recorder(id)
    end
    SIM.load_script_component("controller", ROOT .. "main/controller.script")
    SIM.load_script_component("profile", ROOT .. "main/profile.gui_script")
    -- The online screen is loaded for real only when a case asks, because it
    -- is the heaviest of them and most cases never look at it.
    if opts.with_online then
        SIM.load_script_component("online", ROOT .. "main/online.gui_script")
    else
        SIM.add_recorder("online")
    end
    SIM.init_component("controller")
    SIM.init_component("profile")
    if opts.with_online then SIM.init_component("online") end
    SIM.pump(3.0)

    local env = {
        SIM = SIM,
        http_log = http_log,
        ws = require("modules.websocket_manager"),
        screen = function() return SIM.components.controller.self.screen end,
        step = function() return SIM.components.profile.self.step end,
        pself = function() return SIM.components.profile.self end,
    }

    -- Press a button the screen ACTUALLY built, through its own on_input.
    function env.tap(id)
        local pself = SIM.components.profile.self
        local penv = SIM.components.profile.env
        local target
        for _, b in ipairs(pself.buttons or {}) do
            if b.id == id then target = b.node end
        end
        if not target then return false end
        gui.pick_node = function(n) return n == target end
        SIM.with_ctx("profile", penv.on_input, pself, hash("touch"),
            { pressed = true, x = 0, y = 0 })
        gui.pick_node = function() return false end
        SIM.pump(0.2)
        return true
    end

    function env.type_digits(s)
        local all = true
        for d in s:gmatch(".") do all = env.tap("p_" .. d) and all end
        return all
    end

    function env.type_username(s)
        local all = true
        for c in s:gmatch(".") do all = env.tap("k_" .. c:upper()) and all end
        return all
    end

    -- Is this text actually DRAWN on the card, rather than only toasted?
    -- A toast is bottom-left and gone in three seconds; these screens cannot
    -- be left, so a refusal the player does not happen to catch is
    -- indistinguishable from the app doing nothing.
    function env.on_screen(fragment, comp)
        for _, n in ipairs(SIM.components[comp or "profile"].self.nodes or {}) do
            if type(n) == "table" and type(n.text) == "string"
               and n.text:find(fragment, 1, true) then
                return true
            end
        end
        return false
    end

    -- The text node drawn straight after `label` — the info card lays its
    -- stats out as a caption ("BAL.") followed by its figure, so this is how
    -- to read what the player sees next to a heading rather than merely
    -- somewhere on the screen.
    function env.rendered_after(label, comp)
        local nodes = SIM.components[comp or "online"].self.nodes or {}
        local found = false
        for _, n in ipairs(nodes) do
            if type(n) == "table" and type(n.text) == "string" and n.text ~= "" then
                if found then return n.text end
                if n.text == label then found = true end
            end
        end
        return nil
    end

    -- What the signup-bonus screen was told, if anything.
    function env.bonus_shown()
        for _, r in ipairs(SIM.components.signup_bonus.received or {}) do
            if r.mid == hash("show_signup_bonus") then return (r.msg or {}).amount end
        end
        return nil
    end

    -- `method` is optional: one URL can carry two verbs with very different
    -- meanings (PUT /users/:id saves a profile, GET /users/:id describes an
    -- account), so an assertion about one must be able to say which.
    function env.called(fragment, method)
        for _, h in ipairs(http_log) do
            if h.url:find(fragment, 1, true) and (not method or h.method == method) then
                return true
            end
        end
        return false
    end

    return env
end

local DEVICE_UNKNOWN = { "/auth/device", function()
    return { status = 404, response =
        '{"success":false,"message":"No account on this device yet.","code":"DEVICE_UNKNOWN"}' }
end }

-- ---------------------------------------------------------------------------
print("MATATU: AN UNKNOWN HANDSET IS ASKED FOR A NUMBER")
do
    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN } })
    check("the phone screen is what opens", app.screen(), "profile")
    check("on the keypad step", app.step(), "phone")
    -- Not "link": there is no session to link a number TO. The distinction is
    -- what puts a way out on the screen — in link mode this is the first thing
    -- a fresh install sees and has no exit at all.
    check("in sign-in mode, with a way back", app.pself().phone_mode, "login")
    check("and it did ask the backend first", app.called("/auth/device"), true)
end

-- ---------------------------------------------------------------------------
print("")
print("MATATU: THE NUMBER GOES IN AND THE PROFILE SCREEN COMES UP")
do
    -- The payload deliberately carries NO phoneNumber. That is the shape that
    -- used to strand the player: the sign-in plainly worked, and the screen
    -- asked the payload rather than the outcome.
    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN,
        { "/auth/phone", function()
            return { status = 200, response = [[{"success":true,"isNewUser":true,
                "matchedBy":"phone","token":"tok-1",
                "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8d9","accountId":9001,"balance":500}}]] }
        end } } })

    check("typed all nine digits", app.type_digits("712345678"), true)
    check("the field holds them", app.pself().phone, "712345678")
    check("CONTINUE is on screen", app.tap("phone_link"), true)
    app.SIM.pump(3.0)

    check("it signed in by number", app.called("/auth/phone"), true)
    check("no error was raised", tostring(app.pself()._phone_error), "nil")
    check("the keypad is gone", app.step(), "profile")
    check("and this is the username/avatar screen", app.screen(), "profile")
    -- The number is written onto the cached account even though the response
    -- never mentioned it — the server found or created the account BY it, so
    -- it is a fact, and phone_complete reads exactly this field.
    check("the number is remembered locally",
        (app.ws.current_user_data or {}).phoneNumber, "0712345678")
    -- The backend credits the welcome bonus at creation. Nothing told the
    -- player: the celebration screen was only ever posted to from the
    -- /auth/device path, which creates nothing and answers isNewUser:false
    -- every time, so the trigger sat on the one route that could never fire
    -- it. The coins arrived and nobody was ever told.
    check("and the welcome bonus is announced", app.bonus_shown(), 500)
end

-- ---------------------------------------------------------------------------
print("")
print("MATATU: THE SAME THING, WITH THE SOCKET TALKING BACK")
do
    -- The case above answers HTTP and leaves the socket silent, which is not
    -- what a real launch looks like. A fresh install opens a socket and
    -- IDENTIFYs by device id BEFORE anybody types anything, the server answers
    -- IDENTIFY_UNKNOWN, and then the account's own IDENTIFY lands a second or
    -- two AFTER the sign-in — merging a whole user payload over
    -- ws.current_user_data on the way past.
    --
    -- The payload here is the shape handleNearbyPlayers actually produces for
    -- a brand-new account: it deletes undefined keys, so there is no
    -- `username` and no `avatar` in it at all.
    local NEW_USER = [[{"_id":"64b7f9a1c2d3e4f5a6b7c8d9","accountId":9001,"names":"Ada Bem",
        "phoneNumber":"0712345678","balance":500,"points":0,"rank":[],"position":1,
        "gamesPlayed":0,"recentForm":[],"winRate":0,"savingCoins":0,"badges":[],
        "themes":[],"tournaments":[],"myBattles":[],"payments":[],"prizes":[],
        "teamInvitations":[],"isBlocked":false}]]

    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN,
        { "/auth/phone", function()
            return { status = 200, response =
                '{"success":true,"isNewUser":true,"matchedBy":"phone","token":"tok-1","user":'
                .. NEW_USER .. '}' }
        end } } })

    -- The boot socket's device-only IDENTIFY, answered.
    app.SIM.server_send({ type = "IDENTIFY_UNKNOWN",
        data = { message = "No account is associated with this device yet." } })
    app.SIM.pump(2.0)
    check("that alone does not throw the player off the screen", app.screen(), "profile")
    check("still asking for the number", app.step(), "phone")

    app.type_digits("712345678")
    app.tap("phone_link")
    app.SIM.pump(2.0)
    check("the keypad is done", app.step(), "profile")

    -- ...and now the account's real IDENTIFY arrives and merges over the
    -- cached user. It carries no username, so nothing here should re-open the
    -- phone step behind the player.
    app.SIM.server_send({ type = "IDENTIFY", data = {
        _id = "64b7f9a1c2d3e4f5a6b7c8d9", accountId = 9001, names = "Ada Bem",
        phoneNumber = "0712345678", balance = 500, points = 0, rank = {}, position = 1,
        gamesPlayed = 0, winRate = 0, savingCoins = 0, badges = {}, themes = {},
        tournaments = {}, myBattles = {}, payments = {}, prizes = {}, teamInvitations = {},
    } })
    app.SIM.pump(5.0)
    check("and it stays done after IDENTIFY lands", app.step(), "profile")
    check("on the profile screen", app.screen(), "profile")
    check("with the username still unchosen, which is the point",
        tostring((app.ws.current_user_data or {}).username), "nil")
end

-- ---------------------------------------------------------------------------
print("")
print("MATATU: A NUMBER THAT ALREADY HAS AN ACCOUNT JUST LOGS IN")
do
    -- Complete account, so there is nothing left to fill in and the profile
    -- screen must not detain them.
    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN,
        { "/auth/phone", function()
            return { status = 200, response = [[{"success":true,"isNewUser":false,
                "matchedBy":"phone","token":"tok-2",
                "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8d9","username":"Scovia","avatar":12,
                        "phoneNumber":"0712345678","balance":4200}}]] }
        end } } })

    app.type_digits("712345678")
    app.tap("phone_link")
    app.SIM.pump(3.0)

    check("straight past the profile screen", app.screen(), "online")
    check("their balance came back", (app.ws.current_user_data or {}).balance, 4200)
    check("and their name", (app.ws.current_user_data or {}).username, "Scovia")
    -- isNewUser:false. Congratulating a returning player on signing up, over
    -- a balance that is their own money, would be worse than saying nothing.
    check("and no welcome bonus is claimed for them",
        tostring(app.bonus_shown()), "nil")
end

-- ---------------------------------------------------------------------------
print("")
print("MATATU: A STALE SESSION FALLS THROUGH TO SIGNING IN")
do
    -- is_logged_in() only asks whether a user id is CACHED, which is a guess
    -- about the token beside it. When the guess is wrong the submit goes to
    -- /auth/link-phone, which needs a Bearer token, and can only answer 401 —
    -- leaving the player on the one screen with no way out, holding the one
    -- button that does not work. The number they typed is not our bookkeeping
    -- problem: it becomes an account either way.
    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN,
        { "/auth/link-phone", function()
            return { status = 401, response = '{"success":false,"message":"Invalid token"}' }
        end },
        { "/auth/phone", function()
            return { status = 200, response = [[{"success":true,"isNewUser":true,
                "matchedBy":"phone","token":"tok-4",
                "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8dB","accountId":9003,"balance":500}}]] }
        end } } })

    -- A cached id with a token the backend no longer honours.
    app.ws.current_user_data = { _id = "64b7f9a1c2d3e4f5a6b7c8dC", username = "" }
    app.SIM.components.controller.self.screen = "profile"
    app.SIM.with_ctx("controller", app.SIM.components.controller.on_message,
        app.SIM.components.controller.self, hash("link_phone"),
        { phoneNumber = "0712345678" })
    app.SIM.pump(3.0)

    check("it tried to link first", app.called("/auth/link-phone"), true)
    check("then signed in when the session was refused", app.called("/auth/phone"), true)
    check("and the player has an account", (app.ws.current_user_data or {})._id,
        "64b7f9a1c2d3e4f5a6b7c8dB")
    check("on the profile screen", app.screen(), "profile")
    check("at the username step", app.step(), "profile")
end

-- ---------------------------------------------------------------------------
print("")
print("MATATU: A REFUSED NUMBER SAYS SO AND STAYS PUT")
do
    -- The other half of the fix: moving on must still be conditional on the
    -- request SUCCEEDING. A rejection has to keep the keypad up.
    local app = boot({ game = "MATATU", routes = { DEVICE_UNKNOWN,
        { "/auth/phone", function()
            return { status = 400, response =
                '{"success":false,"message":"This identity has been suspended."}' }
        end } } })

    app.type_digits("712345678")
    app.tap("phone_link")
    app.SIM.pump(3.0)

    check("still on the keypad", app.step(), "phone")
    check("with the reason shown", app.pself()._phone_error, "This identity has been suspended.")
    check("and not stuck mid-save", app.pself()._phone_saving, false)
    -- ON THE CARD, not only in a toast that is gone in three seconds. This is
    -- how a backend refusal came to be reported as "I punch in the number and
    -- nothing happens": the app answered somewhere the player was not looking.
    check("printed on the card the player is looking at",
        app.on_screen("This identity has been suspended."), true)
    -- And the local format check must stop contradicting it. Nine valid-looking
    -- digits still satisfy validate_phone, so this line went on saying "Looks
    -- good!" about the number that had just been rejected.
    check("and not still claiming the number looks good", app.on_screen("Looks good!"), false)
    -- CONTINUE has to work again, or the only screen with no way out is also
    -- the only screen with no working button.
    check("CONTINUE is live again", app.tap("phone_link"), true)
end

-- ---------------------------------------------------------------------------
print("")
print("WHOT: NO NUMBER IS ASKED FOR AT ALL")
do
    local app = boot({ game = "WHOT", routes = { DEVICE_UNKNOWN,
        { "/auth/device/profile", function()
            return { status = 200, response = [[{"success":true,"isNewUser":true,
                "matchedBy":"device","token":"tok-3",
                "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8dA","username":"Chidi","avatar":1,
                        "accountId":9002,"balance":200}}]] }
        end } } })

    check("the same unknown handset lands on the profile screen", app.screen(), "profile")
    check("but on the username/avatar step", app.step(), "profile")
    check("there is no keypad to press", app.tap("p_7"), false)
    check("and no CONTINUE button either", app.tap("phone_link"), false)

    check("typed a username", app.type_username("Chidi"), true)
    check("it reads back", app.pself().username, "Chidi")
    check("SAVE is on screen", app.tap("save"), true)
    app.SIM.pump(3.0)

    -- The whole point: this save had no account id to PUT to, and used to be
    -- refused by the client before it left the handset.
    check("it created the account by device id", app.called("/auth/device/profile"), true)
    -- The save must not go through update_profile, which needs an account id
    -- this player does not have yet. A GET to the same path afterwards is a
    -- different thing entirely — that is refresh_account asking what the
    -- account it just created looks like.
    check("nothing was PUT to /users/", app.called("/users/", "PUT"), false)
    check("no phone endpoint was touched", app.called("/auth/phone"), false)
    check("and the player is online", app.screen(), "online")
    check("signed in as themselves", (app.ws.current_user_data or {}).username, "Chidi")
    -- Whot's ONLY signup route, so this is the only moment its welcome bonus
    -- can be announced — and 200 NGN, the figure the server actually sent,
    -- not Matatu's 500 UGX.
    check("with the welcome bonus announced", app.bonus_shown(), 200)
end

-- ---------------------------------------------------------------------------
print("")
print("WHOT: A REJECTED USERNAME IS REPORTED, NOT SWALLOWED")
do
    local app = boot({ game = "WHOT", routes = { DEVICE_UNKNOWN,
        { "/auth/device/profile", function()
            return { status = 400, response =
                '{"success":false,"message":"That username is already taken.",' ..
                '"error":"USERNAME_TAKEN","suggestions":["Chidi7","Chidi23"]}' }
        end } } })

    app.type_username("Chidi")
    app.tap("save")
    app.SIM.pump(3.0)

    check("still on the profile screen", app.screen(), "profile")
    check("the save is not left hanging", app.pself()._saving, false)
    check("the reason is shown", app.pself()._error, "That username is already taken.")
    check("printed on the card, not only toasted",
        app.on_screen("That username is already taken."), true)
    check("and not still claiming the name looks good", app.on_screen("Looks good!"), false)
    local app_state = require("modules.app_state")
    check("with alternatives to offer", #(app_state.username_suggestions or {}), 2)
end

-- ---------------------------------------------------------------------------
print("")
print("A BRAND-NEW ACCOUNT ARRIVES WITH ITS BALANCE AND POINTS")
do
    -- Reported: right after signing up, BAL and PTS read 0 on the online
    -- screen, and only a manual refresh fills them in.
    --
    -- The routes that BUILD an account are not the route that DESCRIBES one.
    -- /auth/phone answers with a snapshot taken mid-creation, and PUT
    -- /users/:id answers with findByIdAndUpdate's raw document — no rank, no
    -- position, no prizes, none of the computed fields the screen reads. So
    -- both payloads here deliberately carry no balance and no points, which is
    -- the worst case, and the screen must still end up showing the real
    -- figures without anybody touching anything.
    local app = boot({ game = "MATATU", with_online = true, routes = { DEVICE_UNKNOWN,
        { "/auth/phone", function()
            return { status = 200, response = [[{"success":true,"isNewUser":true,
                "matchedBy":"phone","token":"tok-5",
                "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8dD","accountId":9004,
                        "phoneNumber":"0712345678","names":"Ada Bem"}}]] }
        end },
        { "/users/", function(_, method)
            -- ONE URL, TWO VERBS, TWO VERY DIFFERENT ANSWERS.
            --
            -- PUT is updateUser: it replies with findByIdAndUpdate's raw
            -- mongoose document. Modelled faithfully here — the document has
            -- the account's own columns and none of the computed ones, so no
            -- rank, no position, and (as far as this screen is concerned) no
            -- usable balance or points.
            if method == "PUT" then
                return { status = 200, response = [[{"success":true,
                    "user":{"_id":"64b7f9a1c2d3e4f5a6b7c8dD","accountId":9004,
                            "username":"Ada","avatar":3,"phoneNumber":"0712345678",
                            "names":"Ada Bem","gamesPlayed":0,"gamesWon":0}}]] }
            end
            -- GET is getUser, which answers with the full handleNearbyPlayers
            -- payload — the same thing IDENTIFY carries, and the same thing
            -- the player was getting by refreshing by hand.
            return { status = 200, response = [[{"success":true,
                "_id":"64b7f9a1c2d3e4f5a6b7c8dD","accountId":9004,"username":"Ada","avatar":3,
                "balance":500,"points":12,"savingCoins":0,"rank":[],"position":1,
                "phoneNumber":"0712345678","names":"Ada Bem","themes":[]}}]] }
        end } } })

    app.type_digits("712345678")
    app.tap("phone_link")
    app.SIM.pump(2.0)
    app.type_username("Ada")
    app.tap("save")
    app.SIM.pump(4.0)

    check("the player is on the online screen", app.screen(), "online")
    check("and it asked what the account looks like", app.called("/users/", "GET"), true)
    check("the balance is known", (app.ws.current_user_data or {}).balance, 500)
    check("and the points", (app.ws.current_user_data or {}).points, 12)
    -- The figures the card is actually PAINTING, read from beside their own
    -- labels. Searching the whole screen for "500" is not good enough — the
    -- stake ladder draws that number too, so the assertion passed while the
    -- info card said 0.
    check("BAL reads the real balance", app.rendered_after("BAL."), "500")
    check("PTS reads the real points", app.rendered_after("PTS."), "12")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
