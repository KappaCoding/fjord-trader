## Loads the JSON data files in res://data and gives typed access to them.
## Data is read once and cached. Nothing in here changes during a game.
extends RefCounted

const GOODS_PATH := "res://data/goods.json"
const BALANCE_PATH := "res://data/balance.json"
const NAMES_PATH := "res://data/names.json"

static var _cache := {}
static var _goods_by_id := {}
static var _good_ids: Array = []


static func load_json(path: String) -> Variant:
	if _cache.has(path):
		return _cache[path]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Missing data file: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null:
		push_error("Invalid JSON in data file: %s" % path)
		return {}
	_cache[path] = parsed
	return parsed


static func balance() -> Dictionary:
	return load_json(BALANCE_PATH)


static func names() -> Dictionary:
	return load_json(NAMES_PATH)


static func goods() -> Array:
	return load_json(GOODS_PATH)["goods"]


static func _index_goods() -> void:
	if not _good_ids.is_empty():
		return
	for g in goods():
		_goods_by_id[g["id"]] = g
		_good_ids.append(g["id"])


## Good ids in catalogue order (Grain … Gold).
static func good_ids() -> Array:
	_index_goods()
	return _good_ids


static func good(id: String) -> Dictionary:
	_index_goods()
	return _goods_by_id[id]


static func base_price(id: String) -> int:
	return int(good(id)["base"])


static func tier(id: String) -> int:
	return int(good(id)["tier"])


static func is_food(id: String) -> bool:
	return bool(good(id)["food"])


static func is_import_only(id: String) -> bool:
	return tier(id) == 0


static func hours_per_day() -> int:
	return 24


static func hours_per_month() -> int:
	return int(balance()["clock"]["days_per_month"]) * hours_per_day()
