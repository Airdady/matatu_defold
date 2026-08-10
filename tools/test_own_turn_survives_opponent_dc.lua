-- OPPONENT DISCONNECTS, MY OWN CARDS GO DEAD.
--
--   Run: lua tools/test_own_turn_survives_opponent_dc.lua
--
-- Reported: the opponent drops mid-game while it's this player's OWN turn,
-- and their cards stop responding until the opponent either reconnects or
-- the grace period runs out — their own valid turn held hostage by someone
-- else's connection, even though the server processes their move exactly
-- the same regardless of the opponent's connection state.
--
-- ROOT CAUSE
--
-- ws_player_dc's conn_overlay unconditionally claimed the "network" modal
-- slot (app_state.modal_open("network")), which app.input_blocked() —
-- checked first thing in on_input — swallows every board tap for, whoever's
-- turn it actually is.
--
-- FIX, IN TWO PARTS
--
--   1. The initial claim is now conditional: block_input = not
--      is_player_turn(), computed the moment the overlay goes up.
--   2. That alone isn't enough — the overlay can go up while it's still the
--      OPPONENT's turn (a grace-period timeout AI-covers their move) and
--      THEN the turn hands straight to this player, still mid-disconnect.
--      A one-shot watchdog in update() releases the claim the moment the
--      turn actually becomes this player's, tracked via
--      self._opp_dc_grace_active.

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

local game = slurp("main/game.script")
local overlay = slurp("modules/overlay_ui.lua")

print("")
print("ws_player_dc computes block_input from the current turn, not a fixed true")

local dc_start = game:find('hash%("ws_player_dc"%)')
local dc_end = dc_start and game:find('hash%("ws_player_rc"%)', dc_start)
local dc_body = dc_start and game:sub(dc_start, dc_end and (dc_end - 1) or nil)

check("ws_player_dc handler is found", dc_body ~= nil)
if dc_body then
    check("passes block_input = not self.is_player_turn() to conn_overlay",
        dc_body:find("block_input = not self%.is_player_turn%(%)") ~= nil,
        "otherwise the overlay always claims the input block regardless of whose turn it is")
    check("marks the grace as active for the watchdog below to find",
        dc_body:find("self%._opp_dc_grace_active = true") ~= nil)
end

print("")
print("ws_player_rc clears the flag once the disconnect episode resolves")
local rc_start = game:find('hash%("ws_player_rc"%)')
local rc_end = rc_start and game:find("\n    elseif message_id", rc_start + 1)
local rc_body = rc_start and game:sub(rc_start, rc_end and (rc_end - 1) or nil)
check("ws_player_rc handler is found", rc_body ~= nil)
check("resets self._opp_dc_grace_active",
    rc_body ~= nil and rc_body:find("self%._opp_dc_grace_active = false") ~= nil,
    "otherwise a later disconnect episode could read a stale flag from a previous one")

print("")
print("update()'s watchdog releases the block once it becomes this player's turn")
local wd_pos = game:find("self%._opp_dc_grace_active and now_my_turn")
check("the watchdog condition exists", wd_pos ~= nil)
if wd_pos then
    local wd_body = game:sub(wd_pos, wd_pos + 300)
    check("releases the flag (one-shot, not re-armed)",
        wd_body:find("self%._opp_dc_grace_active = false") ~= nil)
    check("actually closes the network modal slot",
        wd_body:find('app%.modal_close%("network"%)') ~= nil,
        "is_player_turn()'s own separate gate on card taps covers the rest — this only has to release, never re-claim")
end

print("")
print("set_conn_overlay only skips claiming the block — never force-closes it")
local sco_start = overlay:find("function M%.set_conn_overlay")
local sco_end = sco_start and overlay:find("\nfunction M%.show_ai_notice", sco_start)
local sco_body = sco_start and overlay:sub(sco_start, sco_end and (sco_end - 1) or nil)
check("set_conn_overlay is found", sco_body ~= nil)
if sco_body then
    check("only calls modal_open when block_input is not explicitly false",
        sco_body:find("if opts%.block_input ~= false then") ~= nil
            and sco_body:find('app_state%.modal_open%("network"%)') ~= nil)
    check("never calls modal_close(\"network\") from the block_input branch",
        not (sco_body:match("if opts%.block_input ~= false then.-end") or ""):find('modal_close'),
        "\"network\" is a single shared slot main/network.gui_script also claims for this device's own connectivity — force-closing it here could silently unblock an unrelated, more serious concern")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
