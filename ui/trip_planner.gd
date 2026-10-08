## The trip planner (DESIGN 2c-A): pick a vehicle and destination, what to sell there and what to buy.
## All checks and estimates come from the engine (Transport.plan); this dialog only collects choices.
extends ConfirmationDialog

signal submitted(vehicle_id: String, dest: String, sell: Dictionary, buy: Dictionary)
signal preview_changed(stops: Array, vtype: String)

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Simulation := preload("res://engine/simulation.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

var game: RefCounted
var _vehicle_opt: OptionButton
var _dest_opt: OptionButton
var _route: RichTextLabel
var _sell_title: Label
var _sell_grid: GridContainer
var _buy_title: Label
var _buy_grid: GridContainer
var _summary: RichTextLabel
var _sell_spins := {}
var _buy_spins := {}
var _sell_est := {}
var _buy_est := {}
var _building := false


func _ready() -> void:
	title = "Plan a trip"
	ok_button_text = "Send"
	min_size = Vector2i(640, 720)
	confirmed.connect(_on_confirmed)
	visibility_changed.connect(func():
		if not visible:
			preview_changed.emit([], ""))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var top := GridContainer.new()
	top.columns = 2
	top.add_theme_constant_override("h_separation", 10)
	root.add_child(top)
	top.add_child(Style.label("Vehicle"))
	_vehicle_opt = OptionButton.new()
	_vehicle_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vehicle_opt.item_selected.connect(func(_i): _on_vehicle_changed())
	top.add_child(_vehicle_opt)
	top.add_child(Style.label("Destination"))
	_dest_opt = OptionButton.new()
	_dest_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dest_opt.item_selected.connect(func(_i): _on_dest_changed())
	top.add_child(_dest_opt)

	_route = Style.rich()
	_route.custom_minimum_size.x = 600  # a known width keeps fit_content from sizing the dialog off screen
	root.add_child(_route)
	root.add_child(HSeparator.new())

	var cols := VBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	_sell_title = Style.heading("Sell there")
	left.add_child(_sell_title)
	var ls := ScrollContainer.new()
	ls.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(ls)
	_sell_grid = GridContainer.new()
	_sell_grid.columns = 4
	_sell_grid.add_theme_constant_override("h_separation", 10)
	ls.add_child(_sell_grid)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	_buy_title = Style.heading("Buy there and bring home")
	right.add_child(_buy_title)
	var rs := ScrollContainer.new()
	rs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(rs)
	_buy_grid = GridContainer.new()
	_buy_grid.columns = 4
	_buy_grid.add_theme_constant_override("h_separation", 10)
	rs.add_child(_buy_grid)

	root.add_child(HSeparator.new())
	_summary = Style.rich()
	_summary.custom_minimum_size.x = 600
	root.add_child(_summary)


## Opens the planner. Empty arguments are filled with sensible choices; a preset quantity of -1 means
## "as much as fits".
func open_for(g: RefCounted, vehicle_id := "", dest := "", sell_preset := {}, buy_preset := {}) -> bool:
	game = g
	var s: Dictionary = game.state
	var idle := Transport.idle_vehicles(s)
	if idle.is_empty():
		return false
	if vehicle_id == "" and dest != "":
		vehicle_id = _best_vehicle_for(idle, dest)
	if vehicle_id == "":
		vehicle_id = idle[0]["id"]
	_building = true
	_vehicle_opt.clear()
	for v in idle:
		_vehicle_opt.add_item("%s — carries %d lots by %s" % [v["name"], int(v["capacity"]), Transport.ROUTE_WORDS[Transport.route_of(v["type"])]])
		_vehicle_opt.set_item_metadata(_vehicle_opt.item_count - 1, v["id"])
		if v["id"] == vehicle_id:
			_vehicle_opt.select(_vehicle_opt.item_count - 1)
	_fill_destinations(dest)
	_building = false
	_rebuild_rows(sell_preset, buy_preset)
	# Open on the left so the map's mainland stays visible with the planned route on it.
	popup(Rect2i(Vector2i(8, 48), Vector2i(640, 720)))
	return true


func _best_vehicle_for(idle: Array, dest: String) -> String:
	var best := ""
	var best_days := 1 << 30
	for v in idle:
		var d := int(Transport.path_for(game.state, game.state["home_id"], dest, v["type"])["days"])
		if d > 0 and d < best_days:
			best = v["id"]
			best_days = d
	return best


func _vehicle_id() -> String:
	return "" if _vehicle_opt.selected < 0 else String(_vehicle_opt.get_item_metadata(_vehicle_opt.selected))


func _dest_id() -> String:
	return "" if _dest_opt.selected < 0 else String(_dest_opt.get_item_metadata(_dest_opt.selected))


func _fill_destinations(prefer: String) -> void:
	var s: Dictionary = game.state
	var v := Transport.vehicle(s, _vehicle_id())
	_dest_opt.clear()
	if v.is_empty():
		return
	for entry in Transport.reachable(s, s["home_id"], v["type"]):
		var c: Dictionary = s["cities"][entry["city"]]
		var text := "%s — %s" % [c["name"], Style.days(int(entry["days"]))]
		if entry["stops"].size() > 2:
			text += " (via other cities)"
		_dest_opt.add_item(text)
		_dest_opt.set_item_metadata(_dest_opt.item_count - 1, entry["city"])
		if entry["city"] == prefer:
			_dest_opt.select(_dest_opt.item_count - 1)
	if _dest_opt.item_count > 0 and _dest_opt.selected < 0:
		_dest_opt.select(0)


func _on_vehicle_changed() -> void:
	if _building:
		return
	var keep_sell := _current(_sell_spins)
	var keep_buy := _current(_buy_spins)
	var dest := _dest_id()
	_building = true
	_fill_destinations(dest)
	_building = false
	_rebuild_rows(keep_sell, keep_buy)


func _on_dest_changed() -> void:
	if _building:
		return
	_rebuild_rows(_current(_sell_spins), {})


func _current(spins: Dictionary) -> Dictionary:
	var out := {}
	for good in spins:
		var n := int(spins[good].value)
		if n > 0:
			out[good] = n
	return out


func _clear(grid: GridContainer) -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()


func _rebuild_rows(sell_preset: Dictionary, buy_preset: Dictionary) -> void:
	var s: Dictionary = game.state
	var v := Transport.vehicle(s, _vehicle_id())
	var dest := _dest_id()
	var cap := int(v["capacity"]) if not v.is_empty() else 0
	var wh: Dictionary = Economy.home(s)["warehouse"]
	_building = true
	_clear(_sell_grid)
	_clear(_buy_grid)
	_sell_spins.clear()
	_buy_spins.clear()
	_sell_est.clear()
	_buy_est.clear()

	var dest_name: String = s["cities"][dest]["name"] if dest != "" else "?"
	_sell_title.text = "Sell in %s (from your warehouse)" % dest_name
	_buy_title.text = "Buy in %s and bring home" % dest_name

	for h in ["Good", "You have", "Lots", "Est. revenue"]:
		_sell_grid.add_child(Style.label(h, Style.MUTED, 13))
	var any_stock := false
	var room := cap
	for good in Data.good_ids():
		var have := Economy.stock(wh, good)
		if have <= 0:
			continue
		any_stock = true
		_sell_grid.add_child(Style.label(good, Style.band_color(s["cities"][dest]["market"][good]["band"]) if dest != "" else Color.WHITE))
		_sell_grid.add_child(Style.right(Style.label(str(have))))
		var spin := _spin(mini(have, cap))
		var want := int(sell_preset.get(good, 0))
		if want < 0:
			want = mini(have, room)
		spin.value = clampi(want, 0, mini(have, cap))
		room -= int(spin.value)
		_sell_grid.add_child(spin)
		var est := Style.right(Style.label(""))
		est.custom_minimum_size.x = 150
		_sell_grid.add_child(est)
		_sell_spins[good] = spin
		_sell_est[good] = est
	if not any_stock:
		_sell_grid.add_child(Style.label("Nothing in the warehouse yet.", Style.MUTED))

	for h in ["Good", "Price now", "Lots", "Est. cost"]:
		_buy_grid.add_child(Style.label(h, Style.MUTED, 13))
	var any_sold := false
	for good in Data.good_ids():
		if dest == "" or not Market.city_sells(s, dest, good):
			continue
		any_sold = true
		_buy_grid.add_child(Style.label(good, Style.SURPLUS))
		_buy_grid.add_child(Style.right(Style.label(Fmt.coins(Market.listed_price(s, dest, good)))))
		var spin := _spin(cap)
		var want := int(buy_preset.get(good, 0))
		spin.value = cap if want < 0 else clampi(want, 0, cap)
		_buy_grid.add_child(spin)
		var est := Style.right(Style.label(""))
		est.custom_minimum_size.x = 110
		_buy_grid.add_child(est)
		_buy_spins[good] = spin
		_buy_est[good] = est
	if not any_sold:
		_buy_grid.add_child(Style.label("Nothing for sale here.", Style.MUTED))
	_building = false
	refresh_estimate()


func _spin(max_value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 0
	spin.max_value = maxi(0, max_value)
	spin.step = 1
	spin.rounded = true
	spin.custom_minimum_size.x = 90
	spin.value_changed.connect(func(_v): refresh_estimate())
	return spin


## Re-runs the engine's estimate; called on every change and periodically while the planner is open.
func refresh_estimate() -> void:
	if _building or game == null or not is_inside_tree():
		return
	var s: Dictionary = game.state
	var vid := _vehicle_id()
	var dest := _dest_id()
	var p: Dictionary = game.plan_trip(vid, dest, _current(_sell_spins), _current(_buy_spins))
	var v := Transport.vehicle(s, vid)

	for good in _sell_est:
		_sell_est[good].text = ""
	for line in p["sell_lines"]:
		if _sell_est.has(line["good"]):
			_sell_est[line["good"]].text = "%s (%s)" % [Fmt.coins(line["revenue"]), Fmt.signed(line["profit"])]
			_sell_est[line["good"]].tooltip_text = "Revenue, and profit against what the goods cost you"
	for good in _buy_est:
		_buy_est[good].text = ""
	for line in p["buy_lines"]:
		if _buy_est.has(line["good"]):
			_buy_est[line["good"]].text = Fmt.coins(line["cost"])

	var muted := Style.hex(Style.MUTED)
	if int(p["days"]) > 0 and not v.is_empty():
		var rt := Transport.route_of(v["type"])
		var stops: Array = p["stops"]
		var via := ""
		if stops.size() > 2:
			var names: PackedStringArray = []
			for i in range(1, stops.size() - 1):
				names.append(s["cities"][stops[i]]["name"])
			via = ", passing through " + ", ".join(names)
		_route.text = "[color=#%s]■[/color] By [b]%s[/b]%s · [b]%s[/b] each way\nArrives %s · back home %s" % [
			Style.hex(Style.ROUTE_COLORS[rt]), Transport.ROUTE_WORDS[rt], via, Style.days(int(p["days"])),
			Simulation.short_date(s, int(p["arrive_t"])), Simulation.short_date(s, int(p["home_t"]))]
		preview_changed.emit(stops, v["type"])
	else:
		_route.text = ""
		preview_changed.emit([], "")

	var lines: PackedStringArray = []
	lines.append("Cargo out [b]%d/%d[/b] lots · back [b]%d/%d[/b] lots" % [p["cargo_out"], p["capacity"], p["cargo_back"], p["capacity"]])
	lines.append("Sales %s  [color=#%s](%s against cost)[/color]   ·   Purchases %s" % [
		Fmt.coins(p["sell_total"]), muted, Fmt.signed(p["sell_profit"]), Fmt.coins(p["buy_total"])])
	lines.append("Trip fees %s  [color=#%s](%s now, %s on the way back)[/color]" % [
		Fmt.coins(int(p["fee_out"]) + int(p["fee_back"])), muted, Fmt.coins(p["fee_out"]), Fmt.coins(p["fee_back"])])
	var net := int(p["net"])
	lines.append("Cash effect [b][color=#%s]%s[/color][/b]" % [Style.hex(Style.GOOD if net >= 0 else Style.BAD), Fmt.signed(net)])
	lines.append("[color=#%s]Estimates use today's prices; the trade happens at the prices on arrival.[/color]" % muted)
	for w in p["warnings"]:
		lines.append("[color=#%s]⚠ %s[/color]" % [Style.hex(Style.WARN), w])
	for e in p["errors"]:
		lines.append("[color=#%s]✖ %s[/color]" % [Style.hex(Style.BAD), e])
	_summary.text = "\n".join(lines)
	get_ok_button().disabled = not p["errors"].is_empty()


func _on_confirmed() -> void:
	submitted.emit(_vehicle_id(), _dest_id(), _current(_sell_spins), _current(_buy_spins))
