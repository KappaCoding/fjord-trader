## Procedural world generation from a seeded RNG. See DESIGN.md 2b-E.
##
## The map is an abstract plane: y runs north (0) to south (~1100). The mainland lies
## east of a wavy coastline (Geo.coast_x); overseas lands lie far to the west across open sea.
## Home is always on the northern mainland coast, on a fjord or the open coast.
extends RefCounted

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")

const MAX_ATTEMPTS := 60
const HOME_ID := "c0"


static func generate(rng: RandomNumberGenerator, npc_count: int) -> Dictionary:
	var w: Dictionary = Data.balance()["world"]
	npc_count = clampi(npc_count, int(w["npc_cities_min"]), int(w["npc_cities_max"]))
	var state := {}
	for attempt in MAX_ATTEMPTS:
		state = _try_generate(rng, npc_count)
		if validate(state).is_empty():
			return state
	push_error("World generation could not satisfy its rules: %s" % str(validate(state)))
	return state


# ---------------------------------------------------------------- generation

static func _try_generate(rng: RandomNumberGenerator, npc_count: int) -> Dictionary:
	var w: Dictionary = Data.balance()["world"]
	var cities := {}
	var order: Array = []
	var used_names := {}
	var placed: Array = []  # [Vector2, region]

	# Home
	var home := _make_home(rng)
	home["name"] = _unique_name(rng, "northern", home["site"], used_names)
	cities[HOME_ID] = home
	order.append(HOME_ID)
	placed.append([Vector2(home["x"], home["y"]), home["region"]])

	# Slots for NPC cities
	var n_over := maxi(2, int(round(npc_count * float(w["overseas_share"]))))
	var n_main := npc_count - n_over
	var n_fjord := int(round(n_main * float(w["fjord_share_of_mainland"])))
	var n_coast := int(round(n_main * float(w["coast_share_of_mainland"])))
	var n_inland := n_main - n_fjord - n_coast
	var slots: Array = []
	var counts := {"inland": n_inland, "fjord": n_fjord, "coast": n_coast, "overseas": n_over}
	for kind in ["inland", "fjord", "coast", "overseas"]:
		for i in int(counts[kind]):
			slots.append(kind)

	var idx := 1
	for kind in slots:
		var city := _make_npc(rng, kind, placed)
		city["id"] = "c%d" % idx
		city["name"] = _unique_name(rng, _culture_for(rng, city), city["site"], used_names)
		cities[city["id"]] = city
		order.append(city["id"])
		placed.append([Vector2(city["x"], city["y"]), city["region"]])
		idx += 1

	# What everyone produces
	for id in order:
		var c: Dictionary = cities[id]
		if c["is_home"]:
			c["produces"] = []
			c["production_options"] = _home_options(rng, c)
		else:
			c["production_options"] = []
			c["produces"] = _pick_production(rng, c)
	_ensure_import_goods(rng, cities, order)

	# Wants and markets
	for id in order:
		var c: Dictionary = cities[id]
		c["wants"] = Geo.weighted_pick(rng, Geo.want_weights(c), int(Data.balance()["market"]["wants_per_city"]))
		c["want_timer_hours"] = Market.roll_want_timer(rng)
		Market.init_market(c, rng)

	var state := {
		"version": 1,
		"time_hours": 0,
		"start_month": int(Data.balance()["clock"]["start_month"]),
		"npc_count": npc_count,
		"home_id": HOME_ID,
		"cities": cities,
		"city_order": order,
		"routes": _compute_routes(cities, order),
		"news": [],
	}
	return state


static func _make_home(rng: RandomNumberGenerator) -> Dictionary:
	var w: Dictionary = Data.balance()["world"]
	var y := rng.randf_range(80.0, 220.0)
	var site := Geo.SITE_FJORD if rng.randf() < 0.5 else Geo.SITE_COAST
	var x := Geo.coast_x(y) + (rng.randf_range(50.0, 90.0) if site == Geo.SITE_FJORD else rng.randf_range(0.0, 15.0))
	var climate := Geo.climate_for_y(y)
	var home := {
		"id": HOME_ID,
		"is_home": true,
		"region": Geo.REGION_MAINLAND,
		"site": site,
		"climate": climate,
		"culture": "northern",
		"x": x,
		"y": y,
		"pop": int(w["home_population"]),
		"fjord_exit_days": _fjord_exit(rng, site),
	}
	home["features"] = Geo.roll_features(rng, site, climate, Geo.REGION_MAINLAND)
	return home


