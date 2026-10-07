## Saves and loads games.
##
## Saves use Godot's binary Variant format, which stores every number bit-for-bit.
## (JSON was tried first: Godot's JSON parser can be off by one bit on floats, which
## made a loaded game drift away from the original. Exact saves keep bugs reproducible.)
## `to_json` remains for debugging and for comparing states in tests.
extends RefCounted

const FORMAT := "fjord-trader-save"
const FORMAT_VERSION := 1


static func save_file(path: String, state: Dictionary, rng: RandomNumberGenerator) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var({
		"format": FORMAT,
		"format_version": FORMAT_VERSION,
		"rng_seed": rng.seed,
		"rng_state": rng.state,
		"state": state,
	})
	return OK


## Returns the loaded state (and restores `rng` in place), or an empty Dictionary on failure.
static func load_file(path: String, rng: RandomNumberGenerator) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var payload: Variant = f.get_var()
	if typeof(payload) != TYPE_DICTIONARY or payload.get("format", "") != FORMAT:
		return {}
	rng.seed = int(payload["rng_seed"])
	rng.state = int(payload["rng_state"])
	return payload["state"]


## Human-readable dump of a state and its RNG position (debugging and tests only).
static func to_json(state: Dictionary, rng: RandomNumberGenerator) -> String:
	return JSON.stringify({"rng": [str(rng.seed), str(rng.state)], "state": state}, "\t", true, true)
