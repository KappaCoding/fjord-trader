# Fjord Trader

A long, slow real-time trading game: grow a small northern settlement into a trading empire by producing goods,
setting up trade routes and competing with NPC traders across a procedurally generated world.

- **Rules:** [`DESIGN.md`](DESIGN.md) — every design decision, in one place.
- **Plan:** [`ROADMAP.md`](ROADMAP.md) — milestones and what each one adds.

## Open and run it

1. Install **Godot 4.7.2** (Standard version, not .NET) from godotengine.org.
2. Get the latest code: in GitHub Desktop, **Fetch origin**, then **Pull origin**.
3. In Godot's Project Manager, click **Import**, select `project.godot` in this folder, then **Import & Edit**.
4. Press **F5** (or the ▶ button, top right) to run.

## How to play

1. **Choose production.** A new world starts paused and asks what your two lines should make. Each line makes
   10 lots a month (one every 3 days). **What can I make?** lists every good, whether your land and stage allow it,
   its inputs, and where it sells best.
2. **Grow your settlement.** Your people eat Grain or Fish from the warehouse; with no food there is no growth.
   The panel on the left shows the growth rate, what boosts it, what's missing, and when you reach the next stage.
   **Infrastructure** speeds things up: housing adds 15% people at once, roads make wagons faster, a harbor cuts
   water fees. Stage 2 (10,000 people) unlocks more lines and Tier 2 goods.
3. **Read the map.** Lines show the routes your vehicles use from home: dashed sand = road (wagons), light blue =
   sheltered water (barges), dotted blue = open sea (ocean ships, from Stage 3). Hollow cities can't be reached by
   any vehicle you own. Click a city for its market and *Getting there*.
4. **Find a market.** Pick a good under *Prices* (or click a good's name) to colour every city by what it pays.
5. **Trade with routes.** Press **Buy**/**Sell** in a city's market or **Plan route** on a vehicle. A route loads goods
   at home, visits one or more stops (sell some goods, buy others at each), and comes home. Tick **Repeat** to make it
   a standing trade route; *Stop after this loop* ends it. Price limits are optional (0 = none). **Keep** in the
   warehouse reserves lots that routes will never take.
6. **Watch your money.** The **Finances** tab shows running costs, fees already committed, how long your money
   lasts, and this and last month's books.

| Key / button | Does |
|---|---|
| Space or **Pause** | Pause / resume |
| 1, 2, 3 or **1× 2× 4×** | Game speed (1× = one game day every 10 seconds) |
| F11 | Fullscreen on/off |
| Esc | Pause (the settings menu comes later) |
| **Game ▾** | New world (seed + city count), Save, Load |

The game is laid out for 1920×1080 and scales to your window.

## Tests

The rules engine has automated tests. From this folder:

```
godot --headless --path . -s tests/run_tests.gd
```
