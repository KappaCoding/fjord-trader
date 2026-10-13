## Procedural world generation from a seeded RNG. See DESIGN.md 2b-E and 2d.
##
## The map is an abstract plane: y runs north (0) to south (~1300). The mainland lies east of an irregular
## coastline (Geo.coast_x), with a mountain belt (highlands) inland and rivers running from the mountains to the
## coast. Climate zones (Geo.zone_at) decide what towns produce. Overseas islands lie far to the west.
## Home is always on the northern coast, on a fjord or the open coast.
extends RefCounted

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")

const MAX_ATTEMPTS := 60
const HOME_ID := "c0"


static func generate(rng: RandomNumberGenerator, npc_count: int) -> Dictionary:
	var w := Geo.world_cfg()
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
	var w := Geo.world_cfg()
	var state := {
		"version": 1,
		"time_hours": 0,
		"start_month": int(Data.balance()["clock"]["start_month"]),
		"npc_count": npc_count,
		"home_id": HOME_ID,
		"cities": {},
		"city_order": [],
		"routes": {},
		"news": [],
	}
	state["geo"] = Geo.make_shape(rng)
	_make_rivers(rng, state, npc_count)

	var cities: Dictionary = state["cities"]
	var order: Array = state["city_order"]
	var used_names := {}
	var placed: Array = []  # [Vector2, region]

	var home := _make_home(rng, state)
	home["name"] = _unique_name(rng, "northern", home["site"], used_names)
	cities[HOME_ID] = home
	order.append(HOME_ID)
	placed.append([Geo.city_pos(home), home["region"]])

	var n_over := maxi(2, int(round(npc_count * float(w["overseas_share"]))))
	var n_main := npc_count - n_over
	var shares: Dictionary = w["site_shares"]
	var counts := {
		"fjord": int(round(n_main * float(shares["fjord"]))),
		"coast": int(round(n_main * float(shares["coast"]))),
		"river": int(round(n_main * float(shares["river"]))) if not state["geo"]["rivers"].is_empty() else 0,
	}
	counts["inland"] = n_main - int(counts["fjord"]) - int(counts["coast"]) - int(counts["river"])
	counts["overseas"] = n_over
	var idx := 1
	for kind in ["river", "fjord", "coast", "inland", "overseas"]:
		for i in int(counts[kind]):
			var city := _make_npc(rng, state, kind, placed)
			city["id"] = "c%d" % idx
			city["name"] = _unique_name(rng, _culture_for(rng, city), city["site"], used_names)
			cities[city["id"]] = city
			order.append(city["id"])
			placed.append([Geo.city_pos(city), city["region"]])
			idx += 1

	for id in order:
		var c: Dictionary = cities[id]
		if c["is_home"]:
			c["produces"] = []
			c["production_options"] = _home_options(c)
		else:
			c["production_options"] = []
			c["produces"] = _pick_production(rng, c)
	_ensure_import_goods(cities, order)

	for id in order:
		var c: Dictionary = cities[id]
		c["wants"] = Geo.weighted_pick(rng, Geo.want_weights(c), int(Data.balance()["market"]["wants_per_city"]))
		c["want_timer_hours"] = Market.roll_want_timer(rng)
		Market.init_market(c, rng)

	state["routes"] = _compute_routes(state)
	return state


