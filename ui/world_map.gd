## The world map: climate zones, coast, mountains, rivers, fjords, islands, cities, the routes your vehicles use,
## and vehicles on the move. Scroll to zoom, drag to pan, double-click to fit. Clicking a city emits `city_clicked`.
## Read-only view of the game state; all geometry comes from engine/geo.gd.
##
## The open sea between the mainland and the overseas islands is drawn compressed (not to scale);
## travel days are always shown as numbers.
extends Control

signal city_clicked(city_id: String)

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const Transport := preload("res://engine/transport.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

const OCEAN_COMPRESS := 0.35
const SEA := Color("1b3048")
const COAST := Color("a9c2d0")
const RIVER := Color("5fb0dc")
const ROCK := Color("9a948a")
const SNOW := Color("e1e5e8")
const ZONE_TEX_UNITS := 5.0  # map units per texture pixel
const ZONE_RECT := Rect2(300.0, -500.0, 1500.0, 2300.0)  # mainland area covered by the zone texture (beyond any view)
const MAX_ZOOM := 6.0

var game: RefCounted
var selected_id := ""
var price_good := ""
var show_route := {"land": true, "sheltered": true, "ocean": false}
var preview_stops: Array = []
var preview_type := ""

var _scale := 1.0
var _offset := Vector2.ZERO
var _zoom := 1.0
var _pan := Vector2.ZERO
var _paths := {}  # route type -> {city id: [stops from home]}
var _edges := {}  # "rt|a|b" -> PackedVector2Array in world coordinates
var _hover := ""
var _reachable := {}  # city id -> true if a vehicle you own can get there
var _zone_tex: ImageTexture
var _press_pos := Vector2.ZERO
var _dragging := false
var _pressed := false
var _legend_open := true
var _legend_rect := Rect2()


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
	_edges.clear()
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
	_zone_tex = _build_zone_texture()
	reset_view()


func reset_view() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
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
	if x < Geo.OCEAN_SPLIT_X:
		x = Geo.OCEAN_SPLIT_X + (x - Geo.OCEAN_SPLIT_X) * OCEAN_COMPRESS
	return Vector2(x, p.y)


func _fit() -> void:
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for id in game.state["city_order"]:
		var q := _squash(_world(id))
		minp = minp.min(q)
		maxp = maxp.max(q)
	minp -= Vector2(90, 40)
	maxp += Vector2(40, 40)
	maxp.x = maxf(maxp.x, 1300.0) + 60.0  # room for the names of the easternmost cities
	var world_size := maxp - minp
	var pad := 6.0
	var avail := size - Vector2(pad, pad) * 2.0
	_scale = minf(avail.x / world_size.x, avail.y / world_size.y)
	_offset = Vector2(pad, pad) + (avail - world_size * _scale) / 2.0 - minp * _scale


func _world(id: String) -> Vector2:
	return Geo.city_pos(game.state["cities"][id])


func to_screen(world: Vector2) -> Vector2:
	return (_squash(world) * _scale + _offset) * _zoom + _pan


func _city_px(id: String) -> Vector2:
	return to_screen(_world(id))


func _poly(world_pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in world_pts:
		out.append(to_screen(p))
	return out


func _edge_world(a: String, b: String, rt: String) -> PackedVector2Array:
	var key := "%s|%s|%s" % [rt, a, b]
	if not _edges.has(key):
		_edges[key] = Geo.route_polyline(game.state, a, b, rt)
	return _edges[key]


func _edge(a: String, b: String, rt: String) -> PackedVector2Array:
	return _poly(_edge_world(a, b, rt))


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


# ------------------------------------------------------------------ zone texture

func _build_zone_texture() -> ImageTexture:
	var s: Dictionary = game.state
	var w := int(ZONE_RECT.size.x / ZONE_TEX_UNITS)
	var h := int(ZONE_RECT.size.y / ZONE_TEX_UNITS)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var colors := {}
	for z in Geo.zones()["order"]:
		colors[z] = Color(String(Geo.zone_info(z)["color"]))
	for py in h:
		var wy := ZONE_RECT.position.y + (float(py) + 0.5) * ZONE_TEX_UNITS
		var coast := Geo.coast_x(s, wy)
		for px in w:
			var wx := ZONE_RECT.position.x + (float(px) + 0.5) * ZONE_TEX_UNITS
			if wx < coast:
				img.set_pixel(px, py, Color(0, 0, 0, 0))
				continue
			var c: Color = colors[Geo.zone_at(s, wx, wy)]
			var n := 0.035 * sin(wx * 0.09 + wy * 0.05) * sin(wy * 0.07 - wx * 0.03)
			img.set_pixel(px, py, c.lightened(n) if n > 0.0 else c.darkened(-n))
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SEA)
	if game == null:
		return
	_fit()
	_draw_land()
	_draw_mountains()
	_draw_rivers()
	_draw_islands()
	_draw_fjords()
	_draw_routes()
	_draw_highlight()
	_draw_preview()
	_draw_vehicles()
	_draw_cities()
	_draw_legend()


func _draw_land() -> void:
	var tl := to_screen(ZONE_RECT.position)
	var br := to_screen(ZONE_RECT.end)
	draw_texture_rect(_zone_tex, Rect2(tl, br - tl), false)
	var s: Dictionary = game.state
	var coast := PackedVector2Array()
	var y := ZONE_RECT.position.y
	while y <= ZONE_RECT.end.y:
		coast.append(to_screen(Vector2(Geo.coast_x(s, y), y)))
		y += 8.0
	draw_polyline(coast, COAST, 1.5, true)


func _draw_mountains() -> void:
	var s: Dictionary = game.state
	var k := clampf(_zoom, 1.0, 2.5)
	var y := -40.0
	var i := 0
	while y <= 1360.0:
		var hw := Geo.ridge_half_width(s, y)
		for off in [-0.45, 0.05, 0.5]:
			var jitter := 14.0 * sin(float(i) * 1.7 + float(off) * 5.0)
			var p := to_screen(Vector2(Geo.ridge_x(s, y) + hw * float(off) + jitter, y + 18.0 * float(off)))
			var sz := 6.0 * k
			draw_colored_polygon(PackedVector2Array([p + Vector2(-sz, sz * 0.7), p + Vector2(0, -sz), p + Vector2(sz, sz * 0.7)]), ROCK)
			draw_colored_polygon(PackedVector2Array([p + Vector2(-sz * 0.33, -sz * 0.45), p + Vector2(0, -sz), p + Vector2(sz * 0.33, -sz * 0.45)]), SNOW)
		y += 46.0
		i += 1


func _draw_rivers() -> void:
	var s: Dictionary = game.state
	var width := clampf(2.2 * _zoom, 2.0, 6.0)
	for i in s["geo"]["rivers"].size():
		var pts := _poly(Geo.river_points(s, i))
		draw_polyline(pts, RIVER, width, true)


func _draw_islands() -> void:
	var col := Color(String(Geo.zone_info("tropics")["color"]))
	for id in game.state["city_order"]:
		var c: Dictionary = game.state["cities"][id]
		if c["region"] != Geo.REGION_OVERSEAS:
			continue
		var center := _city_px(id)
		var r := 80.0 * _scale * _zoom
		var phase := float(abs(String(c["name"]).hash()) % 1000) / 100.0
		var pts := PackedVector2Array()
		for i in 28:
			var a := TAU * float(i) / 28.0
			var k := 1.0 + 0.18 * sin(a * 3.0 + phase) + 0.1 * sin(a * 5.0 + phase * 2.0)
			pts.append(center + Vector2(cos(a), sin(a)) * r * k)
		draw_colored_polygon(pts, col)
		pts.append(pts[0])
		draw_polyline(pts, COAST, 1.2, true)


func _draw_fjords() -> void:
	var width := clampf(8.0 * _scale * _zoom, 3.0, 10.0)
	for id in game.state["city_order"]:
		var c: Dictionary = game.state["cities"][id]
		if c["site"] != Geo.SITE_FJORD:
			continue
		var a := _city_px(id)
		var b := to_screen(Geo.city_port(c))
		var mid := a.lerp(b, 0.5) + (b - a).orthogonal().normalized() * 5.0
		var ext := b + (b - mid).normalized() * 6.0
		draw_polyline(PackedVector2Array([a, mid, b, ext]), SEA, width, true)
		draw_circle(a, width * 0.5, SEA)


func _route_style(rt: String, strong: bool) -> Dictionary:
	var col: Color = Style.ROUTE_COLORS[rt]
	if not strong:
		col.a = 0.6
	var w := 1.6 if rt != "sheltered" else 2.0
	if strong:
		w += 2.0
	return {"color": col, "width": w, "dash": 7.0 if rt == "land" else (3.0 if rt == "ocean" else 0.0)}


func _stroke(pts: PackedVector2Array, style: Dictionary) -> void:
	if pts.size() < 2:
		return
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
	return clampf(3.5 + 2.5 * log(pop / 1000.0) / log(10.0), 4.0, 10.0) * clampf(0.85 + 0.15 * _zoom, 1.0, 1.6)


func _draw_cities() -> void:
	var font := get_theme_default_font()
	var home_id: String = game.state["home_id"]
	var font_size := 13 if _zoom < 1.5 else 15
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
		var name_col := Color.WHITE if reachable else Color(0.78, 0.78, 0.78)
		var text_pos := p + Vector2(r + 4.0, 5.0)
		_text(font, text_pos, c["name"], font_size, name_col)
		if price_good != "":
			var price := int(Market.sell_lot_prices(game.state, id, price_good, 1)[0])
			_text(font, text_pos + Vector2(0, font_size + 1), Fmt.coins(price), font_size - 2, Style.band_color(c["market"][price_good]["band"]))


func _text(font: Font, pos: Vector2, text: String, font_size: int, col: Color) -> void:
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.85))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)


