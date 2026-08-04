-- WHAT THE APP TELLS THE SERVER IT IS.
--
--   Run: lua tools/test_version_stamp.lua
--
-- game.project said 18.5.9 while modules/config.lua was stamped 20.9.2, and
-- config.lua PREFERS what the engine was bundled with:
--
--     local v = cfg("project.version")
--     if v ~= "" then M.APP_VERSION = v end
--
-- release.sh passes --settings to bob.jar, so a RELEASE carries the real
-- version and the stamped constant is never consulted. build.sh passes no
-- settings at all — it builds straight from the file in the repo — so every
-- build.sh build reported 18.5.9 no matter what config.lua said.
--
-- That is not cosmetic. The server's force-update gate compares what the
-- client reports against a floor, so a build that under-reports its version
-- can be refused and go quiet, and one that over-reports slips a gate that was
-- meant to catch it.
--
-- Both files now carry the same version, and release.sh stamps both.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end

local proj = slurp("game.project")
local cfg  = slurp("modules/config.lua")
local rel  = slurp("release.sh")

local proj_version = proj:match("\n?version = ([%d%.]+)")
local proj_code    = tonumber(proj:match("\nversion_code = (%d+)"))
local cfg_version  = cfg:match('M%.APP_VERSION = "([%d%.]+)"')
local cfg_code     = tonumber(cfg:match("M%.APP_BUILD%s*=%s*(%d+)"))

print("the two places a version lives agree")
check_true("game.project has a version", proj_version ~= nil, "not found")
check_true("and a version_code", proj_code ~= nil,
    "without one a plain build sends no build number at all")
check_true("config.lua has both", cfg_version ~= nil and cfg_code ~= nil, "not found")
check("version name matches", proj_version, cfg_version)
check("version code matches", proj_code, cfg_code)

print("")
print("and neither is the stale one that caused this")
check_true("game.project is no longer 18.5.9", proj_version ~= "18.5.9",
    "the value that under-reported every build.sh build")

-- Ordered comparison, so a later edit cannot go BACKWARDS unnoticed.
local function to_num(v)
    local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
    return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end
check_true("and is not older than the version that shipped broken",
    to_num(proj_version) > to_num("18.5.9"),
    "reported " .. tostring(proj_version))

print("")
print("release.sh keeps them from drifting again")
check_true("it stamps config.lua", rel:find("modules/config%.lua") ~= nil, "not stamped")
check_true("and game.project", rel:find("into game%.project") ~= nil,
    "stamping only one is how they drifted in the first place")
check_true("verifying rather than trusting the version sed",
    rel:find('grep %-q "%^version = %${VERSION_NAME}%$" game%.project') ~= nil,
    "a sed that matches nothing exits 0")
check_true("and the version_code sed",
    rel:find('grep %-q "%^version_code = %${VERSION_CODE}%$" game%.project') ~= nil,
    "same trap")

print("")
print("google sign-in is not offered")
local lobby = slurp("main/lobby.gui_script")
local code_of = function(s) return (s:gsub("%-%-[^\n]*", "")) end
check_true("the lobby no longer says SIGN IN WITH GOOGLE",
    code_of(lobby):find("SIGN IN WITH GOOGLE") == nil,
    "it told the player to do something the app cannot do")
check_true("and nothing calls the google route",
    code_of(slurp("modules/api_service.lua")):find("auth/google") == nil,
    "a live call to a sign-in we no longer use")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
