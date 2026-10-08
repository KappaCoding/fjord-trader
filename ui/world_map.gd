## Schematic world map: land and sea, cities, the routes your vehicles use, and vehicles on the move.
## Read-only view of the game state; clicking a city emits `city_clicked`.
##
## The open sea between the mainland and the overseas lands is drawn compressed (not to scale);
## travel days are always shown as numbers.
extends Control

signal city_clicked(city_id: String)

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const Transport := preload("res://engine/transport.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

const OCEAN_SPLIT_X := 300.0
const OCEAN_COMPRESS := 0.35
const SEA := Color("1b3048")
const LAND := {"north": Color("56634f"), "temperate": Color("4a6342"), "south": Color("7a6f47")}
const COAST := Color("a9c2d0")
const OFFSHORE := 20.0
const OPEN_SEA := 70.0

var game: RefCounted
var selected_id := ""
var price_good := ""
var show_route := {"land": true, "sheltered": true, "ocean": false}
var preview_stops: Array = []
var preview_type := ""

var _scale := 1.0
var _offset := Vector2.ZERO
var _paths := {}  # route type -> {city id: [stops from home]}
var _hover := ""
var _reachable := {}  # city id -> true if a vehicle you own can get there


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "map"
	resized.connect(queue_redraw)


func set_game(g: RefCounted) -> void:
	game = g
	selected_id = g.state["home_id"]
	preview_stops = []
	_paths.clear()
	var s: Dictionary = g.state
	var home_id: String = s["home_id"]
	for rt in Geo.ROUTE_TYPES:
		var vtype: String = Data.balance()["world"]["route_vehicle"][rt]
		var by_city := {}
		for id in s["city_order"]:
			if id == home_id:
				continue
			var p := Geo.best_path(s, home_id, id, rt, vtype)
			if int(p["days"]) > 0:
				by_city[id] = p["stops"]
		_paths[rt] = by_city
	queue_redraw()


## Called by the dashboard whenever the state may have changed.
func refresh() -> void:
	if game == null:
		return
	_reachable.clear()
	var owned := {}
	for v in game.state["vehicles"]:
		owned[Transport.route_of(v["type"])] = true
	for rt in owned:
		for id in _paths.get(rt, {}):
			_reachable[id] = true
	queue_redraw()


# ------------------------------------------------------------------ coordinates

func _squash(p: Vector2) -> Vector2:
	var x := p.x
	if x < OCEAN_SPLIT_X:
		x = OCEAN_SPLIT_X + (x - OCEAN_SPLIT_X) * OCEAN_COMPRESS
	return Vector2(x, p.y)


func _fit() -> void:
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for id in game.state["city_order"]:
		var q := _squash(_world(id))
		minp = minp.min(q)
		maxp = maxp.max(q)
	minp -= Vector2(70, 50)
	maxp += Vector2(40, 60)
	maxp.x = maxf(maxp.x, 1040.0) + 70.0  # room for the names of the easternmost cities
	var world_size := maxp - minp
	var pad := 8.0
	var avail := size - Vector2(pad, pad) * 2.0
	_scale = minf(avail.x / world_size.x, avail.y / world_size.y)
	_offset = Vector2(pad, pad) + (avail - world_size * _scale) / 2.0 - minp * _scale


func _world(id: String) -> Vector2:
	var c: Dictionary = game.state["cities"][id]
	return Vector2(float(c["x"]), float(c["y"]))


func to_screen(world: Vector2) -> Vector2:
	return _squash(world) * _scale + _offset


func _city_px(id: String) -> Vector2:
	return to_screen(_world(id))


## Where a city meets navigable water: the fjord mouth for fjord towns, the town itself otherwise.
func _port(id: String) -> Vector2:
	var c: Dictionary = game.state["cities"][id]
	if c["site"] == "fjord":
		var y := float(c["y"])
		return to_screen(Vector2(Geo.coast_x(y + 12.0) - 6.0, y + 12.0))
	return _city_px(id)


func _offshore(y: float, dist: float) -> Vector2:
	return to_screen(Vector2(Geo.coast_x(y) - dist, y))


func _is_overseas(id: String) -> bool:
	return game.state["cities"][id]["region"] == Geo.REGION_OVERSEAS


## Polyline for one hop of a route, drawn from a to b.
func _edge(a: String, b: String, rt: String) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if rt == "land":
		pts.append(_city_px(a))
		pts.append(_city_px(b))
		return pts
	var ya := float(game.state["cities"][a]["y"])
	var yb := float(game.state["cities"][b]["y"])
	var a_over := _is_overseas(a)
	var b_over := _is_overseas(b)
	pts.append(_city_px(a))
	if a_over and b_over:
		pts.append(_city_px(b))
		return pts
	var dist := OFFSHORE if rt == "sheltered" else OPEN_SEA
	if not a_over:
		pts.append(_port(a))
	if not a_over and not b_over:
		var steps := maxi(1, int(absf(yb - ya) / 25.0))
		for i in steps + 1:
			pts.append(_offshore(lerpf(ya, yb, float(i) / float(steps)), dist))
	elif not a_over:
		pts.append(_offshore(ya, dist))
	else:
		pts.append(_offshore(yb, dist))
	if not b_over:
		pts.append(_port(b))
	pts.append(_city_px(b))
	return pts


func _stops_polyline(stops: Array, rt: String) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(1, stops.size()):
		var e := _edge(stops[i - 1], stops[i], rt)
		if not pts.is_empty():
			e.remove_at(0)
		pts.append_array(e)
	return pts


static func _point_along(pts: PackedVector2Array, f: float) -> Vector2:
	if pts.size() == 1:
		return pts[0]
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	var target := clampf(f, 0.0, 1.0) * total
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		if target <= seg or i == pts.size() - 1:
			return pts[i - 1].lerp(pts[i], 0.0 if seg == 0.0 else clampf(target / seg, 0.0, 1.0))
		target -= seg
	return pts[pts.size() - 1]


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SEA)
	if game == null:
		return
	_fit()
	_draw_mainland()
	_draw_islands()
	_draw_fjords()
	_draw_terrain()
	_draw_routes()
	_draw_highlight()
	_draw_preview()
	_draw_vehicles()
	_draw_cities()
	_draw_legend()


