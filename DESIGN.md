# Fjord Trader — Design Document

This is the single source of truth for the game's rules. The original ruleset lives in
[`docs/original-ruleset.md`](docs/original-ruleset.md); every decision below **overrides** it where they differ.
Each coding session starts by reading this file. If a rule isn't written here or in the original ruleset,
it isn't decided yet — ask, don't improvise.

## Project setup

- Engine: **Godot 4, Standard version** (no .NET), language **GDScript**.
- Presentation: **interactive dashboard** (tables, panels, buttons). Map/visual polish is a later phase.
- Architecture:
  - `engine/` — pure rules logic, no UI. A turn is `resolve_turn(state, orders) -> new_state + log`.
  - `data/` — goods, cities, events and balance numbers as data files, not hard-coded.
  - `ui/` — dashboard scenes; reads state, submits orders, never contains rules.
  - `tests/` — automated tests for the engine math.
- Randomness: one **seeded RNG** stored in the save, so any save + seed reproduces the same game.

## Decision log

Status: ✅ locked · 🟡 in discussion · ⬜ not yet reviewed

### Batch 1 — Markets ✅

**1A. Who sells what** ✅
Foreign cities only sell goods they produce. They buy any good.

**1B. Price impact scales with city size** ✅
Each lot traded moves that good's price in that city by a size-dependent step (compounding within a turn):

| City population | Step per lot |
|---|---|
| under 10,000 | 3.0% |
| 10,000 – 50,000 | 2.0% |
| 50,000 – 250,000 | 1.5% |
| 250,000+ | 1.0% |

Selling lot k pays `listed × 0.90 × (1 − step)^(k−1)`; buying lot k costs `listed × (1 + step)^(k−1)`;
each lot rounded to the nearest coin. Prices recover 25% of the gap toward their normal value per turn.
The same price impact applies to NPC trade.

**1C. Home market** ✅
- Ravnsfjord has its own market with its own surplus/neutral/want modifiers, drift and want changes,
  multiplied by **0.75** — a safety valve for cash, not a substitute for trading.
- **NPCs can sell to your home market:** foreign NPC traders deliver goods into Ravnsfjord's market stock,
  which the player can then buy (e.g. food).
- **NPCs can buy from you only by offer:** when a foreign trader wants goods from your warehouse, it makes
  an offer (good, quantity, price per lot) that the player **accepts or declines**. Nothing leaves the
  warehouse without consent.

**1D. Price drift** ✅
Every turn, each good's normal price in each city drifts randomly by up to **±3%**, staying inside its
band (surplus 0.60–0.85, neutral 0.90–1.10, want 1.25–2.00 × base).

**1E. Trade routes (NPC and player)** ✅
The game is about **establishing trade routes**, not racing for gaps.
- **NPC routes:** foreign cities run persistent trade routes with **visible** caravans and ships
  (cargo, destination, arrival turn). Routes form between a city's surplus and another city's wants when
  the gap persists, and dissolve when they stop paying. NPC trade moves prices through the normal
  price-impact rules, so NPCs and the player compete through prices, not reflexes.
- **Player routes:** the player can assign a vehicle to a standing route (e.g. "load Salt at home → sell at
  Grimsdal → buy Iron Ore → sell at Brekkhavn → return") that repeats every loop without re-ordering.
  Route details (price limits, stop conditions, how routes form/dissolve) are decided in Batch 2.
- One-off manual trips remain available alongside routes.

### Batch 2 — Transport, routes and risk ⬜
### Batch 3 — Population, food and growth ⬜
### Batch 4 — Money: taxes, loans, net worth ⬜
### Batch 5 — Production and tier balance ⬜
### Batch 6 — Events ⬜

## Open design problems (from the initial review)

1. Net worth can be farmed by buying below base and holding (inventory counts at base value). — Batch 4
2. The 1% treasury tax doesn't touch inventory, so hoarding goods is untaxed. — Batch 4
3. Pacing: ~33 turns per stage at the 5% growth cap, ~99 turns to Metropolis. — Batch 3
4. Tier 4 balance: Ships keep 75% margin at base prices, Jewelry 11%. — Batch 5

## Starting world (from the initial setup; may be revised)

| City | Route | Distance | Pop | Produces | Wants |
|---|---|---|---|---|---|
| Ravnsfjord (home) | — | — | 2,000 | (player's choice of 2 Tier 1) | — |
| Grimsdal | Land | 1 | 14,000 | Iron Ore, Coal, Stone, Timber | Grain, Salt |
| Kastelborg | Land | 2 | 38,000 | Grain, Wool, Cloth | Fish, Stone |
| Saltnes | Fjord | 1 | 9,000 | Salt, Fish, Stone | Timber, Wool |
| Brekkhavn | Fjord | 2 (frozen months 12–2) | 55,000 | Timber, Fish, Furniture | Grain, Iron Ore |
| Zafiran | Ocean | 4 | 180,000 | Spices, Cloth, Glass, Salt | Steel, Furniture |
| Valmora | Ocean | 5 | 90,000 | Gold, Wine, Grain | Tools, Wool |

Ravnsfjord is too far north for Wine.