## Rivers start on the west flank of the mountains and meander west to the coast (DESIGN 2d-B).
static func _make_rivers(rng: RandomNumberGenerator, state: Dictionary, npc_count: int) -> void:
	var w := Geo.world_cfg()
	@warning_ignore("integer_division")
	var count := int(w["rivers_base"]) + (npc_count / 10) * int(w["rivers_per_10_cities"])
	var my: Array = w["mainland_y"]
	var ys: Array = []
	for attempt in 300:
		if ys.size() >= count:
			break
		var y := rng.randf_range(float(my[0]) + 60.0, float(my[1]) - 40.0)
		var ok := true
		for other in ys:
			if absf(y - float(other)) < 230.0:
				ok = false
		if ok:
			ys.append(y)
	ys.sort()
	var rivers: Array = []
	for y0 in ys:
		var y := float(y0)
		var x := Geo.ridge_x(state, y) - Geo.ridge_half_width(state, y) * 0.6
		var phase := rng.randf_range(0.0, TAU)
		var pts: Array = [[x, y]]
		var step := 0
		while x > Geo.coast_x(state, y) + 4.0 and step < 200:
			x -= 18.0
			y = clampf(y + 9.0 * sin(float(step) * 0.45 + phase) + rng.randf_range(-3.0, 3.0), float(y0) - 70.0, float(y0) + 70.0)
			pts.append([x, y])
			step += 1
		var last: Array = pts[pts.size() - 1]
		pts[pts.size() - 1] = [Geo.coast_x(state, float(last[1])), float(last[1])]
		rivers.append({"points": pts, "cum": Geo.cumulative(pts)})
	state["geo"]["rivers"] = rivers


static func _base_city(state: Dictionary, region: String, site: String, pos: Vector2) -> Dictionary:
	var zone := "tropics" if region == Geo.REGION_OVERSEAS else Geo.zone_at(state, pos.x, pos.y)
	return {
		"is_home": false,
		"region": region,
		"site": site,
		"zone": zone,
		"x": pos.x,
		"y": pos.y,
		"port": [pos.x, pos.y],
		"access": 0.0,
		"river": -1,
		"river_pos": 0.0,
		"fjord_exit_days": 0,
	}


## A fjord town sits at the head of an inlet; its port is where the inlet meets the coast.
static func _fjord_port(rng: RandomNumberGenerator, state: Dictionary, c: Dictionary) -> void:
	var py := float(c["y"]) + rng.randf_range(-15.0, 15.0)
	var port := Vector2(Geo.coast_x(state, py), py)
	c["port"] = [port.x, port.y]
	c["access"] = Geo.city_pos(c).distance_to(port)
	var r: Array = Geo.world_cfg()["fjord_exit_days"]
	c["fjord_exit_days"] = rng.randi_range(int(r[0]), int(r[1]))


static func _make_home(rng: RandomNumberGenerator, state: Dictionary) -> Dictionary:
	var w := Geo.world_cfg()
	var hy: Array = w["home_y"]
	var y := rng.randf_range(float(hy[0]), float(hy[1]))
	var site := Geo.SITE_FJORD if rng.randf() < 0.5 else Geo.SITE_COAST
	var x := Geo.coast_x(state, y) + (rng.randf_range(55.0, 100.0) if site == Geo.SITE_FJORD else rng.randf_range(0.0, 10.0))
	var home := _base_city(state, Geo.REGION_MAINLAND, site, Vector2(x, y))
	home["id"] = HOME_ID
	home["is_home"] = true
	home["culture"] = "northern"
	home["pop"] = int(w["home_population"])
	if site == Geo.SITE_FJORD:
		_fjord_port(rng, state, home)
	return home


static func _make_npc(rng: RandomNumberGenerator, state: Dictionary, kind: String, placed: Array) -> Dictionary:
	var w := Geo.world_cfg()
	var region := Geo.REGION_OVERSEAS if kind == "overseas" else Geo.REGION_MAINLAND
	var site: String = Geo.SITE_COAST if kind == "overseas" else kind
	var spacing := float(w["min_spacing_overseas"] if region == Geo.REGION_OVERSEAS else w["min_spacing_mainland"])
	var pos := Vector2.ZERO
	var river_idx := -1
	var river_pos := 0.0
	for attempt in 300:
		if kind == "river":
			river_idx = rng.randi_range(0, state["geo"]["rivers"].size() - 1)
			river_pos = Geo.river_length(state, river_idx) * rng.randf_range(0.12, 0.8)
			pos = Geo.river_point_at(state, river_idx, river_pos)
		else:
			pos = _sample_position(rng, state, kind)
			if kind == "inland" and _near_river(state, pos, 40.0):
				continue
		if _far_enough(pos, region, placed, spacing):
			break
	var city := _base_city(state, region, site, pos)
	city["pop"] = _roll_pop(rng, region)
	match kind:
		"river":
			city["river"] = river_idx
			city["river_pos"] = river_pos
			var mouth := Geo.river_point_at(state, river_idx, Geo.river_length(state, river_idx))
			city["port"] = [mouth.x, mouth.y]
			city["access"] = Geo.river_length(state, river_idx) - river_pos
		"fjord":
			_fjord_port(rng, state, city)
	return city


