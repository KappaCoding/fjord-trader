## The route editor (DESIGN 2c-F, 2c-G): load at home → stops with goods to sell and buy → back home.
## Run once, or repeat as a standing trade route. All checks and estimates come from the engine
## (Transport.plan_route, sale_options, add_sale via Game); this dialog only edits the route description.
## Editor-only flags stored in the route (the engine ignores them): stop.ui_market_open, stop.ui_sell_good
## (the good whose "where to sell" panel is open) and route.ui_sell_good (the same for loading at home).
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

const WIDTH := 960
const HEIGHT := 1000
const SALE_ROWS := 8

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
## One entry per stop: {info, net, cargo, money, sell_profit: {good: Label}}; keys are missing for a stop without a city.
var _stop_ui: Array = []
var _load_cargo: RichTextLabel
var _home_cargo: RichTextLabel


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
		var stop := {"city": st["city"], "sell_all": bool(st.get("sell_all", false)), "sell": {}, "buy": {}}
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
	stops.append({"city": pick, "sell_all": false, "sell": {}, "buy": {}})


# ------------------------------------------------------------------ building the form

func _on_vehicle_selected(index: int) -> void:
	if _building:
		return
	_vid = String(_vehicle_opt.get_item_metadata(index))
	_rebuild()


## What decides the form's layout: the stops, the goods on board at each, and the lots each open
## "where to sell" panel estimates for. When it changes, the form is rebuilt.
func _make_signature(p: Dictionary) -> String:
	var parts: PackedStringArray = [_vid, str(_route["stops"].size())]
	for est in p.get("stops", []):
		var goods: Array = []
		for g in est["onboard"]:
			if int(est["onboard"][g]) > 0:
				goods.append(g)
		goods.sort()
		parts.append(String(est["city"]) + ":" + ",".join(PackedStringArray(goods)))
	for open in _open_sale_panels():
		parts.append("sale%d:%s:%d" % [open[0], open[1], int(game.sale_load(_vid, _route, open[0], open[1])["lots"])])
	return "|".join(parts)


## [[after, good]] for every open "where to sell" panel (after = -1 for loading at home).
func _open_sale_panels() -> Array:
	var out: Array = []
	if String(_route.get("ui_sell_good", "")) != "":
		out.append([-1, String(_route["ui_sell_good"])])
	var stops: Array = _route["stops"]
	for i in stops.size():
		if String(stops[i].get("ui_sell_good", "")) != "":
			out.append([i, String(stops[i]["ui_sell_good"])])
	return out


func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()


func _rebuild() -> void:
	if game == null:
		return
	_building = true
	_clear(_body)
	_stop_ui.clear()
	_plan = game.plan_route(_vid, _route)
	_signature = _make_signature(_plan)
	_build_load_section()
	for i in _route["stops"].size():
		_build_stop(i)
	_home_cargo = Style.rich()
	_body.add_child(_home_cargo)
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
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.add_child(Style.heading("Load at %s" % home["name"]))
	vb.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	var open_good := String(_route.get("ui_sell_good", ""))
	var any := false
	for g in Data.good_ids():
		var avail := Economy.available_for_load(home, g)
		if avail <= 0 and not _route["load"].has(g):
			continue
		if not any:
			for h in ["Good", "Can load", "Lots"]:
				grid.add_child(Style.label(h, Style.MUTED, 13))
		any = true
		grid.add_child(_good_toggle(g, Color.WHITE, open_good == g,
			"Where can I sell %s? Shows what other cities pay and adds the sale to this route." % g,
			func(on: bool): _set_sale_panel(-1, g, on)))
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
		head.add_child(Style.label("Click a good to see where it sells", Style.MUTED, 13))
		vb.add_child(grid)
	else:
		vb.add_child(Style.label("Nothing in the warehouse to load (or it is all kept in reserve).", Style.MUTED))
	if open_good != "" and (Economy.available_for_load(home, open_good) > 0 or _route["load"].has(open_good)):
		vb.add_child(_sale_panel(-1, open_good))
	_load_cargo = Style.rich()
	vb.add_child(_load_cargo)
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


## A darker inset box (market view, "where to sell"); its VBoxContainer is child 0.
func _inset() -> PanelContainer:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.25)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	box.add_child(vb)
	return box


## A good's name as a small chip that opens (▾) or closes (▸) its "where to sell" panel.
func _good_toggle(g: String, color: Color, open: bool, tip: String, on_toggle: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.text = "%s %s" % [g, "▾" if open else "▸"]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.set_pressed_no_signal(open)
	for key in ["font_color", "font_pressed_color", "font_hover_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, color)
	b.add_theme_font_size_override("font_size", 14)
	for state_name in ["normal", "hover", "pressed", "hover_pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, {"normal": 0.05, "hover": 0.12, "pressed": 0.16, "hover_pressed": 0.2}[state_name])
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 1
		sb.content_margin_bottom = 1
		b.add_theme_stylebox_override(state_name, sb)
	b.toggled.connect(on_toggle)
	return b


## Opens or closes the "where to sell" panel for a good at a point of the route (-1 = loading at home).
func _set_sale_panel(after: int, good: String, on: bool) -> void:
	var holder: Dictionary = _route if after < 0 else _route["stops"][after]
	if on:
		holder["ui_sell_good"] = good
	else:
		holder.erase("ui_sell_good")
	_rebuild.call_deferred()


func _build_stop(i: int) -> void:
	var s: Dictionary = game.state
	var stops: Array = _route["stops"]
	var st: Dictionary = stops[i]
	var city_id := String(st["city"])
	var panel := _panel()
	var vb: VBoxContainer = panel.get_child(0)
	var ui := {}
	_stop_ui.append(ui)

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
		if st.has("ui_sell_good") and not Market.city_sells(s, st["city"], st["ui_sell_good"]):
			st.erase("ui_sell_good")
		_rebuild.call_deferred())
	head.add_child(city_opt)
	var info := Style.rich()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(info)
	ui["info"] = info
	var net := Style.right(Style.label("", Color.WHITE, 16))
	net.custom_minimum_size.x = 150
	net.mouse_filter = Control.MOUSE_FILTER_PASS
	net.tooltip_text = "What this stop earns you: what its sales fetch, less what those goods cost, less the fee for getting here."
	head.add_child(net)
	ui["net"] = net
	var market_btn := Button.new()
	market_btn.toggle_mode = true
	market_btn.set_pressed_no_signal(bool(st.get("ui_market_open", false)))
	market_btn.text = "Market ▾" if bool(st.get("ui_market_open", false)) else "Market ▸"
	market_btn.tooltip_text = "Show what this city wants and its prices for every good"
	market_btn.toggled.connect(func(on: bool):
		st["ui_market_open"] = on  # editor-only flag; the engine ignores it
		_rebuild.call_deferred())
	head.add_child(market_btn)
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

	var cargo_l := Style.rich()
	vb.add_child(cargo_l)
	ui["cargo"] = cargo_l
	var money_l := Style.rich()
	money_l.tooltip_text = "Goods' cost is what you paid for goods bought on the way, or for goods made at home their value (75% of the base price) — the cost they carry in your warehouse."
	vb.add_child(money_l)
	ui["money"] = money_l
	if bool(st.get("ui_market_open", false)):
		vb.add_child(_market_panel(city_id, _stop_estimate(i).get("onboard", {})))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 26)
	vb.add_child(cols)

	# Sell column
	var sell_box := VBoxContainer.new()
	sell_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(sell_box)
	var sell_head := HBoxContainer.new()
	sell_head.add_theme_constant_override("separation", 12)
	sell_head.add_child(Style.label("Sell here", Style.WANT))
	sell_box.add_child(sell_head)
	var est := _stop_estimate(i)
	var onboard: Dictionary = est.get("onboard", {})
	var has_cargo := false
	for g in onboard:
		if int(onboard[g]) > 0:
			has_cargo = true
	var sell_profit := {}
	ui["sell_profit"] = sell_profit
	if not has_cargo:
		# Nothing to sell here, so there is nothing to switch on: clear the setting rather than hide it.
		st["sell_all"] = false
		var why := "load goods at home or buy them at an earlier stop" if i == 0 else "everything was sold at an earlier stop"
		if i == 0 and _route["load"].is_empty():
			why = "load goods at home first"
		var empty_l := Style.label("Nothing on board when it arrives — %s." % why, Style.MUTED)
		empty_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_l.custom_minimum_size.x = 340
		sell_box.add_child(empty_l)
		var dead: PackedStringArray = []
		for g in Data.good_ids():
			if st["sell"].has(g):
				dead.append(g)
		if not dead.is_empty():
			var clear := Button.new()
			clear.text = "Clear orders to sell %s" % ", ".join(dead)
			clear.tooltip_text = "This stop still has orders to sell goods that won't be on board"
			clear.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			clear.pressed.connect(func():
				st["sell"] = {}
				_rebuild.call_deferred())
			sell_box.add_child(clear)
	else:
		var sell_all := bool(st.get("sell_all", false))
		var cb := CheckBox.new()
		cb.text = "Sell everything on board"
		cb.tooltip_text = "Sell every good the vehicle has on board when it arrives here. Minimum prices still apply."
		cb.set_pressed_no_signal(sell_all)
		if sell_all:
			cb.add_theme_color_override("font_color", Style.WANT)
			cb.add_theme_color_override("font_pressed_color", Style.WANT)
		cb.toggled.connect(func(on: bool):
			st["sell_all"] = on
			_rebuild.call_deferred())
		sell_head.add_child(cb)
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override("h_separation", 8)
		for h in ["Good", "On board", "Lots", "Min. price", "Profit"]:
			var hl := Style.label(h, Style.MUTED, 13)
			if h == "Profit":
				Style.right(hl)
				hl.tooltip_text = "What this good fetches here, less what it cost (today's prices)"
				hl.mouse_filter = Control.MOUSE_FILTER_PASS
			grid.add_child(hl)
		for g in Data.good_ids():
			var on_board := int(onboard.get(g, 0))
			var entry: Dictionary = st["sell"].get(g, {"lots": 0, "min": 0})
			if on_board <= 0 and (sell_all or int(entry["lots"]) == 0):
				continue
			var band: String = s["cities"][city_id]["market"][g]["band"]
			var name_l := Style.label(g, Style.band_color(band))
			name_l.tooltip_text = "%s pays %s for the first lot" % [s["cities"][city_id]["name"], Fmt.coins(Market.sell_lot_prices(s, city_id, g, 1)[0])]
			name_l.mouse_filter = Control.MOUSE_FILTER_PASS
			grid.add_child(name_l)
			grid.add_child(Style.right(Style.label(str(on_board))))
			var shown := on_board if (sell_all or int(entry["lots"]) < 0) else int(entry["lots"])
			var lots := _spin(999, shown, 1)
			if sell_all:
				lots.editable = false
				lots.tooltip_text = "Selling everything on board — untick the box above to choose amounts"
			else:
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
			var pl := Style.right(Style.label("—", Style.MUTED))
			pl.custom_minimum_size.x = 84
			pl.mouse_filter = Control.MOUSE_FILTER_PASS
			grid.add_child(pl)
			sell_profit[g] = pl
		sell_box.add_child(grid)

	# Buy column
	var buy_box := VBoxContainer.new()
	buy_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(buy_box)
	var buy_head := HBoxContainer.new()
	buy_head.add_theme_constant_override("separation", 12)
	buy_head.add_child(Style.label("Buy here", Style.SURPLUS))
	buy_box.add_child(buy_head)
	var sold_here: Array = []
	for g in Data.good_ids():
		if Market.city_sells(s, city_id, g):
			sold_here.append(g)
	var open_good := String(st.get("ui_sell_good", ""))
	if sold_here.is_empty():
		buy_box.add_child(Style.label("This city sells nothing.", Style.MUTED))
	else:
		buy_head.add_child(Style.label("Click a good to see where it sells", Style.MUTED, 13))
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 8)
		for h in ["Good", "Price now", "Lots", "Max. price"]:
			grid.add_child(Style.label(h, Style.MUTED, 13))
		for g in sold_here:
			grid.add_child(_good_toggle(g, Style.SURPLUS, open_good == g,
				"Where can I sell %s? Shows what other cities pay and adds the sale to this route." % g,
				func(on: bool): _set_sale_panel(i, g, on)))
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
	if open_good != "" and sold_here.has(open_good):
		vb.add_child(_sale_panel(i, open_good))
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
	spin.custom_minimum_size.x = 84 if step == 1 else 116
	spin.value = clampi(value, 0, maxi(value, max_value))
	return spin


# ------------------------------------------------------------------ estimate

func refresh_estimate() -> void:
	_recalc()


func _signed_color(n: int) -> Color:
	return Style.GOOD if n > 0 else (Style.BAD if n < 0 else Style.MUTED)


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

	var cap := int(_plan["capacity"])
	var nets := 0
	for i in _stop_ui.size():
		var ui: Dictionary = _stop_ui[i]
		var est := _stop_estimate(i)
		var info: RichTextLabel = ui["info"]
		var net_l: Label = ui["net"]
		info.text = ""
		net_l.text = ""
		if est.is_empty():
			continue
		if i < legs.size() and legs[i]["to"] == est["city"]:
			info.text = "[color=#%s]%s away · arrives ~%s[/color]" % [
				muted, Style.days(int(legs[i]["days"])), Simulation.short_date(s, int(s["time_hours"]) + _days_until(i) * 24)]
		var net := int(est["profit"])
		nets += net
		net_l.text = "Net %s" % Fmt.signed(net)
		net_l.add_theme_color_override("font_color", _signed_color(net))
		if ui.has("cargo"):
			ui["cargo"].text = "[b]Arrives with:[/b] %s   →   [b]leaves with:[/b] %s" % [
				_cargo_text(est.get("onboard", {}), cap), _cargo_text(est.get("onboard_after", {}), cap)]
		if ui.has("money"):
			ui["money"].text = _money_text(est)
		if ui.has("sell_profit"):
			var by_good := {}
			for x in est.get("sells", []):
				by_good[x["good"]] = x
			for g in ui["sell_profit"]:
				var pl: Label = ui["sell_profit"][g]
				if by_good.has(g) and int(by_good[g]["lots"]) > 0:
					var x: Dictionary = by_good[g]
					pl.text = Fmt.signed(int(x["profit"]))
					pl.add_theme_color_override("font_color", _signed_color(int(x["profit"])))
					pl.tooltip_text = "Sells %d lots for %s; they cost %s" % [int(x["lots"]), Fmt.coins(x["revenue"]), Fmt.coins(x["cost"])]
				else:
					pl.text = "—"
					pl.add_theme_color_override("font_color", Style.MUTED)
					pl.tooltip_text = "Nothing of this sells here at today's prices"

	var home_name: String = Economy.home(s)["name"]
	if _load_cargo != null:
		_load_cargo.text = "[b]Leaves %s with:[/b] %s" % [home_name, _cargo_text(_plan.get("load_cargo", {}), cap)]
	var return_fee := int(_plan.get("return_fee", 0))
	if _home_cargo != null:
		var back: Dictionary = _plan.get("home_cargo", {})
		_home_cargo.text = "[b]Back at %s with:[/b] %s%s   [color=#%s]·  fee for the way home %s[/color]" % [
			home_name, _cargo_text(back, cap),
			"  [color=#%s](unloaded into the warehouse at what it cost)[/color]" % muted if not back.is_empty() else "",
			Style.hex(Style.BAD) if return_fee > 0 else muted, Fmt.signed(-return_fee)]

	var lines: PackedStringArray = []
	var profit := int(_plan["profit"])
	var cash := int(_plan["cash"])
	lines.append("Profit per trip [b][color=#%s]%s[/color][/b] [color=#%s]= stops' nets %s − way home %s[/color]   ·   Cash effect [b][color=#%s]%s[/color][/b]" % [
		Style.hex(_signed_color(profit)), Fmt.signed(profit), muted, Fmt.signed(nets), Fmt.coins(return_fee),
		Style.hex(_signed_color(cash)), Fmt.signed(cash)])
	lines.append("[color=#%s]Sales %s · purchases %s · fees %s. Goods bought on the way count where they're sold; anything unsold comes home at what it cost.[/color]" % [
		muted, Fmt.coins(_plan["sales"]), Fmt.coins(_plan["purchases"]), Fmt.coins(_plan["fees"])])
	if bool(_route["repeat"]):
		lines.append("[color=#%s]Repeats until you stop it; every loop reloads at home (keeping your reserves).[/color]" % muted)
	lines.append("[color=#%s]Estimates use today's prices; trades happen at the prices on arrival.[/color]" % muted)
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


## "Sold for 45,000 − goods' cost 30,000 − fee 1,000 = net +14,000 · bought for 20,000 …"
func _money_text(est: Dictionary) -> String:
	var muted := Style.hex(Style.MUTED)
	var sales := int(est["sales"])
	var net := int(est["profit"])
	var text := ""
	if sales > 0:
		text = "Sold for [b]%s[/b] − goods' cost %s − fee %s = " % [Fmt.coins(sales), Fmt.coins(est["sold_cost"]), Fmt.coins(est["fee"])]
	else:
		text = "[color=#%s]Sells nothing[/color] − fee %s = " % [muted, Fmt.coins(est["fee"])]
	text += "[b][color=#%s]net %s[/color][/b]" % [Style.hex(_signed_color(net)), Fmt.signed(net)]
	if int(est["purchases"]) > 0:
		text += "   [color=#%s]Buys for %s — that counts at the stop where it's sold.[/color]" % [muted, Fmt.coins(est["purchases"])]
	return text


func _days_until(i: int) -> int:
	var total := 0
	var legs: Array = _plan["legs"]
	for k in mini(i + 1, legs.size()):
		total += int(legs[k]["days"])
	return total


## {"Wool": 6, "Grain": 4} -> "6 Wool, 4 Grain (10/10 lots)"; empty -> "nothing"
func _cargo_text(cargo: Dictionary, cap: int) -> String:
	var parts: PackedStringArray = []
	var total := 0
	for g in Data.good_ids():
		if int(cargo.get(g, 0)) > 0:
			parts.append("%d %s" % [int(cargo[g]), g])
			total += int(cargo[g])
	if parts.is_empty():
		return "[color=#%s]nothing[/color]" % Style.hex(Style.MUTED)
	var col := Style.WARN if total >= cap else Style.MUTED
	return "%s [color=#%s](%d/%d lots)[/color]" % [", ".join(parts), Style.hex(col), total, cap]


