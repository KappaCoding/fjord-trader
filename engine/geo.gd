## Geography: the shape of the world (coast, mountains, zones, rivers), what each place can produce,
## and how long it takes to travel between places. Shared by world generation, the simulation and the map.
## See DESIGN.md 2b-E and 2d (zones, rivers, speed).
##
## The world shape is stored in state["geo"] so every function here takes the state:
##   coast  — {base, p: [phases]}       the mainland's west coast: x = coast_x(y)
##   ridge  — {base, width, p: [phases]} the mountain belt: highlands within a band around ridge_x(y)
##   zone   — {p: [phases]}              wobble of the zone borders
##   rivers — [{points: [[x, y]...], cum: [length...]}]  source (mountains) → mouth (coast)
extends RefCounted

const Data := preload("res://engine/data.gd")

const SITE_INLAND := "inland"
const SITE_FJORD := "fjord"
const SITE_COAST := "coast"
const SITE_RIVER := "river"

const REGION_MAINLAND := "mainland"
const REGION_OVERSEAS := "overseas"

const ROUTE_TYPES := ["land", "sheltered", "ocean"]

## Map x below which the open sea is drawn compressed (not to scale).
const OCEAN_SPLIT_X := 300.0

const RAW_GOODS := ["Grain", "Fish", "Timber", "Wool", "Stone", "Salt", "Iron Ore", "Coal", "Wine", "Spices", "Gold"]


static func world_cfg() -> Dictionary:
	return Data.balance()["world"]


static func zones() -> Dictionary:
	return Data.load_json("res://data/zones.json")


static func zone_info(zone: String) -> Dictionary:
	return zones()["zones"][zone]


static func zone_label(zone: String) -> String:
	return zone_info(zone)["label"]


# ------------------------------------------------------------------ world shape

## Random phases that make each world's coast, mountains and zone borders different.
static func make_shape(rng: RandomNumberGenerator) -> Dictionary:
	var w := world_cfg()
	var ph := func(n: int) -> Array:
		var out: Array = []
		for i in n:
			out.append(rng.randf_range(0.0, TAU))
		return out
	return {
		"coast": {"base": float(w["coast_base_x"]), "p": ph.call(3)},
		"ridge": {"base": float(w["ridge_base_x"]), "width": float(w["ridge_width"]), "p": ph.call(3)},
		"zone": {"p": ph.call(2)},
		"rivers": [],
	}


static func coast_x(state: Dictionary, y: float) -> float:
	var c: Dictionary = state["geo"]["coast"]
	var p: Array = c["p"]
	return float(c["base"]) + 55.0 * sin(y / 170.0 + float(p[0])) + 28.0 * sin(y / 63.0 + float(p[1])) + 12.0 * sin(y / 27.0 + float(p[2]))


static func ridge_x(state: Dictionary, y: float) -> float:
	var r: Dictionary = state["geo"]["ridge"]
	var p: Array = r["p"]
	return float(r["base"]) + 90.0 * sin(y / 310.0 + float(p[0])) + 35.0 * sin(y / 120.0 + float(p[1]))


static func ridge_half_width(state: Dictionary, y: float) -> float:
	var r: Dictionary = state["geo"]["ridge"]
	return float(r["width"]) * (1.0 + 0.25 * sin(y / 140.0 + float(r["p"][2])))


static func is_land(state: Dictionary, x: float, y: float) -> bool:
	return x >= coast_x(state, y)


## The climate zone of a mainland point (DESIGN 2d-A). Overseas lands are always "tropics".
static func zone_at(state: Dictionary, x: float, y: float) -> String:
	if absf(x - ridge_x(state, y)) < ridge_half_width(state, y):
		return "highlands"
	var w := world_cfg()
	var p: Array = state["geo"]["zone"]["p"]
	var lat := y + 45.0 * sin(x / 130.0 + float(p[0])) + 22.0 * sin(x / 53.0 + float(p[1]))
	if lat < float(w["zone_cold_until_y"]):
		return "cold"
	if lat >= float(w["zone_warm_from_y"]):
		return "warm"
	return "temperate"


static func is_water_site(site: String) -> bool:
	return site == SITE_FJORD or site == SITE_COAST or site == SITE_RIVER


## Ocean ships can reach coasts, fjords and islands, but not river towns.
static func is_sea_site(site: String) -> bool:
	return site == SITE_FJORD or site == SITE_COAST


# ------------------------------------------------------------------ rivers

static func river(state: Dictionary, idx: int) -> Dictionary:
	return state["geo"]["rivers"][idx]


