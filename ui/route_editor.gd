## The route editor (DESIGN 2c-F): load at home → stops with goods to sell and buy → back home.
## Run once, or repeat as a standing trade route. All checks and estimates come from
## Transport.plan_route; this dialog only edits the route description.
extends ConfirmationDialog

signal submitted(vehicle_id: String, route: Dictionary)
signal preview_changed(stops: Array, vtype: String)

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Simulation := preload("res://engine/simulation.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

const WIDTH := 900
const HEIGHT := 1000

var game: RefCounted
var _vid := ""
var _route := {"load": {}, "stops": [], "repeat": false}
var _plan := {}
var _signature := ""
var _building := false
var _vehicle_opt: OptionButton
var _repeat: CheckBox
var _route_line: RichTextLabel
var _body: VBoxContainer
var _summary: RichTextLabel
var _stop_info: Array = []


func _ready() -> void:
	title = "Plan a route"
	ok_button_text = "Send"
	min_size = Vector2i(WIDTH, HEIGHT)
	confirmed.connect(func(): submitted.emit(_vid, _route.duplicate(true)))
	visibility_changed.connect(_on_visibility)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	root.add_child(top)
	top.add_child(Style.label("Vehicle"))
	_vehicle_opt = OptionButton.new()
	_vehicle_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vehicle_opt.item_selected.connect(_on_vehicle_selected)
	top.add_child(_vehicle_opt)
	_repeat = CheckBox.new()
	_repeat.text = "Repeat (standing trade route)"
	_repeat.tooltip_text = "Keep running this route until you stop it. Each loop reloads at home."
	_repeat.toggled.connect(func(on: bool):
		_route["repeat"] = on
		_recalc())
	top.add_child(_repeat)

	_route_line = Style.rich()
	_route_line.custom_minimum_size.x = WIDTH - 40
	root.add_child(_route_line)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	scroll.add_child(_body)

	root.add_child(HSeparator.new())
	_summary = Style.rich()
	_summary.custom_minimum_size.x = WIDTH - 40
	root.add_child(_summary)


func _on_visibility() -> void:
	if not visible:
		preview_changed.emit([], "")


## Opens the editor. `route` may hold -1 presets: load -1 = as much as fits, buy -1 = fill the hold.
func open_for(g: RefCounted, vehicle_id := "", route := {}) -> bool:
	game = g
	var s: Dictionary = game.state
	var idle := Transport.idle_vehicles(s)
	if idle.is_empty():
		return false
	var first_city := ""
	if not route.get("stops", []).is_empty():
		first_city = route["stops"][0]["city"]
	if vehicle_id == "" or Transport.vehicle(s, vehicle_id).is_empty() or not Transport.is_idle_at_home(s, Transport.vehicle(s, vehicle_id)):
		vehicle_id = _best_vehicle_for(idle, first_city) if first_city != "" else String(idle[0]["id"])
	_vid = vehicle_id
	_building = true
	_vehicle_opt.clear()
	for v in idle:
		_vehicle_opt.add_item("%s — carries %d lots by %s" % [v["name"], int(v["capacity"]), Transport.ROUTE_WORDS[Transport.route_of(v["type"])]])
		_vehicle_opt.set_item_metadata(_vehicle_opt.item_count - 1, v["id"])
		if v["id"] == _vid:
			_vehicle_opt.select(_vehicle_opt.item_count - 1)
	_building = false
	_route = _apply_presets(route.duplicate(true))
	if _route["stops"].is_empty():
		_add_stop()
	_repeat.set_pressed_no_signal(bool(_route["repeat"]))
	_rebuild()
	popup(Rect2i(Vector2i(8, 40), Vector2i(WIDTH, HEIGHT)))
	return true


func _best_vehicle_for(idle: Array, dest: String) -> String:
	var best := String(idle[0]["id"])
	var best_days := 1 << 30
	for v in idle:
		var d := int(Transport.path_for(game.state, game.state["home_id"], dest, v["type"])["days"])
		if d > 0 and d < best_days:
			best = v["id"]
			best_days = d
	return best


func _cap() -> int:
	var v := Transport.vehicle(game.state, _vid)
	return int(v["capacity"]) if not v.is_empty() else 0


func _apply_presets(route: Dictionary) -> Dictionary:
	var home: Dictionary = Economy.home(game.state)
	var cap := _cap()
	var to_load := {}
	var loaded := 0
	for g in route.get("load", {}):
		var n := int(route["load"][g])
		if n < 0:
			n = mini(Economy.available_for_load(home, g), cap - loaded)
		n = mini(n, Economy.available_for_load(home, g))
		if n > 0:
			to_load[g] = n
			loaded += n
	var stops: Array = []
	for st in route.get("stops", []):
		var stop := {"city": st["city"], "sell": {}, "buy": {}}
		for g in st.get("sell", {}):
			stop["sell"][g] = {"lots": int(st["sell"][g].get("lots", -1)), "min": int(st["sell"][g].get("min", 0))}
		for g in st.get("buy", {}):
			var n := int(st["buy"][g].get("lots", 0))
			if n < 0:
				n = cap - (loaded if stop["sell"].is_empty() else 0)
			stop["buy"][g] = {"lots": maxi(0, n), "max": int(st["buy"][g].get("max", 0))}
		stops.append(stop)
	return {"load": to_load, "stops": stops, "repeat": bool(route.get("repeat", false))}


func _vtype() -> String:
	var v := Transport.vehicle(game.state, _vid)
	return String(v["type"]) if not v.is_empty() else "wagon"


func _reachable_ids() -> Array:
	var out: Array = []
	for e in Transport.reachable(game.state, game.state["home_id"], _vtype()):
		out.append(e["city"])
	return out


func _add_stop() -> void:
	var stops: Array = _route["stops"]
	var last := String(stops[stops.size() - 1]["city"]) if not stops.is_empty() else ""
	var pick := ""
	for id in _reachable_ids():
		if id != last:
			pick = id
			break
	stops.append({"city": pick, "sell": {}, "buy": {}})


# ------------------------------------------------------------------ building the form

func _on_vehicle_selected(index: int) -> void:
	if _building:
		return
	_vid = String(_vehicle_opt.get_item_metadata(index))
	_rebuild()


func _make_signature(p: Dictionary) -> String:
	var parts: PackedStringArray = [_vid, str(_route["stops"].size())]
	for est in p.get("stops", []):
		var goods: Array = []
		for g in est["onboard"]:
			if int(est["onboard"][g]) > 0:
				goods.append(g)
		goods.sort()
		parts.append(String(est["city"]) + ":" + ",".join(PackedStringArray(goods)))
	return "|".join(parts)


func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()


func _rebuild() -> void:
	if game == null:
		return
	_building = true
	_clear(_body)
	_stop_info.clear()
	_plan = game.plan_route(_vid, _route)
	_signature = _make_signature(_plan)
	_build_load_section()
	for i in _route["stops"].size():
		_build_stop(i)
	var add := Button.new()
	add.text = "+ Add a stop"
	add.tooltip_text = "Add another city to visit before coming home"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.pressed.connect(func():
		_add_stop()
		_rebuild())
	_body.add_child(add)
	_building = false
	_recalc()


func _build_load_section() -> void:
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)
	var panel := _panel()
	var vb: VBoxContainer = panel.get_child(0)
	vb.add_child(Style.heading("Load at %s" % home["name"]))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	var any := false
	for g in Data.good_ids():
		var avail := Economy.available_for_load(home, g)
		if avail <= 0 and not _route["load"].has(g):
			continue
		if not any:
			for h in ["Good", "Can load", "Lots"]:
				grid.add_child(Style.label(h, Style.MUTED, 13))
		any = true
		grid.add_child(Style.label(g))
		var res := Economy.reserve(home, g)
		grid.add_child(Style.label("%d%s" % [avail, " (keeping %d)" % res if res > 0 else ""], Style.MUTED))
		var spin := _spin(mini(avail, _cap()), int(_route["load"].get(g, 0)), 1)
		spin.value_changed.connect(func(v: float):
			if _building:
				return
			if int(v) > 0:
				_route["load"][g] = int(v)
			else:
				_route["load"].erase(g)
			_recalc())
		grid.add_child(spin)
	if any:
		vb.add_child(grid)
	else:
		vb.add_child(Style.label("Nothing in the warehouse to load (or it is all kept in reserve).", Style.MUTED))
	_body.add_child(panel)


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)
	return panel


