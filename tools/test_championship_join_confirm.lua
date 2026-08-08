-- THE CHAMPIONSHIP JOIN IS CONFIRMED BY THE SERVER, ONCE — NOT GUESSED LOCALLY.
--
--   Run: lua tools/test_championship_join_confirm.lua
--
-- Reported: "every time I click join it removes coins from the balance, but
-- I noticed this is only done on the frontend — the backend balance stays
-- the same." The PLAY handler used to deduct+animate locally whenever
-- current_level_index == 0, which is true both for a player who never
-- joined AND for one who already joined and paid but hasn't won level 1
-- yet — so "no opponent found, tap PLAY again" animated a second coin loss
-- for a charge the server's own idempotent ensureJoined only ever took
-- once.
--
-- Fixed by asking the server first instead of guessing: POST
-- /tournaments/:id/join runs ensureJoined and reports back exactly what
-- happened. The client now animates only when it says charged > 0, uses its
-- own newBalance rather than a locally computed one, and only proceeds into
-- the jump/search flow (and only shows PLAY instead of the entry-fee coin
-- styling) once that answer is in hand.

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
print("modules/api_service.lua — the HTTP call itself")

local api_src = slurp("modules/api_service.lua")
local api_code = api_src:gsub("%-%-[^\n]*", "")

check("M.join_championship exists",
    api_code:find("function M%.join_championship%(tournament_id, user_id, cb%)") ~= nil)

local jc_start = api_code:find("function M%.join_championship")
local jc_end = api_code:find("\nend\n", jc_start or 1)
local jc_body = (jc_start and jc_end) and api_code:sub(jc_start, jc_end) or ""

check("posts to the join endpoint for THIS tournament",
    jc_body:find('request%("POST", "/tournaments/" %.%. tournament_id %.%. "/join"') ~= nil)
check("sends userId in the body",
    jc_body:find("{ userId = user_id }") ~= nil)
check("retried like the other find%-or%-create%-once endpoints",
    jc_body:find("{ retries = 2 }") ~= nil,
    "ensureJoined is idempotent server-side (charged: 0 on a repeat), so a lost response is safe to retry rather than leaving the player stuck unconfirmed")

-- ---------------------------------------------------------------------------
print("")
print("main/tournaments.gui_script — requires the API module")

local t_src = slurp("main/tournaments.gui_script")
local t_code = t_src:gsub("%-%-[^\n]*", "")

check("requires modules.api_service",
    t_code:find('require%("modules%.api_service"%)') ~= nil)

-- ---------------------------------------------------------------------------
print("")
print("the PLAY handler")

local handle_start = t_code:find("\nlocal function handle%(self, b%)")
check("handle(self, b) exists", handle_start ~= nil, "a rename would make everything below vacuous")

local handle_end = t_code:find("\nfunction on_input", handle_start or 1)
local handle_body = (handle_start and handle_end) and t_code:sub(handle_start, handle_end) or ""

check("calls api.join_championship before anything else happens",
    handle_body:find("api%.join_championship%(tournament_id, user_id, function%(result%)") ~= nil)

check("does NOT compute a local cost/balance deduction any more",
    handle_body:find("u%.balance %- cost") == nil and handle_body:find("local cost = tonumber") == nil,
    "the whole point of the fix is that the client no longer guesses the charge")

