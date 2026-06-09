components {
  id: "controller"
  component: "/main/controller.script"
}
components {
  id: "lobby"
  component: "/main/lobby.gui"
}
components {
  id: "auth"
  component: "/main/auth.gui"
}
components {
  id: "profile"
  component: "/main/profile.gui"
}
components {
  id: "online"
  component: "/main/online.gui"
}
components {
  id: "themes"
  component: "/main/themes.gui"
}
components {
  id: "payments"
  component: "/main/payments.gui"
}
components {
  id: "tournaments"
  component: "/main/tournaments.gui"
}
components {
  id: "game"
  component: "/main/game.gui"
}
components {
  id: "game_logic"
  component: "/main/game.script"
}
components {
  id: "card_factory"
  component: "/main/card.factory"
}
components {
  id: "suit_select"
  component: "/main/suit_select.gui"
}
components {
  id: "gameover"
  component: "/main/gameover.gui"
}
embedded_components {
  id: "background"
  type: "sprite"
  data: "default_animation: \"texture_bg\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/ui/ui.atlas\"\n"
  "}\n"
  ""
  position { x: 640.0  y: 360.0  z: -0.9 }
}
embedded_components {
  id: "logo"
  type: "sprite"
  data: "default_animation: \"bg_logo\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/ui/ui.atlas\"\n"
  "}\n"
  ""
  position { x: 640.0  y: 360.0  z: -0.85 }
  scale { x: 0.6  y: 0.6  z: 1.0 }
}
embedded_components {
  id: "snd_shuffle"
  type: "sound"
  data: "sound: \"/assets/sounds/shuffling.ogg\"\n"
}
embedded_components {
  id: "snd_play"
  type: "sound"
  data: "sound: \"/assets/sounds/play.ogg\"\n"
}
embedded_components {
  id: "snd_play_cut"
  type: "sound"
  data: "sound: \"/assets/sounds/play_cut.ogg\"\n"
}
embedded_components {
  id: "snd_play20"
  type: "sound"
  data: "sound: \"/assets/sounds/play20.ogg\"\n"
}
embedded_components {
  id: "snd_play30"
  type: "sound"
  data: "sound: \"/assets/sounds/play30.ogg\"\n"
}
embedded_components {
  id: "snd_play50"
  type: "sound"
  data: "sound: \"/assets/sounds/play50.ogg\"\n"
}
embedded_components {
  id: "snd_draw"
  type: "sound"
  data: "sound: \"/assets/sounds/draw.ogg\"\n"
}
embedded_components {
  id: "snd_pick"
  type: "sound"
  data: "sound: \"/assets/sounds/request_suit.ogg\"\n"
}
embedded_components {
  id: "snd_win"
  type: "sound"
  data: "sound: \"/assets/sounds/win_alt.ogg\"\n"
}
embedded_components {
  id: "snd_lose"
  type: "sound"
  data: "sound: \"/assets/sounds/lose.ogg\"\n"
}
embedded_components {
  id: "snd_alert"
  type: "sound"
  data: "sound: \"/assets/sounds/alert_timer.ogg\"\n"
}
embedded_components {
  id: "snd_move_deck"
  type: "sound"
  data: "sound: \"/assets/sounds/move_deck.ogg\"\n"
}
embedded_components {
  id: "snd_confetti"
  type: "sound"
  data: "sound: \"/assets/sounds/confetti.ogg\"\n"
}