# ------------------------------------------------------------------ where to sell (2c-G)

## Every city this vehicle can take `good` to from this point of the route, best estimated gain first,
## with a button that adds the sale as the next stop.
func _sale_panel(after: int, good: String) -> Control:
	var s: Dictionary = game.state
	var muted := Style.hex(Style.MUTED)
	var opts: Dictionary = game.sale_options(_vid, _route, after, good)
	var box := _inset()
	var vb: VBoxContainer = box.get_child(0)
	var head := Style.rich()
	head.custom_minimum_size.x = WIDTH - 90
	vb.add_child(head)
	if String(opts["error"]) != "":
		head.text = "[color=#%s]%s[/color]" % [Style.hex(Style.BAD), opts["error"]]
		return box
	var here: String = opts["here"]
	var lots := int(opts["lots"])
	var unit := int(opts["unit_cost"])
	var vlabel := String(Transport.vehicle(s, _vid)["name"])
	var source := ("loaded at %s — it cost you about %s a lot" % [s["cities"][here]["name"], Fmt.coins(unit)]) if after < 0 \
		else ("bought in %s — %s for the first lot" % [s["cities"][here]["name"], Fmt.coins(unit)])
	var now_days := maxi(1, int(opts["now_days"]))
	var now_per_day := int(opts["now_profit"]) / now_days
	var basis := "For [b]%d lots[/b] at today's prices (each lot moves the price), with the sale as the next stop. Best first: what the whole route makes per day — now [b]%s a day[/b] over %s." % [
		lots, Fmt.signed(now_per_day), Style.days(int(opts["now_days"]))]
	if lots == 0:
		basis = "[color=#%s]No room on board here (or nothing to load), so only the price per lot is shown.[/color]" % Style.hex(Style.WARN)
	head.text = "[b]Where to sell %s[/b] [color=#%s]%s[/color]\n[color=#%s]%s[/color]" % [good, muted, source, muted, basis]

	var options: Array = opts["options"]
	if options.is_empty():
		vb.add_child(Style.label("No other city %s can reach from here buys it." % vlabel, Style.MUTED))
		return box
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	var heads := ["City", "Pays you", "Per lot", "Detour", "Profit change", "Per day", ""]
	var tips := ["", "What the city pays for the first lot", "What it pays less what a lot costs here",
		"Days this sale adds to the trip",
		"How the route's profit per trip changes with this sale. It can fall even where the price is good: selling all of it there means it no longer sells where the route sells it now.",
		"The whole route's profit per day of travel with this sale added (now %s)" % Fmt.signed(now_per_day), ""]
	if lots == 0:
		heads[4] = ""
		heads[5] = ""
	for k in heads.size():
		var hl := Style.label(heads[k], Style.MUTED, 12)
		if k >= 1 and k <= 5:
			Style.right(hl)
		hl.tooltip_text = tips[k]
		hl.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(hl)
	var next_stop := after + 2  # 1-based number of the stop after this one
	var stops: Array = _route["stops"]
	var taken := int(_route["load"].get(good, 0)) if after < 0 else int(stops[after]["buy"].get(good, {}).get("lots", 0))
	var next_sells_all := false
	if after + 1 < stops.size():
		var nst: Dictionary = stops[after + 1]
		next_sells_all = bool(nst.get("sell_all", false)) or int(nst["sell"].get(good, {}).get("lots", 0)) < 0
	for o in options.slice(0, SALE_ROWS):
		var c: Dictionary = s["cities"][o["city"]]
		var band: String = o["band"]
		var name_l := Style.label(c["name"] + ("  · wants it" if band == "want" else ""), Style.band_color(band), 14)
		name_l.custom_minimum_size.x = 210
		name_l.tooltip_text = "%s · %s from %s" % [Style.band_label(band), Style.days(int(o["days_from"])), s["cities"][here]["name"]]
		name_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(name_l)
		grid.add_child(Style.right(Style.label(Fmt.coins(o["price"]), Color.WHITE, 14)))
		var margin := int(o["margin"])
		grid.add_child(Style.right(Style.label(Fmt.signed(margin), _signed_color(margin), 14)))
		var det_l: Label
		if bool(o["merge"]):
			det_l = Style.label("next stop", Style.MUTED, 13)
			det_l.tooltip_text = "Already the next stop — no extra travel"
		else:
			det_l = Style.label("+%s" % Style.days(int(o["extra_days"])) if int(o["extra_days"]) >= 0 else Style.days(int(o["extra_days"])), Color.WHITE, 14)
			det_l.tooltip_text = "%s from here; adds %s to the trip and %s in fees" % [
				Style.days(int(o["days_from"])), Style.days(int(o["extra_days"])), Fmt.coins(o["extra_fee"])]
		Style.right(det_l)
		det_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(det_l)
		var gain := int(o["gain"])
		var gain_l := Style.right(Style.label(Fmt.signed(gain) if lots > 0 else "", _signed_color(gain), 14))
		gain_l.tooltip_text = "%d lots fetch %s there; the route then makes %s per trip over %s" % [
			lots, Fmt.coins(o["revenue"]), Fmt.signed(int(o["route_profit"])), Style.days(int(o["route_days"]))]
		gain_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(gain_l)
		var per_day := int(o["per_day"])
		var pd_col := Style.GOOD if per_day > now_per_day else (Style.MUTED if per_day == now_per_day else Style.WARN)
		var pd_l := Style.right(Style.label(Fmt.signed(per_day) if lots > 0 else "", pd_col, 14))
		pd_l.tooltip_text = ("Better than the route makes now (%s a day)" if per_day > now_per_day \
			else "Not better than the route makes now (%s a day)") % Fmt.signed(now_per_day)
		pd_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(pd_l)
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		btn.text = ("Sell at stop %d" % next_stop) if bool(o["merge"]) else ("Sell there next" if after >= 0 else "Sell there first")
		btn.disabled = lots <= 0
		if bool(o["merge"]) and next_sells_all and taken == lots:
			btn.text = "Already planned"
			btn.disabled = true
			btn.tooltip_text = "This route already takes %d %s here and sells all of it at stop %d" % [lots, good, next_stop]
		elif lots <= 0:
			btn.tooltip_text = "No room on board" if after >= 0 else "Nothing to load"
		elif after < 0:
			btn.tooltip_text = "Load %d %s at home and sell all of it in %s" % [lots, good, c["name"]] + ("" if bool(o["merge"]) else ", as a new first stop")
		else:
			btn.tooltip_text = "Buy %d %s here and sell all of it in %s" % [lots, good, c["name"]] + ("" if bool(o["merge"]) else ", as a new stop %d" % next_stop)
		btn.pressed.connect(_apply_sale.bind(after, good, String(o["city"]), lots))
		grid.add_child(btn)
	vb.add_child(grid)
	var foot: PackedStringArray = []
	if options.size() > SALE_ROWS:
		foot.append("Best %d of %d cities." % [SALE_ROWS, options.size()])
	if int(opts["unreachable"]) > 0:
		foot.append("%d more %s %s can't reach from here." % [int(opts["unreachable"]), "city" if int(opts["unreachable"]) == 1 else "cities", vlabel])
	foot.append("The new stop's net shows above once it's added.")
	vb.add_child(Style.label(" ".join(foot), Style.MUTED, 12))
	return box