static func _make_npc(rng: RandomNumberGenerator, kind: String, placed: Array) -> Dictionary:
	var w: Dictionary = Data.balance()["world"]
	var region := Geo.REGION_OVERSEAS if kind == "overseas" else Geo.REGION_MAINLAND
	var site: String = Geo.SITE_COAST if kind == "overseas" else kind
	var spacing := float(w["min_spacing_overseas"] if region == Geo.REGION_OVERSEAS else w["min_spacing_mainland"])
	var pos := Vector2.ZERO
	for attempt in 200:
		pos = _sample_position(rng, kind)
		if _far_enough(pos, region, placed, spacing):
			break
	var climate := Geo.climate_for_y(pos.y)
	var city := {
		"is_home": false,
		"region": region,
		"site": site,
		"climate": climate,
		"x": pos.x,
		"y": pos.y,
		"pop": _roll_pop(rng, region),
		"fjord_exit_days": _fjord_exit(rng, site),
	}
	city["features"] = Geo.roll_features(rng, site, climate, region)
	return city


static func _sample_position(rng: RandomNumberGenerator, kind: String) -> Vector2:
	match kind:
		"coast":
			var y := rng.randf_range(0.0, 1000.0)
			return Vector2(Geo.coast_x(y) + rng.randf_range(0.0, 25.0), y)
		"fjord":
			var y := rng.randf_range(0.0, 420.0)
			return Vector2(Geo.coast_x(y) + rng.randf_range(50.0, 120.0), y)
		"inland":
			var y := rng.randf_range(0.0, 1000.0)
			return Vector2(rng.randf_range(Geo.coast_x(y) + 110.0, 1000.0), y)
		_:  # overseas
			return Vector2(rng.randf_range(-1400.0, -950.0), rng.randf_range(350.0, 1100.0))


static func _far_enough(pos: Vector2, region: String, placed: Array, spacing: float) -> bool:
	for p in placed:
		if p[1] == region and pos.distance_to(p[0]) < spacing:
			return false
	return true


static func _roll_pop(rng: RandomNumberGenerator, region: String) -> int:
	var r := rng.randf()
	var small := 0.15 if region == Geo.REGION_OVERSEAS else 0.30
	var town := 0.60 if region == Geo.REGION_OVERSEAS else 0.75
	var p := 0.0
	if r < small:
		p = rng.randf_range(3000.0, 10000.0)
	elif r < town:
		p = rng.randf_range(10000.0, 50000.0)
	else:
		p = rng.randf_range(50000.0, 200000.0)
	return int(round(p / 100.0)) * 100


static func _fjord_exit(rng: RandomNumberGenerator, site: String) -> int:
	if site != Geo.SITE_FJORD:
		return 0
	var r: Array = Data.balance()["world"]["fjord_exit_days"]
	return rng.randi_range(int(r[0]), int(r[1]))


static func _culture_for(rng: RandomNumberGenerator, city: Dictionary) -> String:
	if city["region"] == Geo.REGION_OVERSEAS:
		var c := "eastern" if rng.randf() < 0.5 else "southern"
		city["culture"] = c
		return c
	var culture := "southern" if city["climate"] == "south" else "northern"
	city["culture"] = culture
	return culture


static func _unique_name(rng: RandomNumberGenerator, culture: String, site: String, used: Dictionary) -> String:
	var n: Dictionary = Data.names()
	var city_name := ""
	for attempt in 100:
		match culture:
			"northern":
				var suffixes: Array = n["northern"]["water_suffix"] if Geo.is_water_site(site) else n["northern"]["land_suffix"]
				city_name = _pick(rng, n["northern"]["prefix"]) + _pick(rng, suffixes)
			"southern":
				city_name = _pick(rng, n["southern"]["start"]) + _pick(rng, n["southern"]["end"])
			_:
				city_name = _pick(rng, n["eastern"]["start"]) + _pick(rng, n["eastern"]["middle"]) + _pick(rng, n["eastern"]["end"])
		if not used.has(city_name):
			break
	used[city_name] = true
	return city_name


