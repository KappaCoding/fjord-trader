## Left-hand panel: your settlement's production lines, warehouse and fleet.
extends VBoxContainer

signal change_line(index: int)
signal sell_home(good: String)
signal plan_with_vehicle(vehicle_id: String)
signal buy_vehicle(vtype: String)
signal show_prices(good: String)

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Simulation := preload("res://engine/simulation.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

var game: RefCounted
var _title: RichTextLabel
var _lines_box: VBoxContainer
var _stock_box: VBoxContainer
var _fleet_box: VBoxContainer
var _buy_box: HFlowContainer
var _signature := ""
var _line_widgets: Array = []
var _stock_widgets := {}
var _fleet_widgets := {}
var _buy_buttons := {}


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_title = Style.rich()
	add_child(_title)

	add_child(Style.heading("Production"))
	_lines_box = VBoxContainer.new()
	add_child(_lines_box)
	add_child(HSeparator.new())

	add_child(Style.heading("Warehouse"))
	_stock_box = VBoxContainer.new()
	add_child(_stock_box)
	add_child(HSeparator.new())

	add_child(Style.heading("Fleet"))
	_fleet_box = VBoxContainer.new()
	_fleet_box.add_theme_constant_override("separation", 6)
	add_child(_fleet_box)
	_buy_box = HFlowContainer.new()
	add_child(_buy_box)


func set_game(g: RefCounted) -> void:
	game = g
	_signature = ""
	refresh()


func _make_signature() -> String:
	var s: Dictionary = game.state
	var parts: PackedStringArray = []
	parts.append(str(Economy.home(s)["lines"].size()))
	var wh: Dictionary = Economy.home(s)["warehouse"]
	for good in Data.good_ids():
		if wh.has(good):
			parts.append(good)
	parts.append("|")
	for v in s["vehicles"]:
		parts.append(v["id"])
	return ",".join(parts)


func refresh() -> void:
	if game == null:
		return
	var sig := _make_signature()
	if sig != _signature:
		_signature = sig
		_rebuild()
	_update()


# ------------------------------------------------------------------ build

func _clear(box: Container) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()


func _rebuild() -> void:
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)

	_clear(_lines_box)
	_line_widgets.clear()
	for i in home["lines"].size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var info := Style.rich()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var btn := Button.new()
		btn.pressed.connect(func(): change_line.emit(i))
		row.add_child(btn)
		_lines_box.add_child(row)
		_line_widgets.append({"info": info, "button": btn})

	_clear(_stock_box)
	_stock_widgets.clear()
	var wh: Dictionary = home["warehouse"]
	if wh.is_empty():
		_stock_box.add_child(_wrap_label("Empty. Each production line adds one lot every 3 days.", Style.MUTED))
	else:
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override("h_separation", 10)
		for h in ["Good", "Lots", "Avg cost", "Home pays", ""]:
			var l := Style.label(h, Style.MUTED, 13)
			if h in ["Lots", "Avg cost", "Home pays"]:
				Style.right(l)
			grid.add_child(l)
		for good in Data.good_ids():
			if not wh.has(good):
				continue
			var name_btn := LinkButton.new()
			name_btn.text = good
			name_btn.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
			name_btn.tooltip_text = "Show where %s sells best on the map" % good
			name_btn.pressed.connect(func(): show_prices.emit(good))
			grid.add_child(name_btn)
			var lots := Style.right(Style.label(""))
			lots.custom_minimum_size.x = 36
			grid.add_child(lots)
			var avg := Style.right(Style.label(""))
			avg.custom_minimum_size.x = 70
			grid.add_child(avg)
			var pays := Style.right(Style.label(""))
			pays.custom_minimum_size.x = 70
			grid.add_child(pays)
			var sell := Button.new()
			sell.text = "Sell here"
			sell.tooltip_text = "Sell %s to your home market now (75%% of normal prices)" % good
			sell.pressed.connect(func(): sell_home.emit(good))
			grid.add_child(sell)
			_stock_widgets[good] = {"lots": lots, "avg": avg, "pays": pays}
		_stock_box.add_child(grid)

	_clear(_fleet_box)
	_fleet_widgets.clear()
	for v in s["vehicles"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var info := Style.rich()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var btn := Button.new()
		btn.text = "Plan trip"
		var vid: String = v["id"]
		btn.pressed.connect(func(): plan_with_vehicle.emit(vid))
		row.add_child(btn)
		_fleet_box.add_child(row)
		_fleet_widgets[vid] = {"info": info, "button": btn}

	_clear(_buy_box)
	_buy_buttons.clear()
	for vtype in ["wagon", "barge", "coastal", "ocean"]:
		var b := Button.new()
		var info := Transport.type_info(vtype)
		b.text = "Buy %s (%s)" % [String(info["label"]).to_lower(), Fmt.coins(int(info["price"]))]
		b.pressed.connect(func(): buy_vehicle.emit(vtype))
		_buy_box.add_child(b)
		_buy_buttons[vtype] = b


func _wrap_label(text: String, col: Color) -> Label:
	var l := Style.label(text, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# ------------------------------------------------------------------ update

func _update() -> void:
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)
	var stage := Economy.stage_info(int(home["stage"]))
	_title.text = "[font_size=19][b]%s[/b][/font_size]\n[color=#%s]Stage %d %s · population %s · %d of %d lines[/color]" % [
		home["name"], Style.hex(Style.MUTED), int(home["stage"]), stage["name"], Fmt.coins(int(home["pop"])),
		home["lines"].size(), int(stage["max_lines"])]

	var t := int(s["time_hours"])
	for i in _line_widgets.size():
		var line: Dictionary = home["lines"][i]
		var w: Dictionary = _line_widgets[i]
		var good := String(line["good"])
		var text := ""
		if String(line["retool_to"]) != "":
			var left := ceili(float(int(line["retool_until"]) - t) / 24.0)
			text = "Line %d  [color=#%s]%s → %s[/color]\n[color=#%s]Retooling, %s left[/color]" % [
				i + 1, Style.hex(Style.SURPLUS), good, line["retool_to"], Style.hex(Style.WARN), Style.days(left)]
			w["button"].text = "Change"
			w["button"].disabled = true
		elif good == "":
			text = "Line %d  [color=#%s]not producing[/color]\n[color=#%s]Choose a good to start (free)[/color]" % [
				i + 1, Style.hex(Style.BAD), Style.hex(Style.MUTED)]
			w["button"].text = "Choose"
			w["button"].disabled = false
		else:
			var hours := Economy.hours_to_next_lot(line)
			var next := "next lot in %s" % Style.days(ceili(float(hours) / 24.0)) if hours > 24 else "next lot today"
			text = "Line %d  [color=#%s][b]%s[/b][/color]\n[color=#%s]%d lots/month · %s[/color]" % [
				i + 1, Style.hex(Style.SURPLUS), good, Style.hex(Style.MUTED), int(line["output"]), next]
			w["button"].text = "Change"
			w["button"].disabled = false
		w["info"].text = text

	var wh: Dictionary = home["warehouse"]
	for good in _stock_widgets:
		var w: Dictionary = _stock_widgets[good]
		w["lots"].text = str(Economy.stock(wh, good))
		w["avg"].text = Fmt.coins(Economy.avg_cost(wh, good))
		w["pays"].text = Fmt.coins(Market.sell_lot_prices(s, s["home_id"], good, 1)[0])

	for v in s["vehicles"]:
		var w: Dictionary = _fleet_widgets[v["id"]]
		w["info"].text = _vehicle_text(v)
		w["button"].disabled = not Transport.is_idle_at_home(s, v)

	for vtype in _buy_buttons:
		var b: Button = _buy_buttons[vtype]
		var info := Transport.type_info(vtype)
		var allowed := Transport.can_buy_type(s, vtype)
		b.visible = allowed or int(info["min_stage"]) <= int(home["stage"]) + 1
		b.disabled = not allowed or int(s["treasury"]) < int(info["price"])
		if not allowed:
			b.tooltip_text = "Available at Stage %d" % int(info["min_stage"])
		else:
			b.tooltip_text = "Carries %d lots by %s. Upkeep %s/month." % [
				int(info["capacity"]), Transport.ROUTE_WORDS[info["route"]],
				Fmt.coins(int(round(int(info["price"]) * float(Data.balance()["vehicles"]["upkeep_share_per_month"]))))]


func _vehicle_text(v: Dictionary) -> String:
	var s: Dictionary = game.state
	var col := Style.hex(Style.VEHICLE_COLORS[v["type"]])
	var head := "[color=#%s][b]%s[/b][/color] [color=#%s](%d lots, %s)[/color]" % [
		col, v["name"], Style.hex(Style.MUTED), int(v["capacity"]), Transport.ROUTE_WORDS[Transport.route_of(v["type"])]]
	var trip: Dictionary = v["trip"]
	var cargo := _cargo_text(v["cargo"])
	if trip.is_empty():
		return head + "\n[color=#%s]At home, ready[/color]" % Style.hex(Style.GOOD)
	var dest_name: String = s["cities"][trip["dest"]]["name"]
	var when := Simulation.short_date(s, int(trip["leg_end"]))
	if trip["phase"] == "out":
		return head + "\n→ %s, arrives %s · %s" % [dest_name, when, cargo]
	return head + "\n← home from %s, arrives %s · %s" % [dest_name, when, cargo]


func _cargo_text(cargo: Dictionary) -> String:
	if cargo.is_empty():
		return "empty"
	var parts: PackedStringArray = []
	for good in Data.good_ids():
		if cargo.has(good):
			parts.append("%d %s" % [int(cargo[good]["lots"]), good])
	return ", ".join(parts)
