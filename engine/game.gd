## One running game: the state plus the RNG that drives it.
## The UI talks to this object; it never changes the state directly.
extends RefCounted

const Data := preload("res://engine/data.gd")
const WorldGen := preload("res://engine/world_gen.gd")
const Simulation := preload("res://engine/simulation.gd")
const SaveLoad := preload("res://engine/save_load.gd")

var state: Dictionary = {}
var rng := RandomNumberGenerator.new()


## Starts a new world. The same seed text and city count always give the same world.
func new_game(seed_text: String, npc_count: int) -> void:
	rng.seed = seed_text.hash()
	state = WorldGen.generate(rng, npc_count)
	state["seed_text"] = seed_text
	var home: Dictionary = state["cities"][state["home_id"]]
	var site := "a fjord" if home["site"] == "fjord" else "the open coast"
	Simulation.add_news(state, "A new world of %d cities. Your settlement, %s, lies on %s." % [
		int(state["npc_count"]) + 1, home["name"], site])


func advance_hours(hours: int) -> void:
	Simulation.advance(state, rng, hours)


func save_to(path: String) -> Error:
	return SaveLoad.save_file(path, state, rng)


func load_from(path: String) -> bool:
	var loaded := SaveLoad.load_file(path, rng)
	if loaded.is_empty():
		return false
	state = loaded
	return true


func date_string() -> String:
	return Simulation.date_string(state)
