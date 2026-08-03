-- THE CLIENT AND THE SERVER MUST AGREE ABOUT THEMES.
--
--   Run: lua tools/test_theme_catalogue.lua
--
-- Reported: POST /themes/purchase answers { "error": "Theme not found or
-- inactive" }, and owned themes are never applied.
--
-- THREE THINGS HAVE TO LINE UP, AND ONLY ONE OF THEM IS OBVIOUS
--
--   the ids      what the client posts to /themes/purchase, what ownedThemeIds
--                and activeThemeId store, and what the client keys its own
--                artwork off. An id that exists on one side and not the other
--                is a theme that can be shown and never bought.
--   the names    what the player reads. The server said 'Default', 'Blue
--                Basic', 'Batman'; the client's fallback said 'Classic Red',
--                'Classic Blue', 'Dark Knight'. Whichever list happened to win
--                decided what was on screen, so the same theme had two names.
--   the prices   what is deducted. The client's fallback charged a flat 2000
--                for everything, matching nothing the server would take —
--                a player could be shown one number and charged another.
--
-- The server owns names and prices, because it is the side that deducts. The
-- client owns the ARTWORK — card sets, backs, backgrounds, accent colours are
-- atlas names and mean nothing to a backend. This checks the overlap.
--
-- It reads the TypeScript source directly. A duplicated table in a test is a
-- third opinion, and three lists that must agree are worse than two.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

vmath = { vector4 = function(a, b, c, d) return { a, b, c, d } end }

local app_state = require("modules.app_state")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- ── the server's catalogue, read from its own source ────────────────────────
local THEME_TS = "../../be_matatu/src/common/models/Theme.ts"
local f = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. THEME_TS)
if not f then
    print("SKIP: be_matatu is not checked out beside this repo")
    os.exit(0)
end
local ts = f:read("a"); f:close()

local block = ts:match("DEFAULT_THEMES_DATA%s*=%s*%[(.-)%]")
local server = {}
local server_order = {}
for line in (block or ""):gmatch("[^\n]+") do
    local id = line:match("id:%s*'([%w_]+)'")
    if id then
        server[id] = {
            name  = line:match("name:%s*'([^']+)'"),
            price = tonumber(line:match("price:%s*(%d+)")),
        }
        server_order[#server_order + 1] = id
    end
end

print(string.format("server catalogue: %d themes", #server_order))
check("it parsed at all", #server_order > 0, true)

print("")
print("EVERY ID EXISTS ON BOTH SIDES")
-- An id on the server that the client cannot draw is a theme somebody can buy
-- and never see. An id on the client that the server does not have is the
-- reported 404 exactly.
for _, id in ipairs(server_order) do
    check("client can draw " .. id, app_state.THEMES[id] ~= nil, true)
end
for _, id in ipairs(app_state.THEME_ORDER) do
    check("server sells " .. id, server[id] ~= nil, true)
end
check("and neither side has extras",
    #server_order, #app_state.THEME_ORDER)

print("")
print("THE PLAYER READS THE SAME NAME EITHER WAY")
-- The client's own label is what the offline fallback shows; the server's name
-- is what the payload shows. They are the same theme.
for _, id in ipairs(server_order) do
    local local_label = (app_state.THEMES[id] or {}).label
    check(id .. " is called the same thing", local_label, server[id].name)
end

print("")
print("AND IS QUOTED THE PRICE THAT WILL BE CHARGED")
-- The fallback used to say 2000 for every theme except default. The server
-- charges 0/500/500/1000/1500/2000, so five of the six were wrong.
for _, id in ipairs(server_order) do
    check(id .. " costs the same", app_state.THEME_PRICES[id], server[id].price)
end
check("default is free on both sides", app_state.THEME_PRICES.default, 0)

print("")
print("THE ARTWORK STAYS ON THE CLIENT")
-- Nothing here should ever end up in the backend catalogue: these are atlas
-- names, and a server that tried to own them would be guessing at a build it
-- cannot see.
for _, id in ipairs(app_state.THEME_ORDER) do
    local t = app_state.THEMES[id]
    check(id .. " has a card set", type(t.card_set), "string")
    check(id .. " has a card back", type(t.card_back), "string")
end
check("and the server carries none of it", ts:find("card_set", 1, true), nil)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
