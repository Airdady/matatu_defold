-- ONE ICON, ONE LOGO, ONE COLOUR — ON EVERY PUSH THIS APP POSTS.
--
--   Run: lua tools/test_notification_icon.lua
--
-- Asked for: icon_notification.png used for all push notifications, the logo
-- shown on the right in the notification panel, and the same colour across
-- every game mode.
--
-- WHY THE APP AND NOT THE SERVER. The backend sends DATA-ONLY messages on
-- purpose (see notifications.ts): a payload carrying a `notification` block is
-- taken over by the FCM SDK whenever the app is backgrounded, which is exactly
-- when the Accept/Decline buttons matter and exactly when they disappeared. So
-- the icon, the logo and the colour are chosen HERE, in the service that
-- builds the notification, and there is nowhere else they could be set.
--
-- The bug this starts from: the icon lookup asked for "app_logo" and
-- "ic_launcher", and NEITHER is in bundle/android/res. Every push we have ever
-- sent fell through to android.R.drawable.ic_dialog_info — a stock grey (i) —
-- with nothing in any log to say so.
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

local svc = slurp("firebaseauth/src/MatatuFirebaseMessagingService.java")
local sh  = slurp("release.sh")

-- Comments are stripped wherever an assertion is about what the code DOES.
-- This file explains itself at length, and a plain search would happily match
-- the prose describing the thing instead of the thing.
local function code(s)
    return (s:gsub("/%*.-%*/", ""):gsub("//[^\n]*", ""))
end
local svc_code = code(svc)

print("")
print("THE STATUS-BAR ICON IS icon_notification")

check("it is looked for first, ahead of every fallback",
    svc_code:match('SMALL_ICON_NAMES%s*=%s*{%s*"icon_notification"'),
    "anything before it in the list wins instead")
check("and the fallbacks include a drawable that actually exists",
    svc_code:find('"icon"', 1, true),
    "app_logo and ic_launcher are not in the bundle - that is how this reached the Android default")
check("the old two-name lookup is gone",
    not svc_code:match('getIdentifier%("app_logo"'),
    "it resolved to nothing and fell through on every push")
check("and a fall-through to the Android default is logged, not silent",
    svc_code:match("Log%.w%(TAG,%s*\"No notification icon found"),
    "the failure mode was invisible, which is why it lasted")

print("")
print("THE LOGO SHOWS ON THE RIGHT")
check("a large icon is set",
    svc_code:find("setLargeIcon", 1, true),
    "nothing set one, so the right of every notification was empty")
check("on the SHARED builder, so every notification type gets it",
    -- Set once before the per-type branches. Set inside them and each new
    -- type has to remember, which is how "all notifications" stops being all.
    (svc_code:find("setLargeIcon", 1, true) or math.huge)
        < (svc_code:find('"GAME_REQUEST"%.equalsIgnoreCase') or 0),
    "set per type, the next type added silently has no logo")
check("and a logo that cannot be decoded does not stop the notification",
    svc_code:match("catch%s*%(Throwable[^\n]*\n[^\n]*notification logo"),
    "cosmetic failure must never swallow the message itself")

print("")
print("ONE COLOUR FOR EVERY GAME MODE")
local colors = {}
for hex in svc_code:gmatch("BRAND_COLOR%s*=%s*(0x%x+)") do colors[#colors+1] = hex end
check("BRAND_COLOR is defined exactly once",
    #colors == 1, "found " .. #colors .. " definitions")
check("and nothing picks a colour per game",
    not svc_code:match("GAME_UPPER") and not svc_code:match("BRAND_COLOR_[A-Z]"),
    "a per-target tint is four colours in the shade instead of one")
check("the notification is tinted with it",
    svc_code:find("setColor(BRAND_COLOR)", 1, true))
check("and so are the lights and the channels",
    svc_code:find("setLights(BRAND_COLOR", 1, true)
        and svc_code:find("setLightColor(BRAND_COLOR)", 1, true))

print("")
print("AND A MISSING ASSET IS NOT ALLOWED TO SHIP QUIETLY")
check("release.sh checks for it",
    sh:find("icon_notification.png", 1, true),
    "its absence is invisible until a player sees a grey (i)")
check("and says it must be a transparent silhouette",
    sh:find("ALPHA MASK", 1, true) or sh:find("TRANSPARENT BACKGROUND", 1, true),
    "from Android 5.0 a full-colour small icon renders as a white square")
-- A warning, not a failure: shipping without it is ugly, not broken, and the
-- launcher icon stands in. Asserted on what the block DOES — it warns and
-- never exits — rather than on a sentence, which is what the previous version
-- pinned and what broke the moment the wording improved.
local notif_block = sh:match("NOTIF_INSTALLED=(.-)\nfi")
check("as a warning rather than a hard stop",
    notif_block ~= nil
        and notif_block:find("print_warning", 1, true) ~= nil
        and notif_block:find("exit 1", 1, true) == nil,
    "blocking a release over a cosmetic asset is worse than the asset")

print("")
print("THE ASSET IS SHARED, AND IT REACHES THE BUNDLE")
local gen = slurp("tools/generate_android_icons.py")
check("the source lives in tools/icons, committed once",
    io.open(dir .. "../tools/icons/icon_notification.png", "rb") ~= nil,
    "the generator installs it; without the file there is nothing to install")
check("and the generator installs it at every density",
    gen:find("NOTIFICATION_DENSITIES", 1, true)
        and gen:find('"icon_notification.png"', 1, true),
    "@drawable/icon_notification does not resolve unless it is in the bundle")
check("installed, never generated per target",
    -- The launcher icon is per-target artwork. This one is the same mark in
    -- the shade for all four, so it must not be derived from ICON_SVG.
    gen:match("NOTIFICATION_SRC%s*=%s*os%.path%.join%(SCRIPT_DIR, \"icons\"") ~= nil,
    "deriving it per game gives four different notification icons")
check("at the sizes Android reserves for a small icon",
    gen:find('"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96', 1, true),
    "24dp base; anything larger is downscaled by the system and comes out soft")
check("and an opaque asset is called out before it ships",
    gen:find("has no transparency", 1, true),
    "a full-colour small icon looks right in a design tool and is a white square on a phone")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