func _draw_legend() -> void:
	var font := get_theme_default_font()
	if not _legend_open:
		_legend_rect = Rect2(Vector2(8, 8), Vector2(74, 22))
		draw_rect(_legend_rect, Color(0, 0, 0, 0.62))
		draw_string(font, Vector2(16, 24), "Legend ▸", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		return
	var box := Rect2(Vector2(8, 8), Vector2(430, 124))
	_legend_rect = box
	draw_rect(box, Color(0, 0, 0, 0.62))
	var x0 := box.position.x + 10.0
	var y := box.position.y + 18.0
	var rows := [["land", "Road — wagons"], ["sheltered", "Coast, fjord, river — barges"], ["ocean", "Open sea — ocean ships"]]
	for row in rows:
		var st := _route_style(row[0], true)
		st["width"] = 2.5
		_stroke(PackedVector2Array([Vector2(x0, y - 4), Vector2(x0 + 28, y - 4)]), st)
		draw_string(font, Vector2(x0 + 36, y), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		y += 19.0
	draw_arc(Vector2(x0 + 14, y - 4), 5.0, 0.0, TAU, 20, Style.NEUTRAL, 1.6, true)
	draw_string(font, Vector2(x0 + 36, y), "Hollow: you can't reach it yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	y += 19.0
	draw_string(font, Vector2(x0, y), "Scroll: zoom · drag: pan · double-click: fit", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.MUTED)
	y += 16.0
	draw_string(font, Vector2(x0, y), "Open sea not to scale · click here to hide", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.MUTED)
	var zx := box.position.x + 250.0
	var zy := box.position.y + 18.0
	for z in Geo.zones()["order"]:
		draw_rect(Rect2(Vector2(zx, zy - 10), Vector2(14, 11)), Color(String(Geo.zone_info(z)["color"])))
		draw_string(font, Vector2(zx + 20, zy), Geo.zone_label(z), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		zy += 19.0
	draw_line(Vector2(zx, zy - 5), Vector2(zx + 14, zy - 5), RIVER, 2.5)
	draw_string(font, Vector2(zx + 20, zy), "River", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


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


func _zoom_at(cursor: Vector2, factor: float) -> void:
	var nz := clampf(_zoom * factor, 1.0, MAX_ZOOM)
	if is_equal_approx(nz, _zoom):
		return
	_pan = cursor - (cursor - _pan) * (nz / _zoom)
	_zoom = nz
	if is_equal_approx(_zoom, 1.0):
		_pan = Vector2.ZERO
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if game == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.15)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.15)
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _legend_rect.has_point(mb.position):
				_legend_open = not _legend_open
				queue_redraw()
				accept_event()
				return
			if mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
				reset_view()
				accept_event()
				return
			if mb.pressed:
				_pressed = true
				_dragging = false
				_press_pos = mb.position
			else:
				if not _dragging and mb.button_index == MOUSE_BUTTON_LEFT:
					var id := _city_at(mb.position)
					if id != "":
						city_clicked.emit(id)
				_pressed = false
				_dragging = false
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _pressed and (_dragging or mm.position.distance_to(_press_pos) > 4.0):
			_dragging = true
			_pan += mm.relative
			queue_redraw()
			return
		var h := _city_at(mm.position)
		if h != _hover:
			_hover = h
			queue_redraw()


func _get_tooltip(at_position: Vector2) -> String:
	if game == null:
		return ""
	var id := _city_at(at_position)
	if id == "":
		return ""
	var s: Dictionary = game.state
	var c: Dictionary = s["cities"][id]
	var site: String = {"fjord": "fjord town", "coast": "coastal town", "river": "river town", "inland": "inland town"}[c["site"]]
	if c["region"] == Geo.REGION_OVERSEAS:
		site = "overseas port"
	var lines: PackedStringArray = ["%s · population %s" % [c["name"], Fmt.coins(int(c["pop"]))], "%s · %s" % [Geo.zone_label(c["zone"]), site]]
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
