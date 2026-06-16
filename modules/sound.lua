-- Thin wrapper around the sound components mounted on controller.go / game.go.
-- Any script on the controller game object can call sound.play("play") etc.
-- Names map to the component ids declared in game.go (snd_<name>).

local M = {}

M.enabled = true

-- event name -> sound component id on game.go
local MAP = {
  shuffle   = "snd_shuffle",
  play      = "snd_play",
  play_cut  = "snd_play_cut",
  play20    = "snd_play20",
  play30    = "snd_play30",
  play50    = "snd_play50",
  draw      = "snd_draw",
  pick      = "snd_pick",
  coin      = "snd_coin",
  win       = "snd_win",
  lose      = "snd_lose",
  alert     = "snd_alert",
  notify    = "snd_notify",
  move_deck = "snd_move_deck",
  confetti  = "snd_confetti",
}

-- Play a sound by event name. `gain` optional (0..1).
function M.play(name, gain)
  if not M.enabled then return end
  local id = MAP[name]
  if not id then return end
  -- "#id" addresses the sibling component on the same game object as the caller.
  pcall(msg.post, "#" .. id, "play_sound", { gain = gain or 1.0 })
end

function M.toggle()
  M.enabled = not M.enabled
  return M.enabled
end

return M