# Fjord Trader — Design Document

This is the single source of truth for the game's rules. The original ruleset lives in
[`docs/original-ruleset.md`](docs/original-ruleset.md); every decision below **overrides** it where they differ.
Each coding session starts by reading this file. If a rule isn't written here or in the original ruleset,
it isn't decided yet — ask, don't improvise.

## Project setup

- Engine: **Godot 4.7.x, Standard version** (no .NET), language **GDScript**.
- Presentation: **interactive dashboard** (tables, panels, buttons). Map/visual polish is a later phase.
- **Real-time strategy, not turn-based** (overrides the original ruleset's turn structure). Exact time model is in Batch 2b.
- Architecture:
  - `engine/` — pure rules logic, no UI. The simulation advances in fixed ticks: `tick(state, commands) -> new_state + log`.
  - `data/` — goods, cities, events and balance numbers as data files, not hard-coded.
  - `ui/` — dashboard scenes; reads state, submits orders, never contains rules.
  - `tests/` — automated tests for the engine math.
- Randomness: one **seeded RNG** stored in the save, so any save + seed reproduces the same game.
- **No fixed story content.** The original ruleset was written for a GM-run story game; city names, the world map and
  starting conditions are generated procedurally from the seed (Batch 2b).

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

### Batch 2 — Transport, routes and risk ✅

**2A. Player route price limits** ✅
Every stop on a player route has optional limits: sell only above a minimum price, buy only below a maximum
price, and a lot cap per visit. Stops whose limits aren't met are skipped and logged.

**2B. NPC route strength** ✅
NPC routes are capacity-limited: one vehicle per route, 10–30 lots per trip; the number of NPC routes a city runs
scales with its population. NPC trade narrows price gaps but never erases them.

**2C. NPCs share the player's risks** ✅
Storms, fjord mishaps and frozen fjords affect NPC vehicles exactly like the player's.

**2D. Transport defaults** ✅
- **No bandits.** Land routes carry no cargo-loss risk.
- Fjord mishap: lose 10–30% of cargo, or a delay.
- Ocean storm: 1 in 3 total loss of vessel and cargo; otherwise 25% cargo lost plus a delay.
- Insurance (8% of cargo value) covers cargo only, never the vehicle.
- Trip fees are charged per leg on departure.
- Wagon upgrades: +5 capacity for 100,000 each, max 2 (20 lots).
- **Land route downsides** (replacing bandits): wagons are slowed by seasonal **spring mud**; the **roads**
  infrastructure upgrade speeds up wagons instead of reducing bandit risk.

**2E. Exploration removed** ✅
All cities in the generated world are known from the start.

### Batch 2b — Real-time model and world generation ✅

**2b-A. Real-time with pause and speed controls** ✅
Speeds 1×/2×/4×. The game runs unless the player pauses it or presses **Esc**, which opens settings
(settings menu designed later).

**2b-B. Clock speed** ✅
At 1×, **1 game day = 10 seconds** (1 month = 5 minutes, 1 year = 1 hour).
**A long, slow game is intended.** At the original growth rates one stage takes ~33 game months at best
(~2.75 hours at 1×). Growth tuning is reviewed in Batch 3 with that goal in mind.

**2b-C. Continuous settlement** ✅
Everything settles continuously: production, vehicle movement, price drift and recovery, upkeep, tax, loan
interest and population growth. Monthly rates in the rules are pro-rated per simulation step.
- Implementation: fixed simulation step of 1 game hour (~0.42 s at 1×). Money is stored as whole coins;
  fractional charges accumulate in a remainder and are deducted as whole coins, so no money is ever lost to rounding.
- Distances are **days of travel**, from the generated map and the vehicle type.
- **Forecast panel** (required UI): shows current prices, loans, interest, upkeep, taxes and projected income
  and costs per day and per month, so the player can plan and is never surprised by a cost.

**2b-D. NPC offers in real time** ✅
Offers arrive in an inbox and expire after ~10 game days. A setting controls **auto-pause on offers**
(default: **on**). With it off, offers wait in the inbox while time runs.

**2b-E. World generation** ✅
- ✅ Number of cities is a new-game setting: default 10, range 6–16.
- ✅ Names are generated from syllables in two or three culture styles (northern, southern, eastern).
- ✅ Geography drives production and wants (coast → fish, mountains → ore, south → wine/spices, …).
- ✅ Starts are deliberately unequal between seeds. Home's production options depend on its site; the only
  guarantee is that home can produce **one food good and one other resource**.
- ✅ Home site: always coastal with inland access; whether the coast is a **fjord** or **open ocean** varies by seed.
  - "Fjord" routes are renamed **sheltered-water routes** (barges, coastal vessels). Both home types have them.
  - Fjord home: safer waters, but its fjord can freeze in winter and it takes extra days to reach the open sea.
  - Ocean-coast home: shorter ocean trips and no freezing, but more exposure to storms.
- ✅ Every world guarantees that **Spices and Gold exist somewhere** (possibly far away), so no seed silently
  locks out Tier 4 Jewelry or Medicine.

### Batch 3 — Population, food and growth ✅

**3A. Food** ✅
- Each city eats **1 lot of Grain or Fish per 2,500 population per month**, deducted continuously from the warehouse.
- No food in stock → growth stops. After **90 days** without food, population declines **2% per month** until food returns.

**3B. Growth formula** ✅ (per month, pro-rated continuously, **capped at 5%**)
| Condition | Growth |
|---|---|
| City is fed | 2% (base; no growth at all if unfed) |
| ≥ 3 months of food in stock | +1% |
| No loans and treasury ≥ 1M × 10^(stage − 1) | +1% |
| Housing, harbor, roads (one each per stage) | +0.5% each |
| Food variety: both Grain and Fish in stock | +0.5% |

Infrastructure costs ~1M / 10M / 100M / 1B per upgrade at Stages 1–4. Harbor also cuts sheltered-water and ocean
trip fees by 10%; roads speed up wagons (see 2D).

**3C. Production line upgrades** ✅
Each line can be upgraded twice: output **10 → 15 → 20 lots/month**. The first upgrade costs **2×** the line's
purchase price, the second **4×** (starting Tier 1 lines count as 500,000, so 1,000,000 and 2,000,000).

**3D. Stages never regress** ✅
A city that falls below its stage's population threshold keeps its stage and its lines.

**3E. NPC cities grow and shrink** ✅
NPC city populations change slowly based on how well their wants are supplied (by the player or NPC routes).
Population feeds back into price-impact step size (1B) and how many NPC routes the city runs (2B).
### Batch 4 — Money: taxes, loans, net worth ✅

**4A. Net worth** ✅
`net worth = treasury + inventory + vehicles + production lines (incl. upgrades) + infrastructure − outstanding loans`
- **Loans are subtracted.** (Fix to the original formula: without it, borrowing raised net worth, which raised the
  loan limit, which allowed more borrowing.)
- **Inventory at cost basis:** bought goods count at their weighted-average purchase cost; produced goods count at
  0.75× base. Buying can never inflate net worth; only profitable selling can. Average cost per good is also used
  to show real profit per route in the UI.
- Vehicles, lines, upgrades and infrastructure count at purchase cost (starting lines 500,000 each).

**4B. Tax and storage** ✅ (both continuous, pro-rated)
- Tax: **1% of treasury per month**, or the stage minimum if higher (25,000 / 250,000 / 2,500,000 / 25,000,000
  per month at Stages 1–4).
- Storage fee: **0.5% of inventory value (cost basis) per month.**
- Lines, vehicles and infrastructure are not taxed (vehicles pay upkeep: ~2% of value per month).

**4C. Loans, emergency credit and default** ✅
- Loans: **3% interest per month**, accrued continuously, up to 50% of net worth, repayable at any time.
- Emergency loan: if a cost would push the treasury below zero, an emergency loan opens automatically at
  **5.5% per month**, within the same 50% limit. The forecast panel warns before this happens.
- Default (limit reached and still short): creditors seize warehouse goods, then vehicles, selling them at 50% of
  value until the debt is covered; all cities pay the player 10% less for 12 months. If net worth is still
  negative afterwards: game over.
- Having any loan forfeits the +1% treasury-health growth bonus (3B).

**4D. Victory** ✅
Reaching **10,000,000,000** net worth shows a victory screen; the player can continue in sandbox mode.
### Batch 5 — Production and tier balance ✅

**5A. Rebalanced processed goods** ✅ (overrides the original price list; unlisted goods keep their original base price)
Principle: line slots are the scarce resource, so lines within a tier should earn similar margins per lot at base
prices. Choice then depends on geography, inputs and markets.

| Good | Base price | Inputs per lot | Margin per lot at base |
|---|---|---|---|
| Cloth | **300,000** | 2 Wool | 160,000 |
| Steel | 900,000 | 2 Iron Ore + 1 Coal | 480,000 |
| Glass | **650,000** | 2 Stone + 1 Timber | 490,000 |
| Furniture | **950,000** | 3 Timber + 1 Cloth | 470,000 |
| Tools | **1,450,000** | 1 Steel + 1 Timber | 490,000 |
| Machinery | 12,000,000 | 3 Steel + 2 Tools + 2 Coal | 6,160,000 |
| Ships | 25,000,000 | **20 Timber + 8 Steel + 6 Cloth + 6 Tools** | 6,100,000 |
| Jewelry | **14,000,000** | 2 Gold + 1 Tools | 6,550,000 |
| Medicine | **10,500,000** | 2 Spices + 1 Wine + 1 Glass | 6,550,000 |

**5B. Ships and vehicle classes** ✅
- 1 lot of Ships = 1 ocean ship: commission it into the fleet or sell it.
- Capacities: wagon 10 (upgradable to 20), barge 20, coastal vessel 60, ocean ship 250.

**5C. Vehicle availability by stage** ✅
Wagons and barges from Stage 1; coastal vessels from Stage 2; ocean ships from Stage 3 (shipyard); self-built
Ships from Stage 4. Spices and Gold are therefore a Stage 3 milestone.

**5D. Retooling lines** ✅
A line can switch to another good its city can produce for **25% of the line's price** and **14 days** of downtime.
Each city can buy one **retooling upgrade per stage** from Stage 2, cutting downtime 14 → 12 → 10 → 7 days.
Upgrade cost: **5M / 50M / 500M** at Stages 2 / 3 / 4.

**5E. Input priority and reserves** ✅
- When lines compete for the same input, the player sets their priority order.
- Each good has a player-set **"keep at least X lots"** floor that trade routes and offers respect.
- A line consumes inputs as it produces; if they run out, it stalls until inputs arrive.
### Batch 6 — Events ✅

**6A. Frequency** ✅ About one event per game month on average.

**6B. Catalogue** ✅ (numbers live in a data file for tuning)

| Event | Effect | Duration | Warning |
|---|---|---|---|
| Festival | A city wants a good at **1.5×** listed. Goods scale with city size: small towns celebrate with food and drink (Grain, Fish, Salt, Wine), large cities with luxuries (Furniture, Jewelry, Glass). | 1 month | announced |
| Delivery contract | Optional fixed-price order (see 6D) | until deadline | announced |
| Hard winter | Fjords freeze one month earlier and thaw one month later | one winter | announced |
| Crop failure | One **NPC** city's Grain or Fish price ×1.6; that city's growth −1% | 3–4 months | announced |
| Gold rush | The Gold city: Gold price ×0.7, population +10%, Tools and Grain become wants | 6 months | sudden |
| Migration wave | One city's population +5% (can be the player's) | instant | sudden |
| Price shock | One good ×1.3 or ×0.75 in every city | 2–3 months | sudden |
| Guild subsidy | Player infrastructure costs −20% | 2 months | sudden (shows duration) |

