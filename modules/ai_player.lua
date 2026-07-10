-- ai_player.lua — build-time game dispatcher (see modules/game_mode.lua).
-- The real per-game implementations live in modules/games/<game>/ai_player.lua;
-- M.GAME picks one when this module is first required, so every existing
-- `require "modules.ai_player"` automatically gets the active game's engine.
-- KADI note: Kadi plays with the standard 54-card deck and, for now, the
-- Matatu client engine (its own special-card rules are not ported
-- client-side yet — the backend /kadi engine is authoritative online).
local GameMode = require "modules.game_mode"
if GameMode.is_whot() then
    return require "modules.games.whot.ai_player"
end
return require "modules.games.matatu.ai_player"
