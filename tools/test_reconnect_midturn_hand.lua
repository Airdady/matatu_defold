-- A CARD THAT COMES BACK TWICE: ONCE AS A "NEW DRAW", ONCE MORE LATER.
--
--   Run: lua tools/test_reconnect_midturn_hand.lua
--
-- Reported: play a skip card (or draw one, mid-penalty) and DON'T press the
-- button that ends the turn yet — then lose the connection. On reconnect the
-- played card comes right back into the hand (a second, freshly-spawned game
-- object with the same value+suit as the one already sitting on the pile —
-- a duplicate with a duplicate key, exactly what breaks its animation), or a
-- drawn card vanishes and then reappears via a phantom "draw" animation
-- later, during the eventual move confirmation or the opponent's next move.
-- Also seen as the deck visibly re-rendering a card back in.
--
-- ROOT CAUSE
--
-- M.end_turn deliberately never sends a skip-chain/penalty-draw/suit-pick
-- until the WHOLE turn resolves — current_turn_actions accumulates PLAY and
-- DRAW entries locally and nothing reaches the server until the player ends
-- their turn. That is correct and unrelated to this bug.
--
-- The bug is downstream: full_resync (every reconnect) and handle_single_move
-- (every opponent move) both reconcile self.player_hand and self.deck
-- against the server's state via sync_my_hand/finalize_state_sync — and
-- neither of them knew current_turn_actions existed. The server's hand and
-- deck count are, correctly, still exactly as they were BEFORE this turn
-- started (nothing was sent yet), so:
--
--   * a card already PLAYED locally (spliced out of player_hand, animated
--     onto the pile) is still listed in the server's hand — read as "the
--     server has a card we don't", sync_my_hand draws it straight back in.
--   * a card already DRAWN locally (added to player_hand) is NOT in the
--     server's hand yet — read as "we have a card the server doesn't
--     recognize", sync_my_hand released it back out. The same drawn card
--     already came off self.deck locally too, but the server's deckCount
--     doesn't know that either — sync_deck_size read the local deck as
--     short and handed a card back onto it, the "deck re-renders" symptom.
--
-- Both are corrected by treating current_turn_actions as what it actually
-- is: turn state the server hasn't heard about yet, not a desync to fix.

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
print("sync_my_hand accounts for an in-progress, not-yet-sent turn")

local fn_start = code:find("local function sync_my_hand%(self, state, done%)")
check("sync_my_hand exists", fn_start ~= nil)

local fn_end = fn_start and code:find("\nfunction M%.finalize_state_sync", fn_start)
-- finalize_state_sync is defined earlier in the file than sync_my_hand, so
-- fall back to the next `local function`/`function M.` after it instead.
if fn_start and not fn_end then
    fn_end = code:find("\n%-%-[^\n]*\nfunction M%.", fn_start + 1) or code:find("\nfunction M%.", fn_start + 1)
end
local fn_body = fn_start and code:sub(fn_start, fn_end and (fn_end - 1) or nil)

if fn_body then
    local pool_build_end = fn_body:find("\n    local kept = {}")
    check("the server-hand pool is built before the kept/to_add diff", pool_build_end ~= nil)

    local adjustment = pool_build_end and fn_body:sub(1, pool_build_end)

    check("walks self.current_turn_actions before diffing",
        adjustment and adjustment:find("ipairs%(self%.current_turn_actions or {}%)") ~= nil,
        "without this, a not-yet-sent PLAY/DRAW is compared against server truth as if it never happened locally")

    check("a locally-PLAYed-but-unsent card is consumed out of the pool, not left for the diff to re-add",
        adjustment and adjustment:find('act%.type == "PLAY"') ~= nil
            and adjustment:find("table%.remove%(bucket%)") ~= nil,
        "otherwise the diff sees 'server still has it, we don't' and calls draw_to_hand — the played card comes right back")

    check("a locally-DRAWn-but-unsent card is injected into the pool, not left for the diff to release",
        adjustment and adjustment:find('act%.type == "DRAW"') ~= nil
            and adjustment:find("table%.insert%(pool%[key%], { v = act%.v, s = act%.s }%)") ~= nil,
        "otherwise the diff sees 'we have a card the server doesn't recognize' and releases it back out of the hand")

    check("the PLAY/DRAW adjustment runs BEFORE the kept/to_add diff, not after",
        adjustment ~= nil and pool_build_end ~= nil,
        "adjusting the pool after kept/to_add has already been computed from it would be a no-op")
end

print("")
print("finalize_state_sync's deck target accounts for the same pending draws")

local fss_start = code:find("function M%.finalize_state_sync%(self, state, on_complete%)")
check("finalize_state_sync exists", fss_start ~= nil)
local fss_end = fss_start and code:find("\nfunction M%.pump_move_queue", fss_start)
local fss_body = fss_start and code:sub(fss_start, fss_end and (fss_end - 1) or nil)

if fss_body then
    check("counts pending DRAW actions from current_turn_actions",
        fss_body:find('if act%.type == "DRAW" then pending_draws = pending_draws %+ 1 end') ~= nil,
        "a DRAW already taken locally already came off self.deck, but the server's deckCount does not reflect that until the turn is sent")

    local do_sync_start = fss_body:find("local function do_sync%(%)")
    local do_sync_target = do_sync_start and fss_body:match(
        "local deck_target = ([^\n]+)\n%s*M%.sync_deck_size", do_sync_start)
    check("the deck_target actually fed to sync_deck_size subtracts pending_draws",
        do_sync_target ~= nil and do_sync_target:find("%- pending_draws") ~= nil,
        "otherwise sync_deck_size reads the locally-already-shrunk deck as short and hands a card back onto it")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
