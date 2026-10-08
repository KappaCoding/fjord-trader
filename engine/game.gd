## One running game: the state plus the RNG that drives it.
## The UI talks to this object; it never changes the state directly.
extends RefCounted

const Data := preload("res://engine/data.gd")
const WorldGen := preload("res://engine/world_gen.gd")
const Simulation := preload("res://engine/simulation.gd")
const SaveLoad := preload("res://engine/save_load.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const News := preload("res://engine/news.gd")

## Bump when the state layout changes; older saves are refused rather than loaded wrongly.
const STATE_VERSION := 3

var state: Dictionary = {}
var rng := RandomNumberGenerator.new()
var last_load_error := ""


## Starts a new world. The same seed text and city count always give the same world.
func new_game(seed_text: String, npc_count: int) -> void:
	rng.seed = seed_text.hash()
	state = WorldGen.generate(rng, npc_count)
	state["version"] = STATE_VERSION
	state["seed_text"] = seed_text
	Economy.init_player(state)
	Transport.init_fleet(state)
	var home: Dictionary = state["cities"][state["home_id"]]
	var site := "a fjord" if home["site"] == "fjord" else "the open coast"
	News.add(state, "A new world of %d cities. Your settlement, %s, lies on %s." % [
		int(state["npc_count"]) + 1, home["name"], site], News.KIND_CITY)


func advance_hours(hours: int) -> void:
	Simulation.advance(state, rng, hours)


# ------------------------------------------------------------------ player commands
# Each returns "" (or a result with an empty "error"/"errors") on success.

func choose_line(index: int, good: String) -> String:
	return Economy.set_line(state, state["home_id"], index, good)


func add_line(good: String) -> String:
	return Economy.add_line(state, state["home_id"], good)


func upgrade_line(index: int) -> String:
	return Economy.upgrade_line(state, state["home_id"], index)


func move_line(index: int, delta: int) -> void:
	Economy.move_line(state, state["home_id"], index, delta)


func build(kind: String) -> String:
	return Economy.build(state, state["home_id"], kind)


func set_reserve(good: String, lots: int) -> void:
	Economy.set_reserve(state, state["home_id"], good, lots)


func sell_at_home(good: String, lots: int) -> Dictionary:
	return Economy.sell_at_home(state, good, lots)


func plan_route(vehicle_id: String, route: Dictionary) -> Dictionary:
	return Transport.plan_route(state, vehicle_id, route)


func send_route(vehicle_id: String, route: Dictionary) -> Dictionary:
	return Transport.send_route(state, vehicle_id, route)


func stop_route(vehicle_id: String, on := true) -> void:
	Transport.set_stop_requested(state, vehicle_id, on)


func buy_vehicle(vtype: String) -> String:
	return Transport.buy_vehicle(state, vtype)


# ------------------------------------------------------------------ queries

func home() -> Dictionary:
	return Economy.home(state)


func needs_line_choice() -> bool:
	for line in home()["lines"]:
		if String(line["good"]) == "" and String(line["retool_to"]) == "":
			return true
	return false


func net_worth() -> int:
	return Economy.net_worth(state)


func forecast() -> Dictionary:
	return Economy.forecast(state, Transport.committed_fees(state))


func date_string() -> String:
	return Simulation.date_string(state)


# ------------------------------------------------------------------ saving

func save_to(path: String) -> Error:
	return SaveLoad.save_file(path, state, rng)


func load_from(path: String) -> bool:
	var probe := RandomNumberGenerator.new()
	var loaded := SaveLoad.load_file(path, probe)
	if loaded.is_empty():
		last_load_error = "No save found."
		return false
	if int(loaded.get("version", 1)) != STATE_VERSION:
		last_load_error = "That save is from an older version of the game and can't be loaded."
		return false
	state = loaded
	rng = probe
	last_load_error = ""
	return true