**6C. No disasters** ✅
No plagues, fires, mine collapses or similar events. Events never damage the player's cities: crop failures only
hit NPC cities, and events that touch the player (migration wave, guild subsidy) are positive.
(Transport risk from 2D — ocean storms, fjord mishaps, freezing, spring mud — stays; it is a rule, not an event.)

**6D. Announcements and contract flow** ✅
- Upcoming festivals and contracts are announced in a **news feed** ahead of time.
- Contracts are **optional**: the player accepts or declines (inbox; auto-pause setting applies).
- Flow: announced in news (~15–30 days ahead) → offer opens → if accepted, the delivery window
  starts **3–5 days later** → lots delivered in the window are paid the contract price → missing the full
  quantity gives **−5% on sales in that city for 3 months**. Declining has no penalty.

**6E. Reputation** ✅ No reputation system for now; penalties are temporary price modifiers.

### Not yet reviewed ⬜
- **Founding new cities** (original section 8): site selection on the generated map, costs, starting state.
  Review before the milestone that builds it.

## Open design problems (from the initial review)

1. ~~Net-worth farming~~ — resolved by cost-basis inventory (4A).
2. ~~Untaxed hoarding~~ — resolved by the storage fee (4B).
3. ~~Pacing~~ — resolved: a long game is intended (2b-B); line upgrades (3C) give progression within each stage.
4. ~~Tier 4 balance~~ — resolved by the rebalance (5A).

## World generation (replaces the fixed starting world)

The fixed six cities from the initial GM setup are retired. The world, its city names, positions, routes,
production and wants are generated from the seed. Rules are being decided in Batch 2b.
