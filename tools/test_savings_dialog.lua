-- THE SAVINGS EXPLAINER: ITS WORDS, AND ITS TURN.
--
--   Run: lua tools/test_savings_dialog.lua
--
-- Two reports about one dialog.
--
-- 1. "the savings dialogue is not showing the text content". The copy is typed
--    out character by character, and the budget for that comes from a clock
--    ticked in ANOTHER FILE's update(). That tick was removed (3f12276) and
--    the drawing code went on dividing by it: _savings_type_t stayed nil,
--    budget was permanently 0, and typed() returned "" for every line. The
--    panel, the coin bundle, the dividers, the progress bar and both buttons
--    all still drew — around no words at all.
--
-- 2. "make sure the user presses UNDERSTAND before opening the new dialogs for
--    bonuses". The explainer is shown once per player EVER, at the same moment
--    a fresh account trips the bonus modals. Those are separate .gui
--    components with their own node trees, so they do not stack with it — they
--    land on top, and it is dismissed unread and never returns.
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

local right  = slurp("modules/online_right.lua")
local online = slurp("main/online.gui_script")
local daily  = slurp("main/daily_bonus.gui_script")
local signup = slurp("main/signup_bonus.gui_script")
local state  = slurp("modules/app_state.lua")

print("")
print("THE COPY SURVIVES A CLOCK THAT IS NOT RUNNING")

local draw = right:match("local function draw_savings_info%(self, ctx%)(.-)\nend\n") or ""
check("no clock means show everything, not nothing",
    draw:find('local ticking = type%(self%._savings_type_t%) == "number"'),
    "an animation must not be able to delete the content it animates")
check("and the typing budget is only applied while it IS running",
    draw:find("local typing = ticking and not self%._savings_type_done"),
    "typing without a clock is what emptied every line")
check("the budget never comes from a nil clock again",
    draw:find("budget = typing and math%.floor%(self%._savings_type_t / CHAR_INTERVAL%)")
        and not draw:find("math%.floor%(%(self%._savings_type_t or 0%)"),
    "`or 0` reads a missing clock as time zero, which is the bug")

-- And the copy it is protecting is really there to be shown.
check("there is body copy to show at all",
    draw:find("Savings are long%-term coins earned from"), "the lines themselves")
check("and the advantages list",
    draw:find("Never resets or expires, it only grows"))

print("")
print("AND THE TICK IS BACK, SO IT STILL TYPES")
local upd = online:match("\nfunction update%(self, dt%)(.-)\nend\n") or online
check("update() advances the savings clock",
    upd:find("self%._savings_type_t = %(self%._savings_type_t or 0%) %+ dt"),
    "removed in 3f12276; the drawing code never stopped depending on it")
check("only while the dialog is open",
    upd:find("if self%.savings_info_open and not self%._savings_type_done"))
check("and the clock starts WITH the dialog",
    online:find("self%._savings_type_t, self%._savings_type_done = 0, false"),
    "left nil for a frame, the copy shows in full and is then typed back in from nothing")

print("")
print("BONUSES WAIT FOR I UNDERSTAND")
check("there is a flag for it, alongside the season one",
    state:find("M%.savings_promo_active = false"))
check("claimed when the explainer opens itself",
    online:find("app_state%.savings_promo_active = true"))
check("released when I UNDERSTAND (or the scrim) closes it",
    online:find("self%.savings_info_open = false\n%s*app_state%.savings_promo_active = false"),
    "still claimed after dismissal blocks every bonus for the rest of the session")

local dgate = daily:match("if self%.pending and not self%.visible(.-)then") or ""
check("the daily bonus waits on it",
    dgate:find("not app_state%.savings_promo_active"),
    "it fires at the same moment on a fresh account")
local sgate = signup:match("if self%.pending and not self%.visible(.-)then") or ""
check("and so does the signup bonus",
    sgate:find("not app_state%.savings_promo_active"))
-- Both already defer to the season modal; this must be an addition, not a swap.
check("without dropping the gates they already had",
    dgate:find("season_modal_active") and sgate:find("daily_bonus_active"),
    "a bonus that stops fighting one modal by fighting another is not fixed")

print("")
print("AND THE CLAIM CANNOT OUTLIVE THE SCREEN")
check("leaving the online screen releases it",
    online:find('hash%("disable"%)(.-)app_state%.savings_promo_active = false'),
    "the nodes are cleared on disable, so a standing claim blocks bonuses forever")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