static func river_points(state: Dictionary, idx: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in river(state, idx)["points"]:
		out.append(Vector2(float(p[0]), float(p[1])))
	return out


static func river_length(state: Dictionary, idx: int) -> float:
	var cum: Array = river(state, idx)["cum"]
	return float(cum[cum.size() - 1])


## The point `pos` map units downstream from the river's source.
static func river_point_at(state: Dictionary, idx: int, pos: float) -> Vector2:
	var pts := river_points(state, idx)
	var cum: Array = river(state, idx)["cum"]
	for i in range(1, pts.size()):
		if pos <= float(cum[i]) or i == pts.size() - 1:
			var seg := float(cum[i]) - float(cum[i - 1])
			var f := 0.0 if seg <= 0.0 else clampf((pos - float(cum[i - 1])) / seg, 0.0, 1.0)
			return pts[i - 1].lerp(pts[i], f)
	return pts[pts.size() - 1]


## River course between two positions, in travel order (a → b).
static func river_segment(state: Dictionary, idx: int, pos_a: float, pos_b: float) -> PackedVector2Array:
	var pts := river_points(state, idx)
	var cum: Array = river(state, idx)["cum"]
	var out := PackedVector2Array([river_point_at(state, idx, pos_a)])
	if pos_a < pos_b:
		for i in pts.size():
			if float(cum[i]) > pos_a and float(cum[i]) < pos_b:
				out.append(pts[i])
	else:
		for i in range(pts.size() - 1, -1, -1):
			if float(cum[i]) < pos_a and float(cum[i]) > pos_b:
				out.append(pts[i])
	out.append(river_point_at(state, idx, pos_b))
	return out


static func cumulative(points: Array) -> Array:
	var cum: Array = [0.0]
	for i in range(1, points.size()):
		var a := Vector2(float(points[i - 1][0]), float(points[i - 1][1]))
		var b := Vector2(float(points[i][0]), float(points[i][1]))
		cum.append(float(cum[i - 1]) + a.distance_to(b))
	return cum


# ------------------------------------------------------------------ water geometry (shared by routes and the map)

static func city_pos(c: Dictionary) -> Vector2:
	return Vector2(float(c["x"]), float(c["y"]))


static func city_port(c: Dictionary) -> Vector2:
	var p: Array = c.get("port", [c["x"], c["y"]])
	return Vector2(float(p[0]), float(p[1]))


## Path from a town to where it meets the coast (fjord inlet or river), in travel order.
static func _to_port(state: Dictionary, c: Dictionary) -> PackedVector2Array:
	match String(c["site"]):
		SITE_FJORD:
			return PackedVector2Array([city_pos(c), city_port(c)])
		SITE_RIVER:
			var idx := int(c["river"])
			return river_segment(state, idx, float(c["river_pos"]), river_length(state, idx))
	return PackedVector2Array([city_pos(c)])


static func _offshore(state: Dictionary, y: float, dist: float) -> Vector2:
	return Vector2(coast_x(state, y) - dist, y)


static func _along_coast(state: Dictionary, ya: float, yb: float, dist: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var steps := maxi(1, int(absf(yb - ya) / 20.0))
	for i in steps + 1:
		out.append(_offshore(state, lerpf(ya, yb, float(i) / float(steps)), dist))
	return out


## The line a vehicle follows between two cities on a route type, in world coordinates (a → b).
static func route_polyline(state: Dictionary, a: String, b: String, route_type: String) -> PackedVector2Array:
	var ca: Dictionary = state["cities"][a]
	var cb: Dictionary = state["cities"][b]
	if route_type == "land":
		return PackedVector2Array([city_pos(ca), city_pos(cb)])
	var a_over: bool = ca["region"] == REGION_OVERSEAS
	var b_over: bool = cb["region"] == REGION_OVERSEAS
	if route_type == "sheltered" and ca["site"] == SITE_RIVER and cb["site"] == SITE_RIVER and int(ca["river"]) == int(cb["river"]):
		return river_segment(state, int(ca["river"]), float(ca["river_pos"]), float(cb["river_pos"]))
	var pts := _to_port(state, ca)
	var pa := city_port(ca)
	var pb := city_port(cb)
	var dist := 14.0 if route_type == "sheltered" else 70.0
	if not a_over and not b_over:
		pts.append_array(_along_coast(state, pa.y, pb.y, dist))
	elif not a_over:
		pts.append(_offshore(state, pa.y, dist))
	elif not b_over:
		pts.append(_offshore(state, pb.y, dist))
	var tail := _to_port(state, cb)
	tail.reverse()
	pts.append_array(tail)
	return pts


static func polyline_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total


# ------------------------------------------------------------------ what a place can produce (DESIGN 2d-A)

static func is_raw(good: String) -> bool:
	return RAW_GOODS.has(good)


## Raw goods a city's land and water allow: its zone's goods, Fish on water, Grain on a river.
static func raw_goods_for(city: Dictionary) -> Array:
	var z := zones()
	var out: Array = []
	for g in z["zones"][city["zone"]]["raw"]:
		out.append(g)
	if is_water_site(city["site"]):
		for g in z["water_goods"]:
			if not out.has(g):
				out.append(g)
	if city["site"] == SITE_RIVER:
		for g in z["river_goods"]:
			if not out.has(g):
				out.append(g)
	return out


static func site_allows(city: Dictionary, good: String) -> bool:
	return not is_raw(good) or raw_goods_for(city).has(good)


## Where a raw good can be found, for explanations: ["Highlands", "any coast, fjord or river", ...].
static func where_found(good: String) -> PackedStringArray:
	var z := zones()
	var out: PackedStringArray = []
	for zid in z["order"]:
		if z["zones"][zid]["raw"].has(good):
			out.append(z["zones"][zid]["label"])
	if z["water_goods"].has(good):
		out.append("any coast, fjord or river")
	if z["river_goods"].has(good):
		out.append("river towns")
	return out


## Weights for what an NPC city could produce, by zone, water and size.
static func production_weights(city: Dictionary) -> Dictionary:
	var pop := int(city["pop"])
	var w := {}
	for g in raw_goods_for(city):
		var t := Data.tier(g)
		if t == 2 and pop < 8000:
			continue
		w[g] = 3.0 if t != 2 else 2.0
	for g in zone_info(city["zone"])["processed"]:
		match Data.tier(g):
			2:
				if pop >= 10000:
					w[g] = 2.0
			3:
				if pop >= 50000:
					w[g] = 2.0
			4:
				if pop >= 120000:
					w[g] = 1.5
	return w


## Weights for what a city would pay a premium for. Bigger cities want finer goods; goods its own land
## can't produce are wanted more, which pulls trade between zones.
static func want_weights(city: Dictionary) -> Dictionary:
	var pop := int(city["pop"])
	var produces: Array = city["produces"]
	var own_raw := raw_goods_for(city)
	var makes_food := produces.has("Grain") or produces.has("Fish")
	var w := {}
	for id in Data.good_ids():
		if produces.has(id):
			continue
		var weight := 0.0
		match Data.tier(id):
			1:
				weight = 3.0
				if Data.is_food(id) and (pop >= 20000 or not makes_food):
					weight += 2.0
			2:
				weight = 2.0 if pop >= 8000 else 1.0
			3:
				weight = 2.0 if pop >= 30000 else 0.3
			4:
				weight = 1.0 if pop >= 100000 else 0.0
			0:
				weight = 1.0 if pop >= 50000 else 0.0
		if weight > 0.0 and is_raw(id) and not own_raw.has(id):
			weight *= 1.5
		if weight > 0.0:
			w[id] = weight
	return w


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


# ------------------------------------------------------------------ routes and travel time

static func route_key(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a


## Route between two cities: {"land": units|-1, "sheltered": units|-1, "ocean": units|-1, "ocean_exit_days": int}
static func route(state: Dictionary, a: String, b: String) -> Dictionary:
	return state["routes"].get(route_key(a, b), {})


## Travel time in whole days for one direct leg, or -1 if there is no direct route of that type.
## `speed_mult` scales the vehicle's speed (roads make the player's wagons faster, DESIGN 3G).
static func travel_days(state: Dictionary, a: String, b: String, route_type: String, vehicle := "", speed_mult := 1.0) -> int:
	var r := route(state, a, b)
	if r.is_empty():
		return -1
	var units := float(r[route_type])
	if units < 0.0:
		return -1
	var w := world_cfg()
	if vehicle == "":
		vehicle = w["route_vehicle"][route_type]
	var speed := float(w["speed_units_per_day"][vehicle]) * speed_mult
	var days := int(ceil(units / speed - 1e-9))
	if route_type == "ocean":
		days += int(r["ocean_exit_days"])
	return max(days, 1)


# Shortest-path trees are cached per origin; the route network never changes during a game, so the cache
# only has to be reset when a different game's routes are used.
static var _cache_routes: Dictionary = {}
static var _cache := {}


static func _tree(state: Dictionary, a: String, route_type: String, vehicle: String, speed_mult: float) -> Dictionary:
	if not is_same(state["routes"], _cache_routes):
		_cache.clear()
		_cache_routes = state["routes"]
	var key := "%s|%s|%s|%.4f" % [a, route_type, vehicle, speed_mult]
	if _cache.has(key):
		return _cache[key]
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
		if current == "":
			break
		done[current] = true
		for id in order:
			if done.has(id) or id == current:
				continue
			var d := travel_days(state, current, id, route_type, vehicle, speed_mult)
			if d > 0 and best + d < float(dist[id]):
				dist[id] = best + d
				prev[id] = current
	var tree := {"dist": dist, "prev": prev}
	_cache[key] = tree
	return tree


## Fastest way from a to b using only one route type (a wagon can't sail, a barge can't
## cross open sea), possibly through other cities. Returns {"days": int, "stops": [ids from a to b]},
## or {"days": -1, "stops": []} when b can't be reached that way.
static func best_path(state: Dictionary, a: String, b: String, route_type: String, vehicle := "", speed_mult := 1.0) -> Dictionary:
	if a == b:
		return {"days": 0, "stops": [a]}
	var tree := _tree(state, a, route_type, vehicle, speed_mult)
	var dist: Dictionary = tree["dist"]
	if not dist.has(b) or is_inf(float(dist[b])):
		return {"days": -1, "stops": []}
	var prev: Dictionary = tree["prev"]
	var stops: Array = [b]
	while stops[0] != a:
		stops.push_front(prev[stops[0]])
	return {"days": int(dist[b]), "stops": stops}
