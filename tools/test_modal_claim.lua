-- Regression test for the app-wide input freeze.
--
--   Run: lua tools/test_modal_claim.lua
--
-- THE BUG
--
-- Every screen in the app begins its on_input with
--
--     if app_state.input_blocked() then return false end
--
-- which is true while ANY entry sits in the modal registry. A full incoming
-- game-request dialog claims "incoming"; a top banner deliberately does not,
-- because it is non-disruptive and play carries on underneath it.
--
-- open_dialog only ever CLAIMED. So when a second request arrived before the
-- first was answered — a tournament invite landing on top of a plain game
-- request, which is what happens when requests come in a burst — the banner
-- replaced the dialog and the dialog's claim was left standing. What the
-- player saw was a banner that lets taps through. What was actually true was
-- that nothing anywhere responded, with no error and nothing on screen to
-- explain it, and no way out but restarting the app.
--
-- This drives the REAL modules/app_state.lua registry rather than a copy of
-- it, because the whole failure was two pieces of code disagreeing about that
-- one table.

-- Minimal Defold stubs so the real module loads outside the engine.
vmath = { vector4 = function(...) return { ... } end, vector3 = function(...) return { ... } end }
hash = function(s) return s end
sys = { get_sys_info = function() return { system_name = "Linux" } end }

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local app_state = require("modules.app_state")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- What a screen's on_input asks before doing anything.
local function screen_accepts_taps() return not app_state.input_blocked() end

-- The claim logic from open_dialog, both directions — this is the fix.
local function claim_for(is_banner)
    if is_banner then app_state.modal_close("incoming") else app_state.modal_open("incoming") end
end

print("A burst of requests must never leave the app unresponsive")

app_state.modals = {}
check("nothing showing -> taps work", screen_accepts_taps(), true)

-- 1. A plain game request. Full dialog, modal on purpose: a challenge is a
--    decision, and nothing underneath may act on a tap meant for it.
claim_for(false)
check("full dialog -> taps blocked", screen_accepts_taps(), false)

-- 2. A tournament invite arrives before it is answered. Banner replaces the
--    dialog. THIS is the case that froze the app.
claim_for(true)
check("banner replaces dialog -> taps work again", screen_accepts_taps(), true)

-- 3. And back, so the reconciliation holds in both directions repeatedly.
claim_for(false)
check("dialog replaces banner -> taps blocked", screen_accepts_taps(), false)
claim_for(true)
check("banner replaces dialog again -> taps work", screen_accepts_taps(), true)

print("The watchdog releases a claim nothing is showing for")

-- Belt and braces from update(): the cost of the registry and the screen
-- disagreeing is not a glitch, it is an unusable app.
app_state.modals = {}
app_state.modal_open("incoming")
check("stale claim -> taps blocked", screen_accepts_taps(), false)
local dialog = nil
if not dialog and app_state.modals and app_state.modals["incoming"] then
    app_state.modal_close("incoming")
end
check("watchdog ran -> taps work", screen_accepts_taps(), true)

print("Other modals are unaffected")

-- gameover claims and releases together (set_visible), and must still work.
app_state.modals = {}
app_state.modal_open("gameover")
check("gameover up -> taps blocked", screen_accepts_taps(), false)
app_state.modal_close("gameover")
check("gameover down -> taps work", screen_accepts_taps(), true)

-- The gameover dialog's OWN input still runs while it is the top modal —
-- input_blocked(name) compares priorities rather than asking "is anything up".
app_state.modals = {}
app_state.modal_open("gameover")
check("gameover reads its own input", app_state.input_blocked("gameover"), false)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("All checks passed.")