static func _pick(rng: RandomNumberGenerator, arr: Array) -> String:
	return str(arr[rng.randi_range(0, arr.size() - 1)])


## Home can produce whatever Tier 1 raw goods its site allows (DESIGN 3H). Guarantee (DESIGN 2b-E):
## at least one food good and one other resource.
static func _home_options(_rng: RandomNumberGenerator, home: Dictionary) -> Array:
	var has_other := false
	for id in ["Timber", "Wool", "Stone", "Salt"]:
		if Geo.site_allows(home, id):
			has_other = true
	if not has_other:
		# Give the site some hills so it has a non-food resource (Wool or Stone).
		home["features"].append("hills")
	var options: Array = []
	for id in Data.good_ids():
		if Data.tier(id) == 1 and Geo.site_allows(home, id):
			options.append(id)
	return options


static func _pick_production(rng: RandomNumberGenerator, city: Dictionary) -> Array:
	var weights := Geo.production_weights(city)
	var pop := int(city["pop"])
	var four_chance := 0.6 if pop >= 50000 else 0.25
	var k := 4 if rng.randf() < four_chance else 3
	var picks := Geo.weighted_pick(rng, weights, k)
	if picks.size() < 3:
		var fallback := {"Grain": 1.0, "Stone": 1.0, "Wool": 1.0, "Timber": 1.0}
		for id in picks:
			fallback.erase(id)
		picks.append_array(Geo.weighted_pick(rng, fallback, 3 - picks.size()))
	return _in_catalogue_order(picks)


## Every world must contain a source of Spices and of Gold, both overseas (DESIGN 2b-E).
static func _ensure_import_goods(rng: RandomNumberGenerator, cities: Dictionary, order: Array) -> void:
	var overseas: Array = []
	for id in order:
		if cities[id]["region"] == Geo.REGION_OVERSEAS:
			overseas.append(id)
	if overseas.is_empty():
		return
	# Southernmost first for Spices; mountainous first for Gold.
	overseas.sort_custom(func(a, b): return float(cities[a]["y"]) > float(cities[b]["y"]))
	var spice_city := _ensure_good(cities, overseas, "Spices", "")
	var gold_order := overseas.duplicate()
	gold_order.sort_custom(func(a, b): return int(cities[a]["features"].has("mountains")) > int(cities[b]["features"].has("mountains")))
	_ensure_good(cities, gold_order, "Gold", spice_city)


static func _ensure_good(cities: Dictionary, candidates: Array, good: String, avoid: String) -> String:
	for id in candidates:
		if cities[id]["produces"].has(good):
			return id
	var target: String = candidates[0]
	for id in candidates:
		if id != avoid:
			target = id
			break
	var produces: Array = cities[target]["produces"]
	if produces.size() >= 4:
		# Replace the last non-import good.
		for i in range(produces.size() - 1, -1, -1):
			if not Data.is_import_only(produces[i]):
				produces.remove_at(i)
				break
	produces.append(good)
	cities[target]["produces"] = _in_catalogue_order(produces)
	return target


static func _in_catalogue_order(ids: Array) -> Array:
	var out: Array = []
	for id in Data.good_ids():
		if ids.has(id):
			out.append(id)
	return out


## Road links that keep the whole mainland connected: a minimum spanning tree over
## mainland cities, so even a remote inland town has a road to its nearest neighbour.
static func _mainland_road_tree(cities: Dictionary, order: Array) -> Dictionary:
	var mainland: Array = []
	for id in order:
		if cities[id]["region"] == Geo.REGION_MAINLAND:
			mainland.append(id)
	var linked := {}
	if mainland.size() < 2:
		return linked
	var in_tree := {mainland[0]: true}
	while in_tree.size() < mainland.size():
		var best := INF
		var edge := []
		for a in in_tree:
			for b in mainland:
				if in_tree.has(b):
					continue
				var d := Vector2(cities[a]["x"], cities[a]["y"]).distance_to(Vector2(cities[b]["x"], cities[b]["y"]))
				if d < best:
					best = d
					edge = [a, b]
		in_tree[edge[1]] = true
		linked[Geo.route_key(edge[0], edge[1])] = true
	return linked


