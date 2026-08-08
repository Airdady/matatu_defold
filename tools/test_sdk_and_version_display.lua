-- MIN SDK 21, TARGET SDK 36, AND THE VERSION VISIBLE NEXT TO THE BRAND.
--
--   Run: lua tools/test_sdk_and_version_display.lua
--
-- Two unrelated requests landing together: keep minimum_sdk_version at 21
-- (it has flip-flopped between 21 and 23 several times in this project's
-- history — this pins the CURRENT, explicit instruction so a future "restore
-- the last known value" pass doesn't silently flip it back), add
-- target_sdk_version = 36 (there was none before), and show the app version
-- inline in the lobby header instead of only inside the support-email
-- diagnostic block.

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

print("game.project's [android] block")

local proj = slurp("game.project")
local android = proj:match("\n%[android%]\n(.-)\n%[")

check("the [android] section exists", android ~= nil)
if android then
    check("minimum_sdk_version is 21",
        android:match("\nminimum_sdk_version = 21\n") ~= nil or android:match("^minimum_sdk_version = 21\n") ~= nil,
        "explicit instruction, after this value has flip-flopped between 21 and 23 several times in history")
    check("target_sdk_version is 36",
        android:match("target_sdk_version = 36") ~= nil)
    check("version_code is still there and untouched by this change",
        android:match("version_code = %d+") ~= nil,
        "this is the value the Play In-App Update comparison depends on — see test_version_stamp.lua")
end

print("")
print("the lobby header shows the app's own version")

local lobby_src = slurp("main/lobby.gui_script")
local lobby_code = lobby_src:gsub("%-%-[^\n]*", "")

local rebuild_start = lobby_code:find("\nlocal function rebuild%(self%)")
check("rebuild(self) exists", rebuild_start ~= nil, "a rename would make everything below vacuous")

if rebuild_start then
    local header_end = lobby_code:find("Tile 1: PLAY ONLINE", rebuild_start)
    local header = lobby_code:sub(rebuild_start, header_end or (rebuild_start + 4000))

    check("requires config, to read the app's own version rather than a hardcoded string",
        header:find('require%("modules%.config"%)') ~= nil)
    check("sits on the subtitle line directly under the brand title, in the v<version> format that was asked for",
        header:find('"ONLINE CARD GAME  ·  v" %.%. tostring%(config%.APP_VERSION%)') ~= nil,
        "no glyph-metrics API exists here to place a new node flush after GameMode.TITLE without risking an overlap")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
