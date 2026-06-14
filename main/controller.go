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
components {
  id: "network"
  component: "/main/network.gui"
}
components {
  id: "incoming"
  component: "/main/incoming.gui"
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
  position {
    x: 640.0
    y: 360.0
    z: -0.9
  }
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
  position {
    x: 640.0
    y: 360.0
    z: -0.85
  }
  scale {
    x: 0.3
    y: 0.3
    z: 1.0
  }
}
embedded_components {
  id: "snd_shuffle"
  type: "sound"
  data: "sound: \"/assets/sounds/shuffling.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_play"
  type: "sound"
  data: "sound: \"/assets/sounds/play.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_play_cut"
  type: "sound"
  data: "sound: \"/assets/sounds/play_cut.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_play20"
  type: "sound"
  data: "sound: \"/assets/sounds/play20.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_play30"
  type: "sound"
  data: "sound: \"/assets/sounds/play30.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_play50"
  type: "sound"
  data: "sound: \"/assets/sounds/play50.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_draw"
  type: "sound"
  data: "sound: \"/assets/sounds/draw.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_pick"
  type: "sound"
  data: "sound: \"/assets/sounds/request_suit.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_win"
  type: "sound"
  data: "sound: \"/assets/sounds/win_alt.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_lose"
  type: "sound"
  data: "sound: \"/assets/sounds/lose.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_alert"
  type: "sound"
  data: "sound: \"/assets/sounds/alert_timer.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_notify"
  type: "sound"
  data: "sound: \"/assets/sounds/request.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_move_deck"
  type: "sound"
  data: "sound: \"/assets/sounds/move_deck.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_confetti"
  type: "sound"
  data: "sound: \"/assets/sounds/confetti.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_laugh_mzeei"
  type: "sound"
  data: "sound: \"/assets/sounds/laugh_mzeei.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_kawedemu"
  type: "sound"
  data: "sound: \"/assets/sounds/kawedemu.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_igoing"
  type: "sound"
  data: "sound: \"/assets/sounds/igoing.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_avuga_obula"
  type: "sound"
  data: "sound: \"/assets/sounds/avuga_obula.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_mbooko"
  type: "sound"
  data: "sound: \"/assets/sounds/mbooko.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_kasongo"
  type: "sound"
  data: "sound: \"/assets/sounds/kasongo.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_towedde"
  type: "sound"
  data: "sound: \"/assets/sounds/towedde.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_towedde_alt"
  type: "sound"
  data: "sound: \"/assets/sounds/towedde_alt.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_banamwe"
  type: "sound"
  data: "sound: \"/assets/sounds/banamwe.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_oh_my_god"
  type: "sound"
  data: "sound: \"/assets/sounds/ohh_my_god.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_abarongo"
  type: "sound"
  data: "sound: \"/assets/sounds/abarongo.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_eheh"
  type: "sound"
  data: "sound: \"/assets/sounds/eheh.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_i_wonder"
  type: "sound"
  data: "sound: \"/assets/sounds/i_wonder.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_kigozi"
  type: "sound"
  data: "sound: \"/assets/sounds/kigozi.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_olyaa"
  type: "sound"
  data: "sound: \"/assets/sounds/olyaa.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_connecting"
  type: "sound"
  data: "sound: \"/assets/sounds/connecting.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_bamukubye"
  type: "sound"
  data: "sound: \"/assets/sounds/bamukubye.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_omukwomu"
  type: "sound"
  data: "sound: \"/assets/sounds/omukwomu.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_snoring"
  type: "sound"
  data: "sound: \"/assets/sounds/snoring.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_i_cant_accept_that"
  type: "sound"
  data: "sound: \"/assets/sounds/i_cant_accept_that.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_togenda_kuba"
  type: "sound"
  data: "sound: \"/assets/sounds/togenda_kuba.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_tokirizibwa"
  type: "sound"
  data: "sound: \"/assets/sounds/tokirizibwa.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_goodbye"
  type: "sound"
  data: "sound: \"/assets/sounds/goodbye.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_suspense"
  type: "sound"
  data: "sound: \"/assets/sounds/suspense.ogg\"\n"
  "loopcount: -1\n"
  ""
}
embedded_components {
  id: "snd_found"
  type: "sound"
  data: "sound: \"/assets/sounds/found.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_fail"
  type: "sound"
  data: "sound: \"/assets/sounds/fail.ogg\"\n"
  ""
}
embedded_components {
  id: "snd_ping"
  type: "sound"
  data: "sound: \"/assets/sounds/ping.ogg\"\n"
  ""
}