func _draw_mainland() -> void:
	var w: Dictionary = Data.balance()["world"]
	var bands := [
		[-400.0, float(w["climate_north_below_y"]), LAND["north"]],
		[float(w["climate_north_below_y"]), float(w["climate_temperate_below_y"]), LAND["temperate"]],
		[float(w["climate_temperate_below_y"]), 1600.0, LAND["south"]],
	]
	for b in bands:
		var pts := PackedVector2Array()
		var y: float = b[0]
		while y <= float(b[1]):
			pts.append(to_screen(Vector2(Geo.coast_x(y), y)))
			y += 10.0
		pts.append(to_screen(Vector2(Geo.coast_x(b[1]), b[1])))
		pts.append(to_screen(Vector2(2000.0, b[1])))
		pts.append(to_screen(Vector2(2000.0, b[0])))
		draw_colored_polygon(pts, b[2])
	var coast := PackedVector2Array()
	var cy := -400.0
	while cy <= 1600.0:
		coast.append(to_screen(Vector2(Geo.coast_x(cy), cy)))
		cy += 10.0
	draw_polyline(coast, COAST, 1.5, true)


func _draw_islands() -> void:
	for id in game.state["city_order"]:
		if not _is_overseas(id):
			continue
		var c: Dictionary = game.state["cities"][id]
		var center := _city_px(id)
		var r := 80.0 * _scale
		var phase := float(abs(String(c["name"]).hash()) % 1000) / 100.0
		var pts := PackedVector2Array()
		for i in 24:
			var a := TAU * float(i) / 24.0
			var k := 1.0 + 0.18 * sin(a * 3.0 + phase) + 0.1 * sin(a * 5.0 + phase * 2.0)
			pts.append(center + Vector2(cos(a), sin(a)) * r * k)
		draw_colored_polygon(pts, LAND[c["climate"]])
		pts.append(pts[0])
		draw_polyline(pts, COAST, 1.2, true)


func _draw_fjords() -> void:
	var width := clampf(11.0 * _scale, 3.0, 8.0)
	for id in game.state["city_order"]:
		if game.state["cities"][id]["site"] != "fjord":
			continue
		var a := _city_px(id)
		var b := _port(id)
		var mid := a.lerp(b, 0.5) + (b - a).orthogonal().normalized() * 6.0
		var pts := PackedVector2Array([a, mid, b, b + (b - mid).normalized() * 6.0])
		draw_polyline(pts, SEA, width, true)
		draw_circle(a, width * 0.5, SEA)