do
    -- The one occurrence before api.join_championship( is the "nothing to
    -- confirm against" fallback (no tournament_id/user_id) — a different,
    -- legitimate path, not the bug. What matters is that AT LEAST ONE call
    -- sits after it, inside the callback.
    local call_pos = handle_body:find("api%.join_championship%(")
    local after_call = call_pos and handle_body:sub(call_pos) or ""
    check("execute_jump_and_play is called from INSIDE the join callback, not before it",
        call_pos ~= nil and after_call:find("execute_jump_and_play%(self, d%)") ~= nil,
        "proceeding before the server confirms the join is exactly the bug being fixed")
end

check("the coin animation is gated on charged > 0",
    handle_body:find("if charged > 0 then") ~= nil,
    "must not always animate — that was the original bug")

do
    local animate_pos = handle_body:find("if charged > 0 then")
    local play_anim_pos = handle_body:find("play_deduction_animation%(self, function%(%)", animate_pos or 1)
    check("and the animation is what LEADS INTO execute_jump_and_play, not run alongside it",
        animate_pos ~= nil and play_anim_pos ~= nil and play_anim_pos > animate_pos and play_anim_pos < (animate_pos + 100))
end

check("the displayed balance comes from the server's own newBalance",
    handle_body:find("local new_balance = tonumber%(data%.newBalance%)") ~= nil,
    "never a locally computed balance - charge - the server's number is the only one trusted")

check("charged is read from the server's response, not assumed",
    handle_body:find("local charged = tonumber%(data%.charged%) or 0") ~= nil)

check("insufficient balance still raises the same transaction modal",
    handle_body:find('msg%.post%("main:/controller", "show_transaction_modal"%)') ~= nil)

-- ---------------------------------------------------------------------------
print("")
print("PRESSING PLAY gives instant feedback, before the round trip resolves")
--
-- Reported: the join round trip can take a genuinely noticeable moment on a
-- slow connection, and nothing on screen changed between the tap landing and
-- the response coming back — no press, no dimming — which read as "the
-- button doesn't respond". The acknowledgement (a press pulse, a dimmed/
-- locked button) must be instant; only the real coin-deduction animation is
-- allowed to wait for the server's confirmed `charged` amount.

do
    local call_pos = handle_body:find("api%.join_championship%(")
    local before_call = call_pos and handle_body:sub(1, call_pos) or ""

    check("the button plays a press animation BEFORE the join call fires",
        before_call:find('gui%.animate%(self%.play_btn_node, "scale"') ~= nil,
        "feedback fired only after the response arrives is not instant feedback")

    check("...and it happens after self.play_disabled/is_moving are set, not before",
        (function()
            local locked_pos = before_call:find("self%.is_moving = true")
            local anim_pos = before_call:find('gui%.animate%(self%.play_btn_node, "scale"')
            return locked_pos ~= nil and anim_pos ~= nil and anim_pos > locked_pos
        end)(),
        "the lock and the feedback are meant to land together, as one instant reaction to the tap")

    check("the button text is swapped immediately too, not left showing the stale label",
        before_call:find('gui%.set_text%(self%.play_txt_node, "%.%.%."%)') ~= nil)

    check("a failed join restores the real button state instead of leaving it on the instant-feedback text",
        handle_body:find("if not result%.success then") ~= nil
        and (function()
            local fail_pos = handle_body:find("if not result%.success then")
            local ret_pos = handle_body:find("return", fail_pos or 1)
            local branch = (fail_pos and ret_pos) and handle_body:sub(fail_pos, ret_pos) or ""
            return branch:find("rebuild%(self%)") ~= nil
        end)(),
        "left on \"...\" after a failure, the button would look permanently broken until some unrelated rebuild happened to fix it")
end

-- ---------------------------------------------------------------------------
print("")
print("the button label agrees with whether the player has actually joined")

local upb_start = t_code:find("\nupdate_play_button = function%(self%)")
check("update_play_button exists", upb_start ~= nil)
local upb_end = t_code:find("\nend\n", upb_start or 1)
local upb_body = (upb_start and upb_end) and t_code:sub(upb_start, upb_end) or ""

check("reads userProgress.status, the same active-row signal ensureJoined checks server-side",
    upb_body:find('local already_joined = up%.status == "active"') ~= nil,
    "current_level_index == 0 is true BOTH for never-joined and for joined-but-still-on-level-1 — that conflation is why the button used to show \"pay X\" to a player who had already paid")

check("only shows the entry-fee coin styling when NOT already joined",
    upb_body:find("if self%.current_level_index == 0 and not already_joined then") ~= nil)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
