-- KADI: PLAY ONLINE IS "COMING SOON", AND NO NEW REGISTRATIONS.
--
--   Run: lua tools/test_kadi_coming_soon.lua
--
-- Both frontend-only, per game_mode.lua's build-time M.GAME switch — Kadi is
-- its own app build, so this affects only the Kadi binary, never Matatu or
-- Whot. No backend change: the client simply never offers the tile or sends
-- the request that would create an account.

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

print("PLAY ONLINE TILE")

local lobby_src = slurp("main/lobby.gui_script")
local lobby_code = lobby_src:gsub("%-%-[^\n]*", "")

check("gates on GameMode.is_kadi()", lobby_code:find("local is_kadi = GameMode%.is_kadi%(%)") ~= nil,
    "a rename would make every assertion below vacuous")
check("checked BEFORE the other connection states (offline/app-offline/connecting/error)",
    lobby_code:find("if is_kadi then%s*\n%s*cta_text = \"COMING SOON\"") ~= nil,
    "if it were an elseif further down, a genuine connection error could still show through")
check("the button id becomes noop, not play_online", lobby_code:find('is_kadi and "noop"') ~= nil,
    "\"noop\" is already handled at the top of handle() as a deliberate do-nothing")
check("and the tile is explicitly disabled", lobby_code:find("if is_kadi then play_disabled = true end") ~= nil)
check("is_exhausted/connecting are both false for Kadi, not just cta_text",
    lobby_code:find("local is_exhausted = %(not is_kadi%) and st ==") ~= nil and
    lobby_code:find("local connecting   = %(not is_kadi%) and %(st ==") ~= nil,
    "otherwise a genuinely offline Kadi build could still show RETRY/CONNECTING under the COMING SOON label")

print("")
print("THE TAP ITSELF IS ALSO GUARDED, NOT JUST THE TILE'S OWN noop")

local handler = lobby_code:match('elseif b%.id == "play_online" then.-\n%s*end')
check("play_online handler found", handler ~= nil)
if handler then
    check("refuses for Kadi before calling go_online",
        handler:find("if GameMode%.is_kadi%(%) then return end") ~= nil)
    local guard_pos = handler:find("if GameMode%.is_kadi%(%) then return end")
    local go_pos = handler:find("go_online%(self%)")
    check("the guard runs BEFORE go_online, not after",
        guard_pos ~= nil and go_pos ~= nil and guard_pos < go_pos)
end

check("go_online() itself is untouched — it is shared with TEAM CUPS' CREATE tap",
    lobby_code:match("local function go_online%(self%)%s*\n.-\n%s*if not ws%.is_identified") ~= nil,
    "blocking go_online itself would also silently break Team Cups for every OTHER game mode")

-- ---------------------------------------------------------------------------
print("")
print("NO NEW REGISTRATIONS")

local ctrl_src = slurp("main/controller.script")
local ctrl_code = ctrl_src:gsub("%-%-[^\n]*", "")

check("controller.script requires GameMode", ctrl_code:find('require%("modules%.game_mode"%)') ~= nil)

local pl_start = ctrl_code:find('elseif message_id == hash%("phone_login"%) then')
check("the phone_login branch exists", pl_start ~= nil,
    "a rename would make every assertion below vacuous")

if pl_start then
    local pl_end = ctrl_code:find("elseif message_id ==", pl_start + 1)
    local pl_branch = ctrl_code:sub(pl_start, pl_end and (pl_end - 1) or nil)

    local guard_pos = pl_branch:find("if GameMode%.is_kadi%(%) then")
    check("refuses for Kadi", guard_pos ~= nil)
    check("returns a message the profile screen actually displays",
        pl_branch:find('msg%.post%("#profile", "phone_link_result",%s*\n%s*{ ok = false, message =') ~= nil)

    local api_call_pos = pl_branch:find("api%.phone_login%(")
    check("the guard runs BEFORE the network call that would create the account, not after",
        guard_pos ~= nil and api_call_pos ~= nil and guard_pos < api_call_pos,
        "checking isNewUser in the response would be too late — the account already exists by then")
end

-- link_phone's own two fallback-to-phone_login branches (no bearer to link
-- onto, or a stale one refused) both re-post "phone_login" rather than
-- calling the API directly — so they inherit the same guard above without
-- needing their own copy. Confirmed here so a future refactor that made them
-- call api.phone_login directly instead would be caught.
local lp_start = ctrl_code:find('elseif message_id == hash%("link_phone"%) then')
check("link_phone's fallbacks route back through phone_login (inheriting its Kadi guard)",
    lp_start ~= nil and (function()
        local lp_end = ctrl_code:find("\n    elseif message_id ==", lp_start + 1)
        local lp_branch = ctrl_code:sub(lp_start, lp_end and (lp_end - 1) or nil)
        local n = select(2, lp_branch:gsub('msg%.post%("#controller", "phone_login"', ""))
        return n == 2
    end)(),
    "if either fallback called api.phone_login directly, it would create a Kadi account with no guard at all")

check("an ALREADY-signed-in user linking/updating a phone number is untouched",
    ctrl_code:find("api%.link_phone%(") ~= nil,
    "that is account management, not new registration, and must keep working on every game mode including Kadi")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