func _build_stop(i: int) -> void:
	var s: Dictionary = game.state
	var stops: Array = _route["stops"]
	var st: Dictionary = stops[i]
	var city_id := String(st["city"])
	var panel := _panel()
	var vb: VBoxContainer = panel.get_child(0)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var title_l := Style.label("Stop %d" % (i + 1), Color.WHITE, 16)
	head.add_child(title_l)
	var city_opt := OptionButton.new()
	city_opt.custom_minimum_size.x = 220
	for id in _reachable_ids():
		city_opt.add_item(s["cities"][id]["name"])
		city_opt.set_item_metadata(city_opt.item_count - 1, id)
		if id == city_id:
			city_opt.select(city_opt.item_count - 1)
	if city_opt.selected < 0 and city_opt.item_count > 0:
		city_opt.select(0)
		st["city"] = city_opt.get_item_metadata(0)
		city_id = st["city"]
	city_opt.item_selected.connect(func(idx: int):
		st["city"] = String(city_opt.get_item_metadata(idx))
		var keep := {}
		for g in st["buy"]:
			if Market.city_sells(s, st["city"], g):
				keep[g] = st["buy"][g]
		st["buy"] = keep
		_rebuild.call_deferred())
	head.add_child(city_opt)
	var info := Style.rich()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(info)
	_stop_info.append(info)
	var up := Button.new()
	up.text = "▲"
	up.tooltip_text = "Visit earlier"
	up.disabled = i == 0
	up.pressed.connect(func(): _move_stop(i, -1))
	head.add_child(up)
	var down := Button.new()
	down.text = "▼"
	down.tooltip_text = "Visit later"
	down.disabled = i == stops.size() - 1
	down.pressed.connect(func(): _move_stop(i, 1))
	head.add_child(down)
	var rm := Button.new()
	rm.text = "✕"
	rm.tooltip_text = "Remove this stop"
	rm.pressed.connect(func():
		stops.remove_at(i)
		_rebuild())
	head.add_child(rm)
	vb.add_child(head)

	if city_id == "" or not s["cities"].has(city_id):
		vb.add_child(Style.label("No city this vehicle can reach.", Style.BAD))
		_body.add_child(panel)
		return

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 30)
	vb.add_child(cols)

	# Sell column
	var sell_box := VBoxContainer.new()
	sell_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(sell_box)
	var sell_head := HBoxContainer.new()
	sell_head.add_child(Style.label("Sell here", Style.WANT))
	var all_btn := Button.new()
	all_btn.text = "Sell everything"
	all_btn.tooltip_text = "Sell every good that is on board when the vehicle arrives"
	all_btn.pressed.connect(func():
		var est := _stop_estimate(i)
		for g in est.get("onboard", {}):
			if int(est["onboard"][g]) > 0:
				var lim := int(st["sell"].get(g, {}).get("min", 0))
				st["sell"][g] = {"lots": -1, "min": lim}
		_rebuild())
	sell_head.add_child(all_btn)
	sell_box.add_child(sell_head)
	var est := _stop_estimate(i)
	var onboard: Dictionary = est.get("onboard", {})
	var sell_goods: Array = []
	for g in Data.good_ids():
		if int(onboard.get(g, 0)) > 0 or st["sell"].has(g):
			sell_goods.append(g)
	if sell_goods.is_empty():
		sell_box.add_child(Style.label("Nothing on board when it arrives.", Style.MUTED))
	else:
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 8)
		for h in ["Good", "On board", "Lots", "Min. price"]:
			grid.add_child(Style.label(h, Style.MUTED, 13))
		for g in sell_goods:
			var band: String = s["cities"][city_id]["market"][g]["band"]
			var name_l := Style.label(g, Style.band_color(band))
			name_l.tooltip_text = "%s pays %s for the first lot" % [s["cities"][city_id]["name"], Fmt.coins(Market.sell_lot_prices(s, city_id, g, 1)[0])]
			grid.add_child(name_l)
			grid.add_child(Style.right(Style.label(str(int(onboard.get(g, 0))))))
			var entry: Dictionary = st["sell"].get(g, {"lots": 0, "min": 0})
			var shown := int(onboard.get(g, 0)) if int(entry["lots"]) < 0 else int(entry["lots"])
			var lots := _spin(999, shown, 1)
			lots.tooltip_text = "Lots to sell here (it sells what is on board, up to this many)"
			lots.value_changed.connect(func(v: float):
				if _building:
					return
				var e: Dictionary = st["sell"].get(g, {"lots": 0, "min": 0})
				e["lots"] = int(v)
				st["sell"][g] = e
				_recalc())
			grid.add_child(lots)
			var lim := _spin(1000000000, int(entry["min"]), 1000)
			lim.tooltip_text = "Only sell while a lot fetches at least this much (0 = no limit)"
			lim.value_changed.connect(func(v: float):
				if _building:
					return
				var e: Dictionary = st["sell"].get(g, {"lots": 0, "min": 0})
				e["min"] = int(v)
				st["sell"][g] = e
				_recalc())
			grid.add_child(lim)
		sell_box.add_child(grid)

	# Buy column
	var buy_box := VBoxContainer.new()
	buy_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(buy_box)
	buy_box.add_child(Style.label("Buy here", Style.SURPLUS))
	var sold_here: Array = []
	for g in Data.good_ids():
		if Market.city_sells(s, city_id, g):
			sold_here.append(g)
	if sold_here.is_empty():
		buy_box.add_child(Style.label("This city sells nothing.", Style.MUTED))
	else:
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 8)
		for h in ["Good", "Price now", "Lots", "Max. price"]:
			grid.add_child(Style.label(h, Style.MUTED, 13))
		for g in sold_here:
			grid.add_child(Style.label(g, Style.SURPLUS))
			grid.add_child(Style.right(Style.label(Fmt.coins(Market.listed_price(s, city_id, g)))))
			var entry: Dictionary = st["buy"].get(g, {"lots": 0, "max": 0})
			var lots := _spin(_cap(), int(entry["lots"]), 1)
			lots.value_changed.connect(func(v: float):
				if _building:
					return
				var e: Dictionary = st["buy"].get(g, {"lots": 0, "max": 0})
				e["lots"] = int(v)
				st["buy"][g] = e
				_recalc())
			grid.add_child(lots)
			var lim := _spin(1000000000, int(entry["max"]), 1000)
			lim.tooltip_text = "Only buy while a lot costs at most this much (0 = no limit)"
			lim.value_changed.connect(func(v: float):
				if _building:
					return
				var e: Dictionary = st["buy"].get(g, {"lots": 0, "max": 0})
				e["max"] = int(v)
				st["buy"][g] = e
				_recalc())
			grid.add_child(lim)
		buy_box.add_child(grid)
	_body.add_child(panel)