static func _sample_position(rng: RandomNumberGenerator, state: Dictionary, kind: String) -> Vector2:
	var w := Geo.world_cfg()
	var my: Array = w["mainland_y"]
	match kind:
		"coast":
			var y := rng.randf_range(float(my[0]) + 20.0, float(my[1]))
			return Vector2(Geo.coast_x(state, y) + rng.randf_range(0.0, 12.0), y)
		"fjord":
			var y := rng.randf_range(float(my[0]) + 20.0, 480.0)
			return Vector2(Geo.coast_x(state, y) + rng.randf_range(55.0, 120.0), y)
		"inland":
			var y := rng.randf_range(float(my[0]) + 20.0, float(my[1]))
			if rng.randf() < float(w["inland_highland_share"]):
				# Mountain towns: the only source of Iron Ore and Coal, so make sure there are some.
				var hw := Geo.ridge_half_width(state, y) * 0.85
				return Vector2(Geo.ridge_x(state, y) + rng.randf_range(-hw, hw), y)
			return Vector2(rng.randf_range(Geo.coast_x(state, y) + 120.0, float(w["mainland_x_max"])), y)
		_:
			var ox: Array = w["overseas_x"]
			var oy: Array = w["overseas_y"]
			return Vector2(rng.randf_range(float(ox[0]), float(ox[1])), rng.randf_range(float(oy[0]), float(oy[1])))


static func _near_river(state: Dictionary, pos: Vector2, dist: float) -> bool:
	for i in state["geo"]["rivers"].size():
		for p in Geo.river_points(state, i):
			if p.distance_to(pos) < dist:
				return true
	return false


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


static func _culture_for(rng: RandomNumberGenerator, city: Dictionary) -> String:
	var culture: String = Geo.zone_info(city["zone"])["culture"]
	if city["region"] == Geo.REGION_OVERSEAS:
		culture = "eastern" if rng.randf() < 0.6 else "southern"
	city["culture"] = culture
	return culture


static func _unique_name(rng: RandomNumberGenerator, culture: String, site: String, used: Dictionary) -> String:
	var n: Dictionary = Data.names()
	var city_name := ""
	for attempt in 100:
		match culture:
			"northern":
				var suffixes: Array = n["northern"]["water_suffix"] if Geo.is_water_site(site) and site != Geo.SITE_RIVER else n["northern"]["land_suffix"]
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


## Home can produce whatever Tier 1 raw goods its zone and coast allow (DESIGN 2d-A). Being on the coast it
## can always fish, and every northern zone has another raw good, so the 2b-E guarantee holds.
static func _home_options(home: Dictionary) -> Array:
	var allowed := Geo.raw_goods_for(home)
	var options: Array = []
	for id in Data.good_ids():
		if Data.tier(id) == 1 and allowed.has(id):
			options.append(id)
	return options


static func _pick_production(rng: RandomNumberGenerator, city: Dictionary) -> Array:
	var weights := Geo.production_weights(city)
	var pop := int(city["pop"])
	var four_chance := 0.6 if pop >= 50000 else 0.25
	var k := 4 if rng.randf() < four_chance else 3
	return _in_catalogue_order(Geo.weighted_pick(rng, weights, k))