func _apply_sale(after: int, good: String, city: String, lots: int) -> void:
	var r: Dictionary = game.add_sale(_route, after, good, city, lots)
	var holder: Dictionary = r if after < 0 else r["stops"][after]
	holder.erase("ui_sell_good")
	_route = r
	_rebuild.call_deferred()


## The expandable market view of a stop: wants, what the city produces, and today's prices for every good.
## Wanted goods come first, then goods on board, then what the city sells, then the rest.
func _market_panel(city_id: String, onboard: Dictionary) -> Control:
	var s: Dictionary = game.state
	var c: Dictionary = s["cities"][city_id]
	var muted := Style.hex(Style.MUTED)
	var box := _inset()
	var vb: VBoxContainer = box.get_child(0)

	var head := Style.rich()
	head.custom_minimum_size.x = WIDTH - 90
	var days_left := ceili(float(c["want_timer_hours"]) / 24.0)
	head.text = "[b]%s[/b] [color=#%s]· population %s[/color]\nWants [color=#%s][b]%s[/b][/color] [color=#%s](pays a premium; changes in %s)[/color] · Produces [color=#%s]%s[/color]" % [
		c["name"], muted, Fmt.coins(int(c["pop"])),
		Style.hex(Style.WANT), ", ".join(PackedStringArray(c["wants"])), muted, Style.days(days_left),
		Style.hex(Style.SURPLUS), ", ".join(PackedStringArray(c["produces"]))]
	vb.add_child(head)

	var order: Array = []
	for g in c["wants"]:
		order.append(g)
	for g in Data.good_ids():
		if int(onboard.get(g, 0)) > 0 and not order.has(g):
			order.append(g)
	for g in Data.good_ids():
		if c["produces"].has(g) and not order.has(g):
			order.append(g)
	for g in Data.good_ids():
		if not order.has(g):
			order.append(g)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	vb.add_child(cols)
	var half := int(ceil(order.size() / 2.0))
	for part in [order.slice(0, half), order.slice(half)]:
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 1)
		for h in ["Good", "Pays you", "vs base", "Sells to you"]:
			var hl := Style.label(h, Style.MUTED, 12)
			if h != "Good":
				Style.right(hl)
			grid.add_child(hl)
		for g in part:
			var band: String = c["market"][g]["band"]
			var col := Style.band_color(band)
			var name_text: String = g
			if int(onboard.get(g, 0)) > 0:
				name_text += "  (%d on board)" % int(onboard[g])
			var nl := Style.label(name_text, col, 13)
			nl.custom_minimum_size.x = 150
			nl.tooltip_text = Style.band_label(band)
			grid.add_child(nl)
			var pays := int(Market.sell_lot_prices(s, city_id, g, 1)[0])
			grid.add_child(Style.right(Style.label(Fmt.coins(pays), col, 13)))
			var listed := Market.listed_price(s, city_id, g)
			var pct := (float(listed) / float(Data.base_price(g)) - 1.0) * 100.0
			grid.add_child(Style.right(Style.label("%+.0f%%" % pct, Style.WANT if pct >= 0.0 else Style.SURPLUS, 12)))
			var sells := Market.city_sells(s, city_id, g)
			grid.add_child(Style.right(Style.label(Fmt.coins(listed) if sells else "—", Color.WHITE if sells else Style.MUTED, 13)))
		cols.add_child(grid)
	var note := Style.label("Today's prices. They drift a little before you arrive, and each lot you trade moves them.", Style.MUTED, 12)
	vb.add_child(note)
	return box
