# Fjord Trader — Roadmap

Each milestone ends with something you can open and run in Godot. Rules come from `DESIGN.md`.

| # | Milestone | You can… |
|---|---|---|
| 1 ✅ | **Foundation** | Generate a world from a seed and watch its markets live: cities, names, routes, prices drifting in real time, pause and 1×/2×/4× speed, save/load. |
| 2 | **First playable** | Pick your two home lines, produce, buy and sell, send wagons and barges on one-off trips, pay upkeep, tax and storage; see everything in the forecast panel. |
| 3 | **Growing the city** | Food, population growth, stages, infrastructure, line upgrades, retooling, input priority and reserves. |
| 4 | **Trade routes** | Set up repeating routes with price limits and lot caps; see profit per route. |
| 5 | **A living world** | Visible NPC routes, NPC cities growing and shrinking, NPC sales into your home market, buy offers with the inbox and auto-pause. |
| 6 | **Money** | Loans, emergency credit, default, cost-basis net worth, victory screen. |
| 7 | **Risk and events** | Storms, freezing, mud, insurance; festivals and delivery contracts with the news feed. |
| 8 | **The wider world** | Tier 2–4 production chains, coastal vessels, shipyard and ocean ships, building Ships, founding new cities (needs design review first). |
| 9 | **Polish** | Esc settings menu, UI polish, balance passes from playtesting. |

## Milestone 1 — Foundation ✅ (done)

- Godot 4.7 project skeleton: `engine/`, `data/`, `ui/`, `tests/`.
- Data files: goods (prices, tiers, inputs), balance numbers.
- Seeded RNG stored in the game state.
- World generator: city count setting, syllable-based names in culture styles, geography → production and wants,
  map positions → travel days by route type, home site (fjord or ocean coast) with the 2b-E guarantees.
- Game clock: 1 game day = 10 s at 1×, 1-hour simulation steps, pause, 1×/2×/4×.
- Markets: local modifiers, ±3% monthly drift, recovery, size-scaled price impact, home market (×0.75).
- Save/load to a file.
- Headless tests for the generator guarantees and the price math.
- Minimal dashboard: city list, price table, clock and speed controls.

Notes from building it:
- Travel uses the best path per route type, possibly through other cities (a wagon can't sail).
- The mainland always has a connected road network (a road to each city's nearest neighbour).
- Saves are binary for exactness; Godot's JSON parser can change floats by one bit.

## Milestone 2 — First playable (next)

Choose two home production lines; production; warehouse; buy and sell at cities; one-off trips with the starting
wagon and barge; upkeep, tax and storage fee; the forecast panel.