func _draw_terrain() -> void:
	var rock := Color("8e8e86")
	var snow := Color("d8dde0")
	var tree := Color("2c4727")
	for id in game.state["city_order"]:
		var c: Dictionary = game.state["cities"][id]
		var p := _city_px(id)
		var feats: Array = c["features"]
		if feats.has("mountains"):
			for o in [Vector2(-17, -9), Vector2(-9, -14), Vector2(-1, -9)]:
				var base: Vector2 = p + o
				draw_colored_polygon(PackedVector2Array([base + Vector2(-5, 4), base + Vector2(0, -5), base + Vector2(5, 4)]), rock)
				draw_colored_polygon(PackedVector2Array([base + Vector2(-1.6, -2), base + Vector2(0, -5), base + Vector2(1.6, -2)]), snow)
		if feats.has("forest"):
			for o in [Vector2(-14, 8), Vector2(-9, 12), Vector2(-17, 13)]:
				draw_circle(p + o, 2.6, tree)


func _route_style(rt: String, strong: bool) -> Dictionary:
	var col: Color = Style.ROUTE_COLORS[rt]
	if not strong:
		col.a = 0.55
	var w := 1.6 if rt != "sheltered" else 2.0
	if strong:
		w += 2.0
	return {"color": col, "width": w, "dash": 7.0 if rt == "land" else (3.0 if rt == "ocean" else 0.0)}


func _stroke(pts: PackedVector2Array, style: Dictionary) -> void:
	if float(style["dash"]) <= 0.0:
		draw_polyline(pts, style["color"], style["width"], true)
		return
	for i in range(1, pts.size()):
		draw_dashed_line(pts[i - 1], pts[i], style["color"], style["width"], style["dash"], true, true)


func _draw_routes() -> void:
	for rt in Geo.ROUTE_TYPES:
		if not show_route[rt]:
			continue
		var style := _route_style(rt, false)
		var seen := {}
		for id in _paths[rt]:
			var stops: Array = _paths[rt][id]
			for i in range(1, stops.size()):
				var key := Geo.route_key(stops[i - 1], stops[i])
				if seen.has(key):
					continue
				seen[key] = true
				_stroke(_edge(stops[i - 1], stops[i], rt), style)


func _draw_highlight() -> void:
	# The selected city's paths from home, for every route type (even ones hidden in the overview).
	if selected_id == "" or selected_id == game.state["home_id"] or not preview_stops.is_empty():
		return
	for rt in Geo.ROUTE_TYPES:
		if _paths[rt].has(selected_id):
			_stroke(_stops_polyline(_paths[rt][selected_id], rt), _route_style(rt, true))


func _draw_preview() -> void:
	if preview_stops.size() < 2:
		return
	var rt := Transport.route_of(preview_type)
	var pts := _stops_polyline(preview_stops, rt)
	draw_polyline(pts, Color(1, 1, 1, 0.9), 5.0, true)
	_stroke(pts, _route_style(rt, true))


func _draw_vehicles() -> void:
	var font := get_theme_default_font()
	for v in game.state["vehicles"]:
		var prog := Transport.trip_progress(game.state, v)
		if prog.is_empty():
			continue
		var stops: Array = prog["stops"]
		var hops: Array = prog["hop_days"]
		var elapsed: float = prog["elapsed_days"]
		var rt := Transport.route_of(v["type"])
		var pos := _city_px(stops[stops.size() - 1])
		var acc := 0.0
		for i in hops.size():
			var d := float(hops[i])
			if elapsed <= acc + d or i == hops.size() - 1:
				pos = _point_along(_edge(stops[i], stops[i + 1], rt), (elapsed - acc) / maxf(d, 0.001))
				break
			acc += d
		var col: Color = Style.VEHICLE_COLORS[v["type"]]
		draw_circle(pos, 7.0, Color(0, 0, 0, 0.7))
		draw_circle(pos, 5.5, col)
		var short := "%s%s" % [String(v["type"]).substr(0, 1).to_upper(), String(v["id"]).get_slice("-", 1)]
		draw_string_outline(font, pos + Vector2(8, -6), short, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.8))
		draw_string(font, pos + Vector2(8, -6), short, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)


func _city_radius(id: String) -> float:
	var pop := float(game.state["cities"][id]["pop"])
	return clampf(3.5 + 2.5 * log(pop / 1000.0) / log(10.0), 4.0, 10.0)