func _stop_estimate(i: int) -> Dictionary:
	var stops: Array = _plan.get("stops", [])
	return stops[i] if i < stops.size() else {}


func _move_stop(i: int, delta: int) -> void:
	var stops: Array = _route["stops"]
	var j := i + delta
	if j < 0 or j >= stops.size():
		return
	var tmp: Dictionary = stops[i]
	stops[i] = stops[j]
	stops[j] = tmp
	_rebuild()


func _spin(max_value: int, value: int, step: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 0
	spin.max_value = maxi(0, max_value)
	spin.step = step
	spin.rounded = true
	spin.allow_greater = step > 1
	spin.custom_minimum_size.x = 96 if step == 1 else 130
	spin.value = clampi(value, 0, maxi(value, max_value))
	return spin


# ------------------------------------------------------------------ estimate

func refresh_estimate() -> void:
	_recalc()


func _recalc() -> void:
	if _building or game == null or not is_inside_tree():
		return
	var s: Dictionary = game.state
	_plan = game.plan_route(_vid, _route)
	var muted := Style.hex(Style.MUTED)
	var legs: Array = _plan["legs"]

	var leg_parts: PackedStringArray = []
	for leg in legs:
		leg_parts.append("%s → %s %dd" % [s["cities"][leg["from"]]["name"], s["cities"][leg["to"]]["name"], int(leg["days"])])
	var rt := Transport.route_of(_vtype())
	_route_line.text = "[color=#%s]■[/color] By %s: %s  ·  [b]%s per trip[/b]" % [
		Style.hex(Style.ROUTE_COLORS[rt]), Transport.ROUTE_WORDS[rt], "  ·  ".join(leg_parts), Style.days(int(_plan["days"]))]

	for i in _stop_info.size():
		var est := _stop_estimate(i)
		var text := ""
		if i < legs.size():
			text = "[color=#%s]%s from the previous stop · arrives ~%s[/color]" % [
				muted, Style.days(int(legs[i]["days"])), Simulation.short_date(s, int(s["time_hours"]) + _days_until(i) * 24)]
		var sales := 0
		var cost := 0
		for x in est.get("sells", []):
			sales += int(x["revenue"])
		for x in est.get("buys", []):
			cost += int(x["cost"])
		if sales > 0 or cost > 0:
			text += "   sell %s · buy %s" % [Fmt.coins(sales), Fmt.coins(cost)]
		_stop_info[i].text = text

	var lines: PackedStringArray = []
	lines.append("Per trip: fees [b]%s[/b] · sales [b]%s[/b] · purchases [b]%s[/b]" % [
		Fmt.coins(_plan["fees"]), Fmt.coins(_plan["sales"]), Fmt.coins(_plan["purchases"])])
	var cash := int(_plan["cash"])
	var profit := int(_plan["profit"])
	lines.append("Cash effect [b][color=#%s]%s[/color][/b] · profit against what the goods cost [b][color=#%s]%s[/color][/b]" % [
		Style.hex(Style.GOOD if cash >= 0 else Style.BAD), Fmt.signed(cash),
		Style.hex(Style.GOOD if profit >= 0 else Style.BAD), Fmt.signed(profit)])
	if bool(_route["repeat"]):
		lines.append("[color=#%s]Repeats until you stop it; every loop reloads at home (keeping your reserves).[/color]" % muted)
	lines.append("[color=#%s]Estimates use today's prices; trades happen at the prices on arrival. Anything unsold comes home.[/color]" % muted)
	for w in _plan["warnings"]:
		lines.append("[color=#%s]⚠ %s[/color]" % [Style.hex(Style.WARN), w])
	for e in _plan["errors"]:
		lines.append("[color=#%s]✖ %s[/color]" % [Style.hex(Style.BAD), e])
	_summary.text = "\n".join(lines)
	get_ok_button().disabled = not _plan["errors"].is_empty()
	get_ok_button().text = "Start route" if bool(_route["repeat"]) else "Send"
	preview_changed.emit(_plan["full_path"], _vtype())
	if _make_signature(_plan) != _signature:
		_rebuild.call_deferred()


func _days_until(i: int) -> int:
	var total := 0
	var legs: Array = _plan["legs"]
	for k in mini(i + 1, legs.size()):
		total += int(legs[k]["days"])
	return total
