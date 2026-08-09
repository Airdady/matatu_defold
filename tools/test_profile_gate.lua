-- A PLAYER WITH NO NAME AND NO FACE IS NOT A PLAYER YET.
--
--   Run: lua tools/test_profile_gate.lua
--
-- The server hides accounts with no username or avatar from the online list
-- and refuses game requests in either direction (be_matatu's
-- profileComplete.ts). This is the client half: what the player SEES when that
-- refusal comes back.
--
-- Every other decline reason is about the opponent or the moment, and closing
-- the dialog is the right response. This one is not — the thing that needs
-- changing lives on another screen, so closing the dialog silently reads as
-- the button simply not working.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local base = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function read(rel)
    local f = assert(io.open(base .. "../" .. rel))
    local s = f:read("a"); f:close(); return s
end

local raw   = read("main/controller.script")
local code  = (raw:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
local state = read("modules/app_state.lua")

print("THE REFUSAL IS ACTED ON, NOT SWALLOWED")
check("the decline handler recognises the reason",
    code:find('PROFILE_INCOMPLETE', 1, true) ~= nil, true)
check("and routes to the screen that fixes it",
    code:find('show(self, "profile")', 1, true) ~= nil, true)
check("with an explanation", code:find("toast.error", 1, true) ~= nil, true)

-- It must not ALSO fall through into the ordinary decline path, which posts a
-- replay-declined and a search-failed for a request that was never a search.
local handler = code:sub(code:find('ws.on("game_request_declined"', 1, true) or 1)
handler = handler:sub(1, handler:find("end))", 1, true) or #handler)
local branch = handler:sub(handler:find("PROFILE_INCOMPLETE", 1, true) or 1)
check("and returns rather than falling through",
    branch:sub(1, (branch:find("end", 1, true) or #branch)):find("return", 1, true) ~= nil, true)
check("before the ordinary decline handling",
    (handler:find("PROFILE_INCOMPLETE", 1, true) or math.huge)
        < (handler:find("ws_replay_declined", 1, true) or 0), true)

print("")
print("AND THE MODULE IT CALLS IS ACTUALLY IN SCOPE")
-- luac -p cannot catch this: an unrequired `toast` is a nil global, and the
-- call raises only when a player is actually refused — which is the one moment
-- it exists to serve. The same shape as the SIGN_IN_CONNECT_GRACE and
-- close_orphan_socket bugs, both of which shipped and both of which were a
-- name that was simply not there at the use site.
check("toast is required", code:find('require("modules.toast")', 1, true) ~= nil, true)
check("before it is used",
    (code:find('require("modules.toast")', 1, true) or math.huge)
        < (code:find("toast.error", 1, true) or 0), true)
-- show() is a local, so it has to be DECLARED above the handler too.
check("and show() is declared above the handler",
    (code:find("local function show(self, screen)", 1, true) or math.huge)
        < (code:find("PROFILE_INCOMPLETE", 1, true) or 0), true)

print("")
print("THE CLIENT AND SERVER AGREE ON WHAT 'SET UP' MEANS")
-- If they drift, a player the app considers finished stays hidden on the
-- server with no screen left to send them to. be_matatu's profileComplete.ts
-- mirrors these; this end asserts they are still the thing being mirrored.
check("three characters", state:find("#name < 3", 1, true) ~= nil, true)
check("trimmed first", state:find('name:gsub("^%s*(.-)%s*$", "%1")', 1, true) ~= nil, true)
check("Player_ anchored at the start",
    state:find('name:sub(1, 7) == "Player_"', 1, true) ~= nil, true)
check("and an avatar above zero", state:find("avatar <= 0", 1, true) ~= nil, true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
