## Geography rules: where things are, what each place can produce and want,
## and how long it takes to travel between places. Shared by world generation
## and the running simulation.
extends RefCounted

const Data := preload("res://engine/data.gd")

const SITE_INLAND := "inland"
const SITE_FJORD := "fjord"
const SITE_COAST := "coast"

const REGION_MAINLAND := "mainland"
const REGION_OVERSEAS := "overseas"

const ROUTE_TYPES := ["land", "sheltered", "ocean"]


## x-coordinate of the mainland coastline at a given y. West of it is open sea.
static func coast_x(y: float) -> float:
	return 480.0 + 40.0 * sin(y / 150.0)


static func climate_for_y(y: float) -> String:
	var w: Dictionary = Data.balance()["world"]
	if y < float(w["climate_north_below_y"]):
		return "north"
	if y < float(w["climate_temperate_below_y"]):
		return "temperate"
	return "south"


static func is_water_site(site: String) -> bool:
	return site == SITE_FJORD or site == SITE_COAST


static func roll_features(rng: RandomNumberGenerator, site: String, climate: String, region: String) -> Array:
	var f: Array = []
	var p_mountains := 0.5 if site == SITE_INLAND else 0.25
	if region == REGION_OVERSEAS:
		p_mountains = 0.4
	if rng.randf() < p_mountains:
		f.append("mountains")
	var p_forest: float = {"north": 0.6, "temperate": 0.4, "south": 0.15}[climate]
	if rng.randf() < p_forest:
		f.append("forest")
	var p_plains := 0.55 if site == SITE_INLAND else 0.3
	if climate == "north":
		p_plains *= 0.6
	if rng.randf() < p_plains:
		f.append("plains")
	if rng.randf() < 0.35:
		f.append("hills")
	return f


## Weights for what a city could produce, given its site, climate, terrain and size.
## A weight of 0 (or a missing key) means the city can't produce that good.
static func production_weights(city: Dictionary, include_tiers_above_1 := true) -> Dictionary:
	var site: String = city["site"]
	var climate: String = city["climate"]
	var region: String = city["region"]
	var feats: Array = city["features"]
	var pop := int(city["pop"])
	var mountains := feats.has("mountains")
	var forest := feats.has("forest")
	var plains := feats.has("plains")
	var hills := feats.has("hills")
	var water := is_water_site(site)
	var w := {}

	# Tier 1 — raw goods
	if plains:
		w["Grain"] = 1.0 if climate == "north" else 3.0
	elif region == REGION_OVERSEAS and climate == "south":
		w["Grain"] = 2.0
	if water:
		w["Fish"] = 3.0
	if forest:
		w["Timber"] = 3.0
	if (hills or plains) and climate != "south":
		w["Wool"] = 2.0
	elif hills:
		w["Wool"] = 1.0
	if mountains or hills:
		w["Stone"] = 2.0
	if site == SITE_COAST:
		w["Salt"] = 1.0 if climate == "north" else 2.0
	elif mountains:
		w["Salt"] = 1.0

	if not include_tiers_above_1:
		return _strip_zero(w)

	# Tier 2 — towns of 10,000+
	if pop >= 10000:
		if mountains:
			w["Iron Ore"] = 3.0
			w["Coal"] = 2.0
		elif hills:
			w["Coal"] = 1.0
		if climate == "south":
			w["Wine"] = 3.0
		elif climate == "temperate" and hills:
			w["Wine"] = 1.0
		if w.has("Wool"):
			w["Cloth"] = 2.0

	# Tier 3 — cities of 50,000+
	if pop >= 50000:
		if mountains:
			w["Steel"] = 2.0
		if w.has("Stone") or site == SITE_COAST:
			w["Glass"] = 1.5
		if forest:
			w["Furniture"] = 2.0
		if mountains or pop >= 100000:
			w["Tools"] = 1.0

	# Import-only goods exist only overseas
	if region == REGION_OVERSEAS:
		if climate == "south":
			w["Spices"] = 3.0
		elif climate == "temperate":
			w["Spices"] = 1.0
		if mountains or hills:
			w["Gold"] = 3.0

	return _strip_zero(w)


## Weights for what a city would pay a premium for. Bigger cities want finer goods.
static func want_weights(city: Dictionary) -> Dictionary:
	var pop := int(city["pop"])
	var produces: Array = city["produces"]
	var feats: Array = city["features"]
	var w := {}
	for id in Data.good_ids():
		if produces.has(id):
			continue
		var t := Data.tier(id)
		var weight := 0.0
		match t:
			1:
				weight = 3.0
				if Data.is_food(id) and (pop >= 20000 or feats.has("mountains")):
					weight += 2.0
			2:
				weight = 2.0 if pop >= 8000 else 1.0
			3:
				weight = 2.0 if pop >= 30000 else 0.3
			4:
				weight = 1.0 if pop >= 100000 else 0.0
			0:
				weight = 1.0 if pop >= 50000 else 0.0
		if weight > 0.0:
			w[id] = weight
	return w


