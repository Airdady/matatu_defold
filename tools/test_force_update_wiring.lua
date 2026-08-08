-- THE PLAY IN-APP UPDATE API STOPPED BEING CALLED AT ALL.
--
--   Run: lua tools/test_force_update_wiring.lua
--
-- gameservices/src/gameservices.cpp and InAppUpdateDefold.java are a
-- complete, working bridge to Google Play's In-App Update API — checkForUpdate,
-- IMMEDIATE with a FLEXIBLE+auto-restart fallback, resuming an interrupted
-- update, re-triggering on cancel. None of that changed or broke.
--
-- What broke: a comment-wording cleanup pass ("improve the code", not from
-- this session) deleted the only two places in the ENTIRE Lua codebase that
-- ever called gameservices.check_update() — main/controller.script's init()
-- (cold start) and its window.set_listener FOCUS_GAINED branch (foreground
-- resume) — along with the comments explaining why both matter. The native
-- side kept compiling and shipping in every build; it just never ran,
-- because nothing ever asked it to. Reported as "the force update API isn't
-- effective any more".
--
-- Both call sites are restored. This pins them so a future cleanup pass
-- cannot silently delete them again without a test noticing.

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

local src = slurp("main/controller.script")
local code = src:gsub("%-%-[^\n]*", "")

print("COLD START")

local init_start = code:find("\nfunction init%(self%)")
check("init(self) exists", init_start ~= nil, "a rename would make everything below vacuous")

local listener_start = code:find("window%.set_listener%(function%(_, event%)", init_start or 1)
check("window.set_listener exists, further down in init", listener_start ~= nil)

if init_start and listener_start then
    local cold_start_body = code:sub(init_start, listener_start)
    check("checks for an update the moment the app opens",
        cold_start_body:find("if gameservices then gameservices%.check_update%(%) end") ~= nil,
        "gameservices.check_update() is the ONLY thing that ever asks the native side to check")
end

print("")
print("FOREGROUND RESUME")

if listener_start then
    -- Up to the next top-level function, so this covers the whole listener
    -- body without also picking up unrelated code further down in the file.
    local listener_end = code:find("\nfunction ", listener_start + 1)
    local listener_body = code:sub(listener_start, listener_end and (listener_end - 1) or nil)

    local focus_gate_pos = listener_body:find("if event ~= window%.WINDOW_EVENT_FOCUS_GAINED then return end")
    check("gated on FOCUS_GAINED specifically, not every window event", focus_gate_pos ~= nil)

    local recheck_pos = listener_body:find("if gameservices then pcall%(gameservices%.check_update%) end")
    check("re-checks for an update on every foreground regain, not just cold start",
        recheck_pos ~= nil,
        "getAppUpdateInfo() answers from Play's own cached metadata, which refreshes on ITS schedule — a single check at cold start can miss an update that becomes available while the app stays resident, and a killed/backgrounded IMMEDIATE update needs an onResume check to resume at all")

    check("the resume-check sits AFTER the FOCUS_GAINED gate, not before",
        focus_gate_pos ~= nil and recheck_pos ~= nil and focus_gate_pos < recheck_pos,
        "checking on every window event (focus lost included) would be at minimum wasteful and at worst call into a background-only native API")

    check("pcall-guarded, unlike the cold-start call",
        recheck_pos ~= nil and listener_body:sub(recheck_pos, recheck_pos + 60):find("pcall") ~= nil,
        "a resume check running many times over an app's life must not be able to kill the window listener on one bad call")
end

print("")
print("THE NATIVE BRIDGE ITSELF IS STILL FULLY WIRED — this never broke")

local ext_src = slurp("gameservices/src/gameservices.cpp")
check("check_update is registered as a Lua-callable function",
    ext_src:find('{"check_update", CheckUpdate}') ~= nil)
check("and it actually calls into the Java checkForUpdate method",
    ext_src:find('"checkForUpdate", "%(%)V"') ~= nil)

local java_src = slurp("gameservices/src/InAppUpdateDefold.java")
check("Java forces IMMEDIATE when Play allows it",
    java_src:find("startImmediateUpdate%(%);") ~= nil)
check("falling back to FLEXIBLE with auto%-restart when it does not",
    java_src:find("startFlexibleUpdate%(%);") ~= nil and java_src:find("completeUpdate%(%);") ~= nil)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
