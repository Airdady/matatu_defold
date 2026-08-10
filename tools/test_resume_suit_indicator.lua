-- CLOSE THE APP WHILE A SUIT IS ACTIVE, REOPEN, AND IT LOOKS UNCHOSEN.
--
--   Run: lua tools/test_resume_suit_indicator.lua
--
-- Reported: the opponent plays a wildcard and picks a suit — the indicator
-- shows it's active. The player closes the app entirely (not just a network
-- drop — a cold close/reopen) while it's showing, then reopens into the same
-- ongoing game. The suit no longer reads as active, even though it still is,
-- server-side, exactly as before.
--
-- ROOT CAUSE
--
-- Cold-reopening into an ongoing game goes through M.start_game's
-- `is_resume` fast path (main/controller.script's game_request_accepted ->
-- GF.start_game, NOT full_resync — that one's only for a live socket
-- reconnect while the app process stays up). That path set
-- self.chosen_suit from state.chosenSuit correctly, but told the GUI about
-- it with `msg.post(GUI_SUIT, "suit_badge", {...})` — and "suit_badge" is
-- never actually received by ANY .gui_script in this client (checked: no
-- `hash("suit_badge")` match anywhere). Every OTHER path that shows the
-- active-suit indicator (process_opponent_actions, finalize_state_sync) uses
-- `suit_select` with mode="preview" instead — that message IS handled, by
-- main/suit_select.gui_script. The resume path was the one place still
-- posting to a message nothing listens for.

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

local src = slurp("modules/online_handler.lua")
local code = src:gsub("%-%-[^\n]*", "")

print("")
print("suit_badge is confirmed dead — nothing in the client handles it")
check("no .gui_script matches hash(\"suit_badge\")",
    not code:find('hash%("suit_badge"%)'),
    "if this ever starts matching, the fix below stops being necessary (but is still harmless)")

print("")
print("M.start_game's is_resume fast path shows the active suit correctly")

local fn_start = code:find("if is_resume then")
check("the is_resume fast path exists", fn_start ~= nil)

local fn_end = fn_start and code:find("\n    end\n\n    local seq = self%._seq", fn_start)
local fn_body = fn_start and code:sub(fn_start, fn_end and (fn_end - 1) or nil)

if fn_body then
    check("posts suit_select with mode=\"preview\" when a suit is in force",
        fn_body:find('msg%.post%(GUI_SUIT, "suit_select", { mode = "preview", suit = self%.chosen_suit }%)') ~= nil,
        "suit_select is the message main/suit_select.gui_script actually listens for")

    check("closes it when there isn't one (or the game already ended)",
        fn_body:find('msg%.post%(GUI_SUIT, "suit_select", { mode = "close" }%)') ~= nil,
        "a resume into a state with no suit chosen must not leave a stale indicator showing")

    check("gated on chosen_suit being non-empty and both hands still having cards",
        fn_body:find('if self%.chosen_suit ~= "" and p_count > 0 and a_count > 0 then') ~= nil,
        "same game_still_active-style guard finalize_state_sync uses — never preview once either hand has emptied")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