static func _strip_zero(w: Dictionary) -> Dictionary:
	var out := {}
	for k in w:
		if float(w[k]) > 0.0:
			out[k] = w[k]
	return out


## Weighted random pick of up to k distinct keys. Deterministic for a given RNG state.
static func weighted_pick(rng: RandomNumberGenerator, weights: Dictionary, k: int) -> Array:
	var pool := weights.duplicate()
	var out: Array = []
	while out.size() < k and not pool.is_empty():
		var keys: Array = pool.keys()
		keys.sort()
		var total := 0.0
		for key in keys:
			total += float(pool[key])
		if total <= 0.0:
			break
		var r := rng.randf() * total
		var acc := 0.0
		var chosen: Variant = keys[keys.size() - 1]
		for key in keys:
			acc += float(pool[key])
			if r < acc:
				chosen = key
				break
		out.append(chosen)
		pool.erase(chosen)
	return out


static func route_key(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a


## Route between two cities: {"land": units|-1, "sheltered": units|-1, "ocean": units|-1, "ocean_exit_days": int}
static func route(state: Dictionary, a: String, b: String) -> Dictionary:
	return state["routes"].get(route_key(a, b), {})


## Fastest way from a to b using only one route type (a wagon can't sail, a barge can't
## cross open sea), possibly through other cities. Returns {"days": int, "stops": [ids from a to b]},
## or {"days": -1, "stops": []} when b can't be reached that way.
static func best_path(state: Dictionary, a: String, b: String, route_type: String, vehicle := "", speed_mult := 1.0) -> Dictionary:
	var order: Array = state["city_order"]
	var dist := {}
	var prev := {}
	var done := {}
	for id in order:
		dist[id] = INF
	dist[a] = 0.0
	while true:
		var current := ""
		var best := INF
		for id in order:
			if not done.has(id) and float(dist[id]) < best:
				best = float(dist[id])
				current = id
		if current == "" or current == b:
			break
		done[current] = true
		for id in order:
			if done.has(id) or id == current:
				continue
			var d := travel_days(state, current, id, route_type, vehicle, speed_mult)
			if d > 0 and best + d < float(dist[id]):
				dist[id] = best + d
				prev[id] = current
	if is_inf(float(dist[b])):
		return {"days": -1, "stops": []}
	var stops: Array = [b]
	while stops[0] != a:
		stops.push_front(prev[stops[0]])
	return {"days": int(dist[b]), "stops": stops}


## Travel time in whole days for one direct leg, or -1 if there is no direct route of that type.
## `speed_mult` scales the vehicle's speed (roads make the player's wagons faster, DESIGN 3G).
static func travel_days(state: Dictionary, a: String, b: String, route_type: String, vehicle := "", speed_mult := 1.0) -> int:
	var r := route(state, a, b)
	if r.is_empty():
		return -1
	var units := float(r[route_type])
	if units < 0.0:
		return -1
	var w: Dictionary = Data.balance()["world"]
	if vehicle == "":
		vehicle = w["route_vehicle"][route_type]
	var speed := float(w["speed_units_per_day"][vehicle]) * speed_mult
	var days := int(ceil(units / speed - 1e-9))
	if route_type == "ocean":
		days += int(r["ocean_exit_days"])
	return max(days, 1)


# ------------------------------------------------------------------ what a site can produce (DESIGN 3H)

const RAW_GOODS := ["Grain", "Fish", "Timber", "Wool", "Stone", "Salt", "Iron Ore", "Coal", "Wine"]

const SITE_NEEDS := {
	"Grain": "farmland (plains)",
	"Fish": "a coast or fjord",
	"Timber": "forest",
	"Wool": "hills or plains for grazing",
	"Stone": "mountains or hills",
	"Salt": "an open coast or mountains",
	"Iron Ore": "mountains",
	"Coal": "mountains or hills",
	"Wine": "a warm climate (the south, or temperate hills)",
}


static func is_raw(good: String) -> bool:
	return RAW_GOODS.has(good)


## Whether a city's land allows a raw good. Processed and import-only goods aren't about land.
static func site_allows(city: Dictionary, good: String) -> bool:
	var feats: Array = city["features"]
	var mountains := feats.has("mountains")
	var hills := feats.has("hills")
	var plains := feats.has("plains")
	match good:
		"Grain":
			return plains or (city["region"] == REGION_OVERSEAS and city["climate"] == "south")
		"Fish":
			return is_water_site(city["site"])
		"Timber":
			return feats.has("forest")
		"Wool":
			return hills or (plains and city["climate"] != "south")
		"Stone":
			return mountains or hills
		"Salt":
			return city["site"] == SITE_COAST or mountains
		"Iron Ore":
			return mountains
		"Coal":
			return mountains or hills
		"Wine":
			return city["climate"] == "south" or (city["climate"] == "temperate" and hills)
	return true
