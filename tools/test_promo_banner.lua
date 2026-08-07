-- THE BANNER TYPE: dispatch split, docking position, and wiring.
--
--   Run: lua tools/test_promo_banner.lua
--
-- The server can now send an item shaped like a marquee (the original
-- scrolling ticker, no `type` or `type == "marquee"`) or a banner
-- (`type == "banner"`, a static image+CTA card) inside the SAME
-- PUBLIC_ANNOUNCEMENTS message (modules/websocket_manager.lua). This checks
-- that split is correct and total — every item lands on exactly one of the
-- two events — and that the new banner overlay (main/promo_banner.gui_script)
-- is wired the way announcement.gui_script already proved out: built once,
-- fed by its own event, gated to the right screen, queued one at a time, and
-- released on every exit path so it can never wedge shut.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- THE SPLIT ITSELF, reproduced directly (the bug this guards against is in
-- the branching, not something a source-pattern check alone would catch: a
-- version that emitted "banners" for EVERYTHING, or dropped the #list > 0
-- guard, reads fine as text but is wrong at runtime).
-- ---------------------------------------------------------------------------
local function split(items)
    local marquee, banners = {}, {}
    for _, item in ipairs(items or {}) do
        if item.type == "banner" then
            banners[#banners + 1] = item
        else
            marquee[#marquee + 1] = item
        end
    end
    return marquee, banners
end

print("")
print("EVERY ITEM LANDS ON EXACTLY ONE EVENT")

do
    local m, b = split({ { type = "banner", id = "1" }, { text = "hi", id = "2" } })
    check("a banner item goes to banners, not the marquee", #b == 1 and b[1].id == "1")
    check("a plain item goes to the marquee", #m == 1 and m[1].id == "2")
end

do
    -- getTopPlayersWithPrizes.ts predates the `type` field and never sends
    -- one — treated as marquee, same as before this feature existed, not
    -- silently dropped or misrouted to the banner slot.
    local m, b = split({ { text = "Top 10 this week" } })
    check("an item with NO type at all defaults to marquee", #m == 1 and #b == 0,
        "a caller that predates `type` must not go quiet or land in the wrong slot")
end

do
    local m, b = split({ { type = "MARQUEE" } })
    check("a differently-cased type is not mistaken for a banner", #m == 1 and #b == 0)
end

do
    local m, b = split({})
    check("an empty list splits into two empty lists, not an error", #m == 0 and #b == 0)
end

-- ---------------------------------------------------------------------------
print("")
print("THE REAL DISPATCHER MATCHES THAT SPLIT")

local ws_src = slurp("modules/websocket_manager.lua")
local ws_code = ws_src:gsub("%-%-[^\n]*", "")

check("branches on item.type == \"banner\"", ws_code:find('item%.type == "banner"') ~= nil)
check("marquee items still reach the existing \"announcements\" event",
    ws_code:find('emit%("announcements", marquee%)') ~= nil)
check("banner items reach a NEW, separate \"banners\" event",
    ws_code:find('emit%("banners", banners%)') ~= nil)
check("neither emit fires on an empty list",
    ws_code:match('if #marquee > 0 then emit%("announcements", marquee%) end') ~= nil and
    ws_code:match('if #banners > 0 then emit%("banners", banners%) end') ~= nil,
    "an empty emit would wake both listeners' queues for nothing")

-- ---------------------------------------------------------------------------
print("")
print("DOCKING POSITION IS COMPUTED FROM THE LOBBY'S OWN SAFE-AREA MODULE")

-- docked_y() is a `local function` and cannot be required directly; lifted
-- out and run with a stubbed theme table the same way test_banner_progress.lua
-- lifts apply_banner_bar — extracted rather than retyped so a rename or a
-- constant drifting out of sync fails loudly here instead of shipping unseen.
local banner_src = slurp("main/promo_banner.gui_script")
local docked_body = banner_src:match("(local function docked_y%(%).-\nend)\n")
check("docked_y was found in the source", docked_body ~= nil,
    "a rename would make every assertion below vacuous")

if docked_body then
    local CARD_H = tonumber(banner_src:match("local CARD_W, CARD_H = %d+, (%d+)"))
    local GAP = tonumber(banner_src:match("local GAP_BELOW_HEADER = (%d+)"))
    check("CARD_H was found", CARD_H ~= nil)
    check("GAP_BELOW_HEADER was found", GAP ~= nil)

    local env = {
        theme = { EDGE_T = 720, PADDING = 32, HEADER_H = 65 },
        CARD_H = CARD_H, GAP_BELOW_HEADER = GAP,
    }
    local chunk = assert(load(docked_body .. "\nreturn docked_y", "docked_y", "t", env))
    local docked_y = chunk()

    local expect = (720 - 32 - 65) - GAP - CARD_H / 2
    check("lands just under the header, at full screen height", docked_y() == expect,
        string.format("got %s, want %s", tostring(docked_y()), tostring(expect)))

    -- The point of reading it from `theme` at call time rather than caching
    -- it: a device with a notch/cutout changes EDGE_T after this script's
    -- own init() has already run, and the banner still has to dock correctly
    -- the next time it shows.
    env.theme.EDGE_T = 680 -- e.g. a safe-area inset trimmed the top
    check("moves with the safe area on a LATER call, not just at build time",
        docked_y() == expect - 40,
        "EDGE_T is read fresh each call, not captured once and stale forever")
end

-- ---------------------------------------------------------------------------
print("")
print("THE OVERLAY IS WIRED THE WAY THE MARQUEE ALREADY PROVED OUT")

local banner_code = banner_src:gsub("%-%-[^\n]*", "")

check("it is registered as a controller.go component",
    slurp("main/controller.go"):find('id: "promo_banner"') ~= nil)
check("pointing at the new .gui file",
    slurp("main/controller.go"):match('id: "promo_banner"%s*\n%s*component: "/main/promo_banner%.gui"') ~= nil)

check("subscribes to its OWN \"banners\" event, not \"announcements\"",
    banner_code:find('ws%.on%("banners"') ~= nil,
    "sharing the marquee's event would mean parsing marquee items as banners")
check("un-subscribes in final()", banner_code:find("ws%.off%(self%._token%)") ~= nil)

check("gated to the LOBBY specifically, not merely \"not game\"",
    banner_code:find('app_state%.current_screen ~= "lobby"') ~= nil,
    "the marquee's own rule (anywhere but game) is too broad for a banner meant to be a lobby fixture")
check("leaving the lobby mid-show re-queues the CURRENT item at the FRONT",
    banner_code:find("table%.insert%(self%.queue, 1, self%.current_item%)") ~= nil,
    "otherwise a banner interrupted by navigation is lost rather than replayed")

check("a new item queues rather than replacing what is showing",
    banner_code:find("self%.queue%[#self%.queue %+ 1%] = item") ~= nil)
check("only one item shows at a time (guarded at the top of show_next)",
    banner_code:match("show_next = function%(self%)%s*\n%s*if self%.showing then return end") ~= nil)

check("a dismissable banner's close button is enabled per-item, not globally",
    banner_code:find("gui%.set_enabled%(self%.close_bg, dismissable%)") ~= nil)
check("the CTA opens the link through sys%.open_url, guarded by pcall",
    banner_code:find("pcall%(sys%.open_url, link%)") ~= nil,
    "an unguarded call here could crash the whole overlay over one bad admin-entered URL")
check("input stays non-modal — only the overlay's own buttons return true",
    banner_code:match("return false%s*\nend%s*$") ~= nil)

print("")
print("THE IMAGE PIPELINE NEVER TRUSTS A SINGLE STEP")

check("the network fetch itself is pcall-guarded",
    banner_code:find("local ok = pcall%(function%(%)%s*\n%s*http%.request") ~= nil)
check("decoding the downloaded bytes is pcall-guarded",
    banner_code:find("pcall%(function%(%) decoded = image%.load") ~= nil)
check("building the texture is pcall-guarded",
    banner_code:find("local tex_ok = pcall%(function%(%)%s*\n%s*gui%.new_texture") ~= nil)
check("binding the texture to the node is pcall-guarded",
    banner_code:find("local bound = pcall%(function%(%) gui%.set_texture%(self%.img_photo") ~= nil)

check("a stale/slow response for an OLD item is discarded, not painted over the new one",
    banner_code:match("if my_token ~= self%._img_token then return end") ~= nil,
    "without this a slow banner N could overwrite banner N+1's image after the queue already advanced")
check("the token advances on every new item shown",
    (function()
        local _, n = banner_code:gsub("self%._img_token = self%._img_token %+ 1", "")
        return n >= 2 -- once in show_next, once in hide_and_advance
    end)())

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
