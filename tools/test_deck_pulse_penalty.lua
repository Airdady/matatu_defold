-- HIGHLIGHT THE DECK WHEN THE ONLY LEGAL MOVE IS TO DRAW.
--
--   Run: lua tools/test_deck_pulse_penalty.lua
--
-- Requested: when a player disconnects (or reopens the app) with an active
-- penalty and no card in hand that answers it, pulse the deck as a signal
-- to draw the required penalty cards.
--
-- WHERE IT LIVES
--
-- rules_eval.lua's pre_validate_hand is already the hook every state change
-- that could affect the answer runs through: full_resync's completion (the
-- reconnect path this was reported for), sync_my_hand, every draw/play
-- settling, a fresh turn starting. Deciding "should I be pulsing" there,
-- once, covers the reconnect case for free instead of needing its own
-- special-cased trigger — and keeps working for the same underlying
-- situation (must draw, nothing in hand answers the penalty) reached any
-- other way.
--
-- board_layout.lua's set_deck_pulse owns the actual animation, keyed to the
-- top deck card's own go id (not just an on/off flag) so an animation left
-- running on a card that has since actually been drawn — a different game
-- object — can't throw trying to touch an instance it no longer represents.

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

local re = slurp("modules/games/matatu/rules_eval.lua")
local bl = slurp("modules/board_layout.lua")
local gs = slurp("modules/game_state.lua")
local game = slurp("main/game.script")

print("")
print("pre_validate_hand decides whether to pulse the deck")

local pv_start = re:find("function M%.pre_validate_hand%(self%)")
local pv_end = pv_start and re:find("\nfunction M%.has_playable", pv_start)
local pv_body = pv_start and re:sub(pv_start, pv_end and (pv_end - 1) or nil)

check("pre_validate_hand is found", pv_body ~= nil)
if pv_body then
    check("only in online mode, and never once the game has ended",
        pv_body:find("not self%.online_mode or self%.game_over") ~= nil)
    check("requires it to be this player's own turn",
        pv_body:find("self%.is_player_turn%(%)") ~= nil,
        "no point prompting a draw on a turn that isn't ours to take yet")
    check("requires an active penalty",
        pv_body:find("M%.get_active_penalty%(self%) > 0") ~= nil)
    check("requires nothing in hand to answer it",
        pv_body:find("not M%.has_playable%(self, self%.player_hand%)") ~= nil,
        "a player who CAN condense the penalty has a real choice to make, not just a draw to take")
    check("turns the pulse off outside online mode or once the game is over",
        pv_body:find("self%.set_deck_pulse%(false%)") ~= nil,
        "otherwise a pulse started before game-over could keep animating a card nobody can act on anymore")
end

print("")
print("set_deck_pulse is wired all the way through")
check("game.script exposes self.set_deck_pulse via BL",
    game:find("self%.set_deck_pulse%s*=%s*function%(active%) BL%.set_deck_pulse%(self, active%) end") ~= nil)

local sdp_start = bl:find("function M%.set_deck_pulse%(self, active%)")
local sdp_end = sdp_start and bl:find("\nend\n", sdp_start)
local sdp_body = sdp_start and bl:sub(sdp_start, sdp_end and (sdp_end + 4) or nil)
check("set_deck_pulse is found", sdp_body ~= nil)
if sdp_body then
    check("targets the TOP deck card specifically",
        sdp_body:find("self%.deck%[#self%.deck%]") ~= nil)
    check("keys the running animation to that card's own go id",
        sdp_body:find("self%._deck_pulse_id") ~= nil,
        "so a card that has actually been drawn (a different game object) never gets an animation call aimed at a stale id")
    check("stops and resets scale when turned off or the top card changed",
        sdp_body:find("pcall%(go%.cancel_animations, current_id, \"scale\"%)") ~= nil
            and sdp_body:find("pcall%(go%.set, current_id, \"scale\", M%.CARD_SCALE%)") ~= nil,
        "otherwise the pulse could keep animating a card that already left the deck")
    check("loops rather than firing once",
        sdp_body:find("go%.PLAYBACK_LOOP_PINGPONG") ~= nil)
end

print("")
print("the tracking id is reset on a fresh game, not left stale")
check("game_state.lua's fresh_state clears _deck_pulse_id",
    gs:find("self%._deck_pulse_id = nil") ~= nil,
    "destroy_all deletes whatever card it was running on regardless of this — left set, the NEXT game's first check would touch a go id that no longer exists")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
