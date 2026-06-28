# Whot port — status notes

This branch reskins the Matatu client into **Whot**: same game-mode shell
(Battle, Battle-vs-AI best-of, Elimination Chamber → Quick/Play/Battle-AI/
Tournament) but Whot rules, Whot deck and Whot card art, talking to the
`/whot` backend endpoints.

## Done (verified)

Pure-logic foundation (runs and was simulated headlessly — see below):

- `modules/config.lua` — `BASE_URL`/`WS_URL` now point at `/whot` and
  `/whot/ws`.
- `modules/card_rules.lua` — replaced with the Whot rule engine (shapes
  C/T/X/S/R + Whot wildcard W; Hold-On 1, Pick-Two 2, Pick-Three 5,
  Suspension 8, General-Market 14, Whot 20; non-stacking penalties;
  choose-shape). Old Matatu API names kept as harmless aliases
  (`CHOOSE_SUIT → CHOOSE_SHAPE`, `RULES_JOKERS`, `is_master_card`,
  `is_joker`, …) so existing call sites don't break.
- `modules/deck.lua` — builds the 54-card Whot deck (5 Whots).
- `modules/card_defs.lua` — Whot frame names (`"<v><s>"`, e.g. `10T`, `20W`),
  `BACK_DEFAULT` back, Whot card/shape names.
- `modules/ai_player.lua` — replaced with the Whot AI (ported from
  `whot_ai.lua`), plus a `decide(state, hand, has_drawn)` /
  `best_suit_for_hand` / `score_card` adapter so the existing offline and
  tournament drivers keep calling it unchanged.
- `modules/rules_eval.lua` — Whot evaluation (no cutting card, chosen-shape
  getter, Whot hand scoring, sound mapping onto the existing sound atlas).
- `modules/game_logic.lua` — self-contained offline engine now handles
  Hold-On / General-Market / Suspension / choose-shape and a Whot starter.
- Card art: Whot PNGs copied to `assets/cards/whot/`, `assets/cards/cards.atlas`
  regenerated to reference them, `card.go` default frame → `BACK_DEFAULT`,
  `card.script` no longer swaps per-theme sheets.
- `main/suit_select.gui_script` — now a 5-shape (C/T/X/S/R) selector.

### Verification

`lua` simulation of `game_logic.lua` (pure Lua, no Defold deps): 200 offline
games AI-vs-AI all reach `GAME_OVER` with no stalls/crashes, balanced 100/100
win split, deck = 54 cards / 5 Whots, and targeted rule assertions (Whot
wildcard, Hold-On, Pick-Two transfer, General-Market, forced-shape match)
pass. All touched `.lua` files pass `luac -p`.

## Remaining (board-controller integration — not yet wired)

The shared online/offline board controller is still Matatu-shaped in places:

- `main/game.script` + `modules/offline_handler.lua`: the `result.type`
  handling renders CHOOSE_SHAPE (via the alias) but does **not** yet branch on
  `HOLD_ON` / `GENERAL_MARKET` for the animated board, and the offline AI's
  chosen shape from `AI.decide(...).suit` isn't threaded into `play_card`.
- `modules/online_handler.lua` / `modules/game_flow.lua`: online rendering of
  Whot effects + chosen-shape badge needs the same treatment. (The backend
  already validates Whot moves — see below — so this is presentation only.)
- `modules/tournament4.lua` / `t4_ui.lua`: tournament board reuse of the above.
- Theming: `themes.*` still references the Matatu drago/batman sheets (left
  intact so the project still builds); Whot ships a single deck art set.

## Backend (be_matatu)

The Whot rule engine, move handler and AI already exist (`src/whot/**`) and the
server mounts `/whot` + `/whot/ws`. This branch adds **path-based game
detection** (`getGameFromPath`) so hitting `/whot` selects the Whot rules even
on a raw-IP host (previously detection was host-only, so a dev IP fell back to
Matatu). HTTP `setGameContext` and the WS upgrade now prefer the path and fall
back to host for `/api`.