static func _compute_routes(cities: Dictionary, order: Array) -> Dictionary:
	var w: Dictionary = Data.balance()["world"]
	var f: Dictionary = w["route_factor"]
	var road_tree := _mainland_road_tree(cities, order)
	var routes := {}
	for i in order.size():
		for j in range(i + 1, order.size()):
			var a: Dictionary = cities[order[i]]
			var b: Dictionary = cities[order[j]]
			var d := Vector2(a["x"], a["y"]).distance_to(Vector2(b["x"], b["y"]))
			var r := {"land": -1.0, "sheltered": -1.0, "ocean": -1.0, "ocean_exit_days": 0}
			var both_mainland: bool = a["region"] == Geo.REGION_MAINLAND and b["region"] == Geo.REGION_MAINLAND
			var both_water: bool = Geo.is_water_site(a["site"]) and Geo.is_water_site(b["site"])
			var key := Geo.route_key(order[i], order[j])
			if both_mainland and (d <= float(w["land_max_distance"]) or road_tree.has(key)):
				r["land"] = d * float(f["land"])
			if both_water and a["region"] == b["region"] and d <= float(w["sheltered_max_distance"]):
				r["sheltered"] = d * float(f["sheltered"])
			if both_water:
				r["ocean"] = d * float(f["ocean"])
				r["ocean_exit_days"] = int(a["fjord_exit_days"]) + int(b["fjord_exit_days"])
			routes[key] = r
	return routes


# ---------------------------------------------------------------- validation

## Returns a list of broken rules; empty means the world is valid.
static func validate(state: Dictionary) -> Array:
	var problems: Array = []
	var cities: Dictionary = state["cities"]
	var order: Array = state["city_order"]
	var home: Dictionary = cities[HOME_ID]

	if order.size() != int(state["npc_count"]) + 1:
		problems.append("wrong city count")

	# Home can produce one food good and one other resource.
	var has_food := false
	var has_other := false
	for id in home["production_options"]:
		if Data.is_food(id):
			has_food = true
		else:
			has_other = true
	if not (has_food and has_other):
		problems.append("home lacks food or another resource")

	# Spices and Gold exist somewhere.
	for good in ["Spices", "Gold"]:
		var found := false
		for id in order:
			if cities[id]["produces"].has(good):
				found = true
		if not found:
			problems.append("no source of %s" % good)

	# The starting wagon and barge each have somewhere to go (playability).
	var land_ok := false
	var sheltered_ok := false
	for id in order:
		if id == HOME_ID:
			continue
		if Geo.travel_days(state, HOME_ID, id, "land") > 0:
			land_ok = true
		if Geo.travel_days(state, HOME_ID, id, "sheltered") > 0:
			sheltered_ok = true
	if not land_ok:
		problems.append("home has no land neighbour")
	if not sheltered_ok:
		problems.append("home has no sheltered-water neighbour")

	# Every city can be reached from home somehow.
	for id in order:
		if id == HOME_ID:
			continue
		var reachable := false
		for rt in Geo.ROUTE_TYPES:
			if int(Geo.best_path(state, HOME_ID, id, rt)["days"]) > 0:
				reachable = true
				break
		if not reachable:
			problems.append("%s is unreachable from home" % cities[id]["name"])

	# Names unique; production and wants well-formed.
	var names := {}
	for id in order:
		var c: Dictionary = cities[id]
		if names.has(c["name"]):
			problems.append("duplicate name %s" % c["name"])
		names[c["name"]] = true
		if c["wants"].size() != int(Data.balance()["market"]["wants_per_city"]):
			problems.append("%s has wrong number of wants" % c["name"])
		for g in c["wants"]:
			if c["produces"].has(g):
				problems.append("%s wants what it produces" % c["name"])
		if not c["is_home"]:
			var n: int = c["produces"].size()
			if n < 3 or n > 4:
				problems.append("%s produces %d goods" % [c["name"], n])
			for g in c["produces"]:
				if Data.is_import_only(g) and c["region"] != Geo.REGION_OVERSEAS:
					problems.append("%s on the mainland produces %s" % [c["name"], g])
	return problems
