# Fjord Trader — Roadmap

Each milestone ends with something you can open and run in Godot. Rules come from `DESIGN.md`.

| # | Milestone | You can… |
|---|---|---|
| 1 ✅ | **Foundation** | Generate a world from a seed and watch its markets live: cities, names, routes, prices drifting in real time, pause and 1×/2×/4× speed, save/load. |
| 2 ✅ | **First playable** | Pick your two home lines, produce, buy and sell, send wagons and barges on one-off trips, pay upkeep, tax and storage; see everything in the forecast panel. |
| 3 ✅ | **Growing the city** | Food, population growth, stages, infrastructure, line upgrades, retooling, input priority and reserves. |
| 4 ✅ | **Trade routes** | Set up repeating routes with price limits and lot caps; see profit per route. |
| 5 | **A living world** | Visible NPC routes, NPC cities growing and shrinking (3E), NPC sales into your home market, buy offers with the inbox and auto-pause. |
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

## Milestone 2 — First playable ✅ (done)

- Choose what your two home lines produce (free the first time; retooling afterwards: 25% of the line, 14 days).
- Continuous production into the warehouse, with cost basis (produced lots count at 0.75 × base).
- Trip planner: vehicle, destination, goods to sell there and to buy there; trades at arrival prices; auto-return.
- Cheap per-day trip fees; vehicle upkeep, tax and storage fee charged continuously with exact coin accounting.
- Home market: instant sales at 75% prices.
- Buy wagons and barges.
- Schematic world map: land, sea, fjords, terrain, routes by type, the selected city's routes, planned route,
  vehicles on the move, price overlay per good.
- Finances tab (forecast panel): running costs, committed fees, runway, this and last month's books.
- 124 headless engine tests.

Notes from building it:
- Retooling (planned for Milestone 3) was pulled forward so production can be changed.
- Saves from Milestone 1 can't be loaded (the state layout changed); the game says so instead of breaking.

## Milestones 3 and 4 — Growing the city, trade routes ✅ (done together after the Milestone 2 playtest)

- Food consumption, growth (rates, bonuses, cap, starvation), stages, a growth breakdown with time to next stage.
- Infrastructure: housing (+15% people at once), harbor (−10% water fees), roads (+25% wagon speed),
  retooling works; one of each per stage.
- Production access by site and stage, with a "What can I make?" overview explaining every good.
- Add lines, upgrade lines (15 and 20 lots/month), switch lines between tiers (pay the difference),
  input priority (line order), processed goods consume inputs and wait when they run out, warehouse reserves.
- Multi-stop routes: load at home, any number of stops with sell/buy, lot caps and price limits, run once or
  repeat; stop after the current loop; per-loop cash and profit against cost; committed fees in the forecast.
- 1920×1080 layout, scaled to the window; F11 fullscreen.
- 223 headless engine tests.

Notes:
- NPC city growth (3E) moved to Milestone 5, since it depends on NPC trade.
- Saves from Milestone 2 can't be loaded (state layout changed).

## Milestone 5 — A living world (next)

NPC trade routes with visible vehicles, NPC deliveries into your home market (so you can buy at home),
NPC buy offers with an inbox and auto-pause, NPC cities growing and shrinking with supply.