func _draw_cities() -> void:
	var font := get_theme_default_font()
	var home_id: String = game.state["home_id"]
	for id in game.state["city_order"]:
		var c: Dictionary = game.state["cities"][id]
		var p := _city_px(id)
		var r := _city_radius(id)
		var reachable: bool = id == home_id or _reachable.has(id)
		var fill := Style.NEUTRAL
		if price_good != "":
			fill = Style.band_color(c["market"][price_good]["band"])
		if id == home_id:
			fill = Style.HOME
		if id == selected_id:
			draw_arc(p, r + 4.0, 0.0, TAU, 32, Color.WHITE, 2.0, true)
		elif id == _hover:
			draw_arc(p, r + 3.0, 0.0, TAU, 32, Color(1, 1, 1, 0.5), 1.5, true)
		if reachable:
			draw_circle(p, r + 1.2, Color(0, 0, 0, 0.75))
			draw_circle(p, r, fill)
		else:
			draw_circle(p, r, Color(0, 0, 0, 0.35))
			draw_arc(p, r, 0.0, TAU, 32, fill.darkened(0.15), 1.6, true)
		if id == home_id:
			draw_arc(p, r + 2.0, 0.0, TAU, 32, Color(0, 0, 0, 0.8), 1.5, true)
		var name_col := Color.WHITE if reachable else Color(0.75, 0.75, 0.75)
		var text_pos := p + Vector2(r + 4.0, 5.0)
		_text(font, text_pos, c["name"], 14, name_col)
		if price_good != "":
			var price := int(Market.sell_lot_prices(game.state, id, price_good, 1)[0])
			_text(font, text_pos + Vector2(0, 15), Fmt.coins(price), 12, Style.band_color(c["market"][price_good]["band"]))


func _text(font: Font, pos: Vector2, text: String, font_size: int, col: Color) -> void:
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.85))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)


func _draw_legend() -> void:
	var font := get_theme_default_font()
	var rows := [
		["land", "Road — wagons"],
		["sheltered", "Sheltered water — barges"],
		["ocean", "Open sea — ocean ships (from Stage 3)"],
	]
	var box := Rect2(Vector2(8, 8), Vector2(262, 100))
	draw_rect(box, Color(0, 0, 0, 0.62))
	var y := box.position.y + 18.0
	for row in rows:
		var st := _route_style(row[0], true)
		st["width"] = 2.5
		_stroke(PackedVector2Array([Vector2(box.position.x + 10, y - 4), Vector2(box.position.x + 40, y - 4)]), st)
		draw_string(font, Vector2(box.position.x + 48, y), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		y += 19.0
	draw_arc(Vector2(box.position.x + 25, y - 4), 5.0, 0.0, TAU, 20, Style.NEUTRAL, 1.6, true)
	draw_string(font, Vector2(box.position.x + 48, y), "Hollow: none of your vehicles can reach it", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	y += 19.0
	draw_string(font, Vector2(box.position.x + 10, y), "The open sea is not drawn to scale.", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.MUTED)


# ------------------------------------------------------------------ input

func _city_at(pos: Vector2) -> String:
	var best := ""
	var best_d := INF
	for id in game.state["city_order"]:
		var d := _city_px(id).distance_to(pos)
		if d <= _city_radius(id) + 7.0 and d < best_d:
			best = id
			best_d = d
	return best


func _gui_input(event: InputEvent) -> void:
	if game == null:
		return
	if event is InputEventMouseMotion:
		var h := _city_at(event.position)
		if h != _hover:
			_hover = h
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var id := _city_at(event.position)
		if id != "":
			city_clicked.emit(id)
			accept_event()


func _get_tooltip(at_position: Vector2) -> String:
	if game == null:
		return ""
	var id := _city_at(at_position)
	if id == "":
		return ""
	var s: Dictionary = game.state
	var c: Dictionary = s["cities"][id]
	var lines: PackedStringArray = ["%s · population %s" % [c["name"], Fmt.coins(int(c["pop"]))]]
	if id == s["home_id"]:
		lines.append("Your settlement")
	else:
		for vtype in ["wagon", "barge", "ocean"]:
			var p := Transport.path_for(s, s["home_id"], id, vtype)
			var word: String = Transport.ROUTE_WORDS[Transport.route_of(vtype)]
			if int(p["days"]) > 0:
				lines.append("%s: %s by %s" % [Transport.label_of(vtype), Style.days(int(p["days"])), word])
			else:
				lines.append("%s: no %s route" % [Transport.label_of(vtype), word])
	lines.append("Produces: %s" % ", ".join(PackedStringArray(c["produces"] if id != s["home_id"] else c["production_options"])))
	lines.append("Wants: %s" % ", ".join(PackedStringArray(c["wants"])))
	lines.append("Click for its market")
	return "\n".join(lines)
