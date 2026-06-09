# Matatu — Defold

A [Defold](https://defold.com) port of the Matatu card game, migrated from the
original Godot project (`../`, GDScript). It keeps the same backend and realtime
protocol while re-implementing the client in Lua.

The lobby has the two requested entry points:

| Button          | Mode    | What it does                                                            |
| --------------- | ------- | ----------------------------------------------------------------------- |
| **QUICK PLAY**  | Offline | Full game vs a built-in **AI opponent** — no server needed.             |
| **PLAY ONLINE** | Online  | Connects to the live backend over **WebSockets**, lists online players, and plays real-time multiplayer. |

## Run it

1. Install the [Defold editor](https://defold.com/download/) (1.9.x or newer).
2. `File → Open Project` → select `defold/game.project`.
3. The editor auto-fetches the `extension-websocket` dependency (needs internet).
   You can also force it with `Project → Fetch Libraries`.
4. `Project → Build` (Cmd/Ctrl-B).

> The project content was verified to compile with the official `bob.jar`
> (Defold 1.12.4). Building the native engine (for the websocket extension) is
> done automatically by the editor / Defold's build server.

## Project layout

```
game.project              bootstrap, display, websocket dependency
input/game.input_binding  touch + escape
main/
  main.collection         single bootstrap collection
  controller.go/.script   owns singletons, routes WS events, switches screens
  lobby.gui/.gui_script    Quick Play / Play Online + online players list
  game.gui/.gui_script     the card board (renders offline AND online)
modules/                  pure Lua (engine-agnostic, unit-tested)
  card_rules.lua          faithful port of card_rules.gd (the rules engine)
  deck.lua                54-card deck + shuffle
  ai_player.lua           NEW offline AI (decision logic on top of the rules)
  game_logic.lua          offline authority: deal/turn/penalty/suit/reshuffle/win
  websocket_manager.lua   realtime client (port of WebSocketManager.gd)
  api_service.lua         REST client (port of ApiService.gd) — device login etc.
  aes.lua + util.lua      AES-256-CBC decrypt of the server's game state
  json_util.lua           JSON encode + decode
  config.lua              DOMAIN, WS URL, app version, AES secret, stakes
  ui.lua / app_state.lua  small helpers / shared state
assets/cards, assets/ui   sliced card sprites + UI atlas
fonts/                    fonts + .font definitions
tools/                    slice_cards.py, test_offline.lua
```

## How it talks to the backend

`modules/config.lua` holds the same endpoints as the Godot app:

- REST: `https://api.matatuleague.com/matatu`
- WebSocket: `wss://api.matatuleague.com/matatu/ws`
- Game state is **AES-256-CBC** encrypted; `aes.lua` decrypts it with the same key.

Online flow: `device_login` → `IDENTIFY` over the socket → `ONLINE_USERS` populate
the lobby → tap a player to send a `GAME_REQUEST` → on accept the server sends the
(encrypted) game state and the board opens. Moves are sent as `MOVE` messages and
the board re-renders from the server's authoritative state.

> First-time online sign-in (phone + OTP) still happens in the original app; this
> port logs in by device. If the server replies `AUTH_REQUIRED`, register the
> device once via the main app.

## The offline AI

`ai_player.decide()` evaluates every card in hand through the same rules engine the
real game uses, then picks the best legal play (shed jokers/penalty cards when
safe, keep aces as wildcards, prefer suits it holds many of, chain skip cards in
heads-up). When no card is legal it draws, and serves penalties by drawing. It runs
entirely client-side via `game_logic.lua`.

## Verification

```bash
# Offline engine + AI + rules — plays 500 complete games, asserts no errors/stalls
lua5.4 tools/test_offline.lua
```

Also verified during development: the Lua AES-256-CBC decrypt against a
PyCryptodome reference, JSON encode/decode round-trips, and the full
encrypted-gameState decode path through `websocket_manager.extract_game_state`.

## Scope

Implemented end-to-end: lobby (Quick Play + Play Online), offline AI game, online
realtime multiplayer (identify, online list, challenge/accept, moves, game over),
backend device login, encrypted state decoding, the full Matatu rules
(jokers/penalties/aces/skips/master card/reshuffle).

Intentionally not ported from the Godot app (secondary systems): tournaments,
shop/themes, payments UI, daily bonus, profile editor, emoji chat, OTP sign-in
screen. The modules and screen routing are structured so these can be added later.
# matatu_defold
# matatu_defold
# matatu_defold
# matatu_defold
