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

## How to play (Milestone 2)

1. **Choose production.** A new world starts paused and asks what your two lines should make. Each line makes
   10 lots a month (one every 3 days). The dialog shows what each good fetches at home and where it sells best.
2. **Read the map.** Your home is the gold dot. Lines show the routes your vehicles use from home:
   dashed sand = road (wagons), light blue = sheltered water (barges), dotted blue = open sea (ocean ships, from
   Stage 3; tick *Open sea* to see them). Hollow cities can't be reached by any vehicle you own.
   Click a city to see its market and *Getting there*: which vehicle reaches it, how many days, and through which towns.
3. **Find a market.** Pick a good under *Prices* (or click a good's name) to colour every city by what it pays you:
   green = it wants the good and pays a premium, orange = it produces it and pays little.
4. **Trade.** Press **Sell** or **Buy** in a city's market, or **Plan trip** on a vehicle. The planner picks the
   fastest vehicle, shows the route on the map, and estimates sales, purchases and fees. The vehicle trades at the
   prices on arrival and comes home by itself. Bought goods land in your warehouse; sell them on a later trip.
5. **Watch your money.** Running costs (upkeep, tax, storage) tick continuously. The **Finances** tab shows them per
   month, how long your money lasts, and this and last month's books.

| Key / button | Does |
|---|---|
| Space or **Pause** | Pause / resume |
| 1, 2, 3 or **1× 2× 4×** | Game speed (1× = one game day every 10 seconds) |
| Esc | Pause (the settings menu comes later) |
| **Game ▾** | New world (seed + city count), Save, Load |

## Tests

The rules engine has automated tests. From this folder:

```
godot --headless --path . -s tests/run_tests.gd
```
