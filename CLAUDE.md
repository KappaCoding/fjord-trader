# Working on Fjord Trader

Ludvig and Claude build this game together over many sessions. Each session starts cold, so:

1. Read `DESIGN.md` (the rules) and `ROADMAP.md` (where we are) before changing anything.
2. If a rule isn't written in `DESIGN.md`, it isn't decided — ask Ludvig, don't improvise.
   When a decision is made, record it in `DESIGN.md` in the same session.
3. Be a critical sparring partner: flag balance problems, exploits and scope risks, then let Ludvig decide.

## Architecture rules

- `engine/` is pure rules logic with no UI. `ui/` only reads state and calls `engine/game.gd`.
- Balance numbers live in `data/*.json`, never hard-coded in scripts.
- All randomness goes through the game's seeded `RandomNumberGenerator`, in a fixed order, so a seed or a save
  always reproduces the same game. Never use `randi()`/`randf()` globals in `engine/`.
- Time advances in 1-game-hour steps; monthly rates are pro-rated per step.
- Money is whole coins (`int`). Saves use Godot's binary Variant format (`store_var`) for exactness.
- Scripts reference each other with `preload` constants, not `class_name`.

## Testing

Run the engine tests headless; add tests for every new rule:

```
godot --headless --path . -s tests/run_tests.gd
```

The UI can be screenshotted on a virtual display (`xvfb-run ... --rendering-driver opengl3`) to check layout.

## Godot

Godot 4.7.2 Standard, GDScript.
