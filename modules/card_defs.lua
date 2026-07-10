-- card_defs.lua — build-time game dispatcher (see modules/game_mode.lua).
-- The real per-game implementations live in modules/games/<game>/card_defs.lua;
-- M.GAME picks one when this module is first required, so every existing
-- `require "modules.card_defs"` automatically gets the active game's engine.
-- KADI note: Kadi plays with the standard 54-card deck and, for now, the
-- Matatu client engine (its own special-card rules are not ported
-- client-side yet — the backend /kadi engine is authoritative online).
local GameMode = require "modules.game_mode"
if GameMode.is_whot() then
    return require "modules.games.whot.card_defs"
end
return require "modules.games.matatu.card_defs"
