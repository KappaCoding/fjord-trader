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

## Controls (Milestone 1)

| Key / button | Does |
|---|---|
| Space or **Pause** | Pause / resume |
| 1, 2, 3 or **1× 2× 4×** | Game speed (1× = one game day every 10 seconds) |
| Esc | Pause (the settings menu comes later) |
| **Seed** + **New world** | Generate a world. The same seed and city count always give the same world |
| **Save** / **Load** | Quick save slot |

Click a city on the left to see its prices. Green = the city wants it (pays a premium), orange = the city produces it
(cheap, and it sells it to you). Travel days are from your home; ↪ means the trip passes through other cities
(hover for the route).

## Tests

The rules engine has automated tests. From this folder:

```
godot --headless --path . -s tests/run_tests.gd
```
