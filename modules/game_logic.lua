-- game_logic.lua — build-time game dispatcher (see modules/game_mode.lua).
-- The real per-game implementations live in modules/games/<game>/game_logic.lua;
-- M.GAME picks one when this module is first required, so every existing
-- `require "modules.game_logic"` automatically gets the active game's engine.
-- KADI note: Kadi plays with the standard 54-card deck and, for now, the
-- Matatu client engine (its own special-card rules are not ported
-- client-side yet — the backend /kadi engine is authoritative online).
local GameMode = require "modules.game_mode"
if GameMode.is_whot() then
    return require "modules.games.whot.game_logic"
end
return require "modules.games.matatu.game_logic"