## Every world must contain a source of Spices and of Gold, both overseas (DESIGN 2b-E).
static func _ensure_import_goods(cities: Dictionary, order: Array) -> void:
	var overseas: Array = []
	for id in order:
		if cities[id]["region"] == Geo.REGION_OVERSEAS:
			overseas.append(id)
	if overseas.is_empty():
		return
	var spice_city := _ensure_good(cities, overseas, "Spices", "")
	_ensure_good(cities, overseas, "Gold", spice_city)


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


## Road links that keep the whole mainland connected: a minimum spanning tree over mainland cities.
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
				var d := Geo.city_pos(cities[a]).distance_to(Geo.city_pos(cities[b]))
				if d < best:
					best = d
					edge = [a, b]
		in_tree[edge[1]] = true
		linked[Geo.route_key(edge[0], edge[1])] = true
	return linked


## Route lengths between every pair of cities, per route type (-1 = no direct route).
## Sheltered water runs along rivers, fjords and the coast (DESIGN 2d-B), between any two mainland water towns
## however far apart; it never crosses the open sea to the islands. Ocean ships use the open sea and can't
## enter rivers.
static func _compute_routes(state: Dictionary) -> Dictionary:
	var cities: Dictionary = state["cities"]
	var order: Array = state["city_order"]
	var w := Geo.world_cfg()
	var f: Dictionary = w["route_factor"]
	var road_tree := _mainland_road_tree(cities, order)
	var routes := {}
	for i in order.size():
		for j in range(i + 1, order.size()):
			var a: Dictionary = cities[order[i]]
			var b: Dictionary = cities[order[j]]
			var d := Geo.city_pos(a).distance_to(Geo.city_pos(b))
			var r := {"land": -1.0, "sheltered": -1.0, "ocean": -1.0, "ocean_exit_days": 0}
			var key := Geo.route_key(order[i], order[j])
			var both_mainland: bool = a["region"] == Geo.REGION_MAINLAND and b["region"] == Geo.REGION_MAINLAND
			var both_overseas: bool = a["region"] == Geo.REGION_OVERSEAS and b["region"] == Geo.REGION_OVERSEAS
			if both_mainland and (d <= float(w["land_max_distance"]) or road_tree.has(key)):
				r["land"] = d * float(f["land"])
			if Geo.is_water_site(a["site"]) and Geo.is_water_site(b["site"]):
				if a["site"] == Geo.SITE_RIVER and b["site"] == Geo.SITE_RIVER and int(a["river"]) == int(b["river"]):
					r["sheltered"] = absf(float(a["river_pos"]) - float(b["river_pos"]))
				elif both_mainland:
					var coastal := Geo.city_port(a).distance_to(Geo.city_port(b))
					r["sheltered"] = float(a["access"]) + coastal * float(f["sheltered"]) + float(b["access"])
				elif both_overseas and d <= float(w["island_hop_max_distance"]):
					r["sheltered"] = d * float(f["sheltered"])
			if Geo.is_sea_site(a["site"]) and Geo.is_sea_site(b["site"]):
				r["ocean"] = Geo.city_port(a).distance_to(Geo.city_port(b)) * float(f["ocean"])
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

	# The starting wagon and barge each have somewhere to go.
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

	# Names unique; production follows the zones; wants well-formed.
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
		if c["is_home"]:
			continue
		var n: int = c["produces"].size()
		if n < 2 or n > 4:
			problems.append("%s produces %d goods" % [c["name"], n])
		for g in c["produces"]:
			if Data.is_import_only(g) and c["region"] != Geo.REGION_OVERSEAS:
				problems.append("%s on the mainland produces %s" % [c["name"], g])
			if not Geo.site_allows(c, g):
				problems.append("%s produces %s outside its zone" % [c["name"], g])
	return problems
