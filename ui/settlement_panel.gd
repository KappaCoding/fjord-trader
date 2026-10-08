## Left-hand panel: your settlement — growth, infrastructure, production lines, warehouse and fleet.
extends VBoxContainer

signal change_line(index: int)
signal add_line
signal show_goods
signal upgrade_line(index: int)
signal move_line(index: int, delta: int)
signal build(kind: String)
signal set_reserve(good: String, lots: int)
signal sell_home(good: String)
signal plan_with_vehicle(vehicle_id: String)
signal stop_route(vehicle_id: String, on: bool)
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
var _stage_bar: ProgressBar
var _growth: RichTextLabel
var _infra_box: VBoxContainer
var _lines_box: VBoxContainer
var _stock_box: VBoxContainer
var _fleet_box: VBoxContainer
var _buy_box: HFlowContainer
var _signature := ""
var _infra_widgets := {}
var _line_widgets: Array = []
var _stock_widgets := {}
var _fleet_widgets := {}
var _buy_buttons := {}
var _slot_label: RichTextLabel
var _add_line_btn: Button


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_title = Style.rich()
	add_child(_title)
	_stage_bar = ProgressBar.new()
	_stage_bar.show_percentage = false
	_stage_bar.custom_minimum_size.y = 8
	add_child(_stage_bar)
	_growth = Style.rich()
	add_child(_growth)
	add_child(HSeparator.new())

	var infra_head := Style.heading("Infrastructure")
	infra_head.text = "Infrastructure"
	infra_head.tooltip_text = "One of each per stage. Housing, harbor and roads also add +0.5% growth each."
	add_child(infra_head)
	var infra_note := Style.label("One of each per stage · housing, harbor and roads each add +0.5% growth", Style.MUTED, 12)
	add_child(infra_note)
	_infra_box = VBoxContainer.new()
	add_child(_infra_box)
	add_child(HSeparator.new())

	var prod_head := HBoxContainer.new()
	prod_head.add_child(Style.heading("Production"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prod_head.add_child(spacer)
	var goods_btn := Button.new()
	goods_btn.text = "What can I make?"
	goods_btn.tooltip_text = "Every good, whether you can make it, and why not"
	goods_btn.pressed.connect(func(): show_goods.emit())
	prod_head.add_child(goods_btn)
	add_child(prod_head)
	_lines_box = VBoxContainer.new()
	_lines_box.add_theme_constant_override("separation", 8)
	add_child(_lines_box)
	var slot_row := HBoxContainer.new()
	_slot_label = Style.rich()
	_slot_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot_row.add_child(_slot_label)
	_add_line_btn = Button.new()
	_add_line_btn.text = "Add line"
	_add_line_btn.pressed.connect(func(): add_line.emit())
	slot_row.add_child(_add_line_btn)
	add_child(slot_row)
	add_child(HSeparator.new())

	add_child(Style.heading("Warehouse"))
	_stock_box = VBoxContainer.new()
	add_child(_stock_box)
	add_child(HSeparator.new())

	add_child(Style.heading("Fleet"))
	_fleet_box = VBoxContainer.new()
	_fleet_box.add_theme_constant_override("separation", 8)
	add_child(_fleet_box)
	_buy_box = HFlowContainer.new()
	add_child(_buy_box)


func set_game(g: RefCounted) -> void:
	game = g
	_signature = ""
	refresh()


func _make_signature() -> String:
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)
	var parts: PackedStringArray = [str(home["stage"]), str(home["lines"].size())]
	for good in Data.good_ids():
		if home["warehouse"].has(good):
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

	_clear(_infra_box)
	_infra_widgets.clear()
	var ig := GridContainer.new()
	ig.columns = 3
	ig.add_theme_constant_override("h_separation", 10)
	for kind in Data.balance()["infrastructure"]["order"]:
		var info: Dictionary = Data.balance()["infrastructure"]["types"][kind]
		var name_l := Style.label("")
		name_l.tooltip_text = info["effect"]
		name_l.custom_minimum_size.x = 110
		ig.add_child(name_l)
		var effect := Style.label(info["effect"], Style.MUTED, 12)
		effect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		effect.clip_text = true
		effect.tooltip_text = info["effect"]
		ig.add_child(effect)
		var btn := Button.new()
		btn.custom_minimum_size.x = 150
		btn.pressed.connect(func(): build.emit(kind))
		ig.add_child(btn)
		_infra_widgets[kind] = {"name": name_l, "button": btn}
	_infra_box.add_child(ig)

	_clear(_lines_box)
	_line_widgets.clear()
	for i in home["lines"].size():
		var box := VBoxContainer.new()
		var info := Style.rich()
		box.add_child(info)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var up := Button.new()
		up.text = "▲"
		up.tooltip_text = "Higher priority: gets shared inputs first"
		up.disabled = i == 0
		up.pressed.connect(func(): move_line.emit(i, -1))
		row.add_child(up)
		var down := Button.new()
		down.text = "▼"
		down.tooltip_text = "Lower priority"
		down.disabled = i == home["lines"].size() - 1
		down.pressed.connect(func(): move_line.emit(i, 1))
		row.add_child(down)
		var change := Button.new()
		change.pressed.connect(func(): change_line.emit(i))
		row.add_child(change)
		var upg := Button.new()
		upg.pressed.connect(func(): upgrade_line.emit(i))
		row.add_child(upg)
		box.add_child(row)
		_lines_box.add_child(box)
		_line_widgets.append({"info": info, "change": change, "upgrade": upg})

	_clear(_stock_box)
	_stock_widgets.clear()
	var wh: Dictionary = home["warehouse"]
	if wh.is_empty():
		_stock_box.add_child(_wrap_label("Empty. Each production line adds one lot every 3 days.", Style.MUTED))
	else:
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override("h_separation", 10)
		for h in ["Good", "Lots", "Avg cost", "Keep", ""]:
			var l := Style.label(h, Style.MUTED, 13)
			if h in ["Lots", "Avg cost"]:
				Style.right(l)
			if h == "Keep":
				l.tooltip_text = "Reserve: routes never load these lots (production and food still use them)"
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
			lots.custom_minimum_size.x = 40
			grid.add_child(lots)
			var avg := Style.right(Style.label(""))
			avg.custom_minimum_size.x = 80
			grid.add_child(avg)
			var keep := SpinBox.new()
			keep.min_value = 0
			keep.max_value = 9999
			keep.step = 1
			keep.rounded = true
			keep.value = Economy.reserve(home, good)
			keep.custom_minimum_size.x = 90
			keep.tooltip_text = "Reserve: routes never load these lots"
			keep.value_changed.connect(func(v: float): set_reserve.emit(good, int(v)))
			grid.add_child(keep)
			var sell := Button.new()
			sell.text = "Sell here"
			sell.tooltip_text = "Sell %s to your home market now (75%% of normal prices)" % good
			sell.pressed.connect(func(): sell_home.emit(good))
			grid.add_child(sell)
			_stock_widgets[good] = {"lots": lots, "avg": avg}
		_stock_box.add_child(grid)

	_clear(_fleet_box)
	_fleet_widgets.clear()
	for v in s["vehicles"]:
		var box := VBoxContainer.new()
		var info := Style.rich()
		box.add_child(info)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var vid: String = v["id"]
		var plan := Button.new()
		plan.text = "Plan route"
		plan.pressed.connect(func(): plan_with_vehicle.emit(vid))
		row.add_child(plan)
		var stop := Button.new()
		stop.pressed.connect(func():
			var veh := Transport.vehicle(game.state, vid)
			stop_route.emit(vid, not bool(veh["stop_requested"])))
		row.add_child(stop)
		box.add_child(row)
		_fleet_box.add_child(box)
		_fleet_widgets[vid] = {"info": info, "plan": plan, "stop": stop}

	_clear(_buy_box)
	_buy_buttons.clear()
	for vtype in Transport.type_order():
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
	var stage := int(home["stage"])
	var info := Economy.stage_info(stage)
	var muted := Style.hex(Style.MUTED)
	_title.text = "[font_size=20][b]%s[/b][/font_size]\n[color=#%s]Stage %d %s · [b]%s[/b] people · %d of %d lines[/color]" % [
		home["name"], muted, stage, info["name"], Fmt.coins(int(home["pop"])), home["lines"].size(), int(info["max_lines"])]
	_update_growth(s, home)
	_update_infra(s, home)
	_update_lines(s, home)

	var wh: Dictionary = home["warehouse"]
	for good in _stock_widgets:
		var w: Dictionary = _stock_widgets[good]
		w["lots"].text = str(Economy.stock(wh, good))
		w["avg"].text = Fmt.coins(Economy.avg_cost(wh, good))

	for v in s["vehicles"]:
		var w: Dictionary = _fleet_widgets[v["id"]]
		w["info"].text = _vehicle_text(v)
		var idle := Transport.is_idle_at_home(s, v)
		w["plan"].visible = idle
		w["plan"].text = "Plan route" if v["last_route"].is_empty() else "Plan route (last one pre-filled)"
		var on_repeat: bool = not v["route"].is_empty() and bool(v["route"]["repeat"])
		w["stop"].visible = on_repeat
		w["stop"].text = "Keep running" if bool(v["stop_requested"]) else "Stop after this loop"

	for vtype in _buy_buttons:
		var b: Button = _buy_buttons[vtype]
		var vinfo := Transport.type_info(vtype)
		var allowed := Transport.can_buy_type(s, vtype)
		b.visible = allowed or int(vinfo["min_stage"]) <= stage + 1
		b.disabled = not allowed or int(s["treasury"]) < int(vinfo["price"])
		if not allowed:
			b.tooltip_text = "Available at Stage %d" % int(vinfo["min_stage"])
		else:
			b.tooltip_text = "Carries %d lots by %s. Upkeep %s/month." % [
				int(vinfo["capacity"]), Transport.ROUTE_WORDS[vinfo["route"]],
				Fmt.coins(int(round(int(vinfo["price"]) * float(Data.balance()["vehicles"]["upkeep_share_per_month"]))))]


func _update_growth(s: Dictionary, home: Dictionary) -> void:
	var b := Economy.growth_breakdown(s, home)
	var eta := Economy.next_stage_eta(s, home)
	var muted := Style.hex(Style.MUTED)
	var lines: PackedStringArray = []
	var rate := float(b["rate"]) * 100.0
	var col := Style.GOOD if rate > 0.0 else (Style.BAD if rate < 0.0 else Style.WARN)
	var head := "Growth [b][color=#%s]%+.1f%% / month[/color][/b]" % [Style.hex(col), rate]
	if bool(b["capped"]):
		head += " [color=#%s](at the 5%% cap)[/color]" % muted
	lines.append(head)
	if not eta.is_empty():
		var prev_min := int(Economy.stage_info(int(home["stage"]))["min_pop"])
		_stage_bar.min_value = prev_min
		_stage_bar.max_value = int(eta["min_pop"])
		_stage_bar.value = clampi(int(home["pop"]), prev_min, int(eta["min_pop"]))
		_stage_bar.visible = true
		var months := float(eta["months"])
		if months >= 0.0:
			var minutes := months * 30.0 * float(Data.balance()["clock"]["seconds_per_day_at_1x"]) / 60.0
			lines.append("Stage %d (%s, %s people) in [b]~%d months[/b] [color=#%s](≈ %s at 1×)[/color]" % [
				int(eta["stage"]), eta["name"], Fmt.coins(int(eta["min_pop"])), int(ceil(months)), muted, _duration(minutes)])
		else:
			lines.append("[color=#%s]Stage %d (%s people) — not growing right now[/color]" % [Style.hex(Style.WARN), int(eta["stage"]), Fmt.coins(int(eta["min_pop"]))])
	else:
		_stage_bar.visible = false
	var have: PackedStringArray = []
	for p in b["parts"]:
		var v := float(p[1]) * 100.0
		have.append("%s %s" % [p[0], ("%+.1f%%" % v) if v != 0.0 else ""])
	lines.append("[color=#%s]✓ %s[/color]" % [Style.hex(Style.GOOD) if bool(b["fed"]) else Style.hex(Style.BAD), " · ".join(have)])
	if not b["missing"].is_empty() and not bool(b["capped"]):
		var miss: PackedStringArray = []
		for m in b["missing"]:
			miss.append("%s (+%.1f%%)" % [m[0], float(m[1]) * 100.0])
		lines.append("[color=#%s]To grow faster: %s[/color]" % [muted, " · ".join(miss)])
	var need := Economy.food_need_per_month(home)
	var stock := Economy.food_stock(home)
	lines.append("Food: eats [b]%d[/b] lot%s of Grain or Fish a month · [b]%d[/b] in store%s" % [
		need, "" if need == 1 else "s", stock, (" (%d months)" % int(float(stock) / float(maxi(1, need)))) if stock > 0 else ""])
	_growth.text = "\n".join(lines)


static func _duration(minutes: float) -> String:
	if minutes < 60.0:
		return "%d min" % int(ceil(minutes))
	var h := int(minutes / 60.0)
	var m := int(minutes) % 60
	return "%d h %d min" % [h, m] if m > 0 else "%d h" % h


func _update_infra(s: Dictionary, home: Dictionary) -> void:
	for kind in _infra_widgets:
		var w: Dictionary = _infra_widgets[kind]
		var info: Dictionary = Data.balance()["infrastructure"]["types"][kind]
		var n := Economy.infra_count(home, kind)
		var allowed := Economy.infra_allowed(home, kind)
		w["name"].text = "%s  %d/%d" % [info["label"], n, allowed] if allowed > 0 else String(info["label"])
		var btn: Button = w["button"]
		if allowed <= 0:
			btn.text = "From Stage %d" % int(info["first_stage"])
			btn.disabled = true
		elif n >= allowed:
			btn.text = "Built" if int(home["stage"]) >= Economy.max_stage() else "Next at Stage %d" % (int(home["stage"]) + 1)
			btn.disabled = true
		else:
			var cost := Economy.infra_cost(home, kind)
			btn.text = "Build · %s" % Fmt.coins(cost)
			btn.disabled = int(s["treasury"]) < cost


func _update_lines(s: Dictionary, home: Dictionary) -> void:
	var t := int(s["time_hours"])
	var muted := Style.hex(Style.MUTED)
	for i in _line_widgets.size():
		var line: Dictionary = home["lines"][i]
		var w: Dictionary = _line_widgets[i]
		var good := String(line["good"])
		var text := ""
		var tier_tag := "T%d line" % int(line["tier"])
		if String(line["retool_to"]) != "":
			var left := ceili(float(int(line["retool_until"]) - t) / 24.0)
			text = "[b]Line %d[/b]  [color=#%s]%s → %s[/color]  [color=#%s]%s[/color]\n[color=#%s]Switching, %s left[/color]" % [
				i + 1, Style.hex(Style.SURPLUS), good, line["retool_to"], muted, tier_tag, Style.hex(Style.WARN), Style.days(left)]
			w["change"].disabled = true
		elif good == "":
			text = "[b]Line %d[/b]  [color=#%s]not producing[/color]  [color=#%s]%s[/color]\n[color=#%s]Choose a good to start (free)[/color]" % [
				i + 1, Style.hex(Style.BAD), muted, tier_tag, muted]
			w["change"].disabled = false
		else:
			var status := ""
			if String(line["waiting"]) != "":
				status = "[color=#%s]Waiting for inputs: %s per lot[/color]" % [Style.hex(Style.WARN), line["waiting"]]
			else:
				var hours := Economy.hours_to_next_lot(line)
				status = "[color=#%s]%d lots/month · %s[/color]" % [muted, Economy.line_output(line),
					("next lot in %s" % Style.days(ceili(float(hours) / 24.0))) if hours > 24 else "next lot today"]
			text = "[b]Line %d[/b]  [color=#%s][b]%s[/b][/color]  [color=#%s]%s[/color]\n%s" % [
				i + 1, Style.hex(Style.SURPLUS), good, muted, tier_tag, status]
			w["change"].disabled = false
		w["info"].text = text
		w["change"].text = "Choose" if good == "" and String(line["retool_to"]) == "" else "Change"
		var ucost := Economy.upgrade_cost(line)
		var upg: Button = w["upgrade"]
		if ucost < 0:
			upg.text = "Fully upgraded"
			upg.disabled = true
		else:
			upg.text = "Upgrade to %d/month · %s" % [int(Data.balance()["economy"]["line_output_by_level"][int(line["level"]) + 1]), Fmt.coins(ucost)]
			upg.disabled = int(s["treasury"]) < ucost or good == ""

	var stage := int(home["stage"])
	var maxl := int(Economy.stage_info(stage)["max_lines"])
	var free: int = maxl - home["lines"].size()
	_add_line_btn.visible = free > 0
	if free > 0:
		_slot_label.text = "[color=#%s]%d free line slot%s[/color]" % [Style.hex(Style.GOOD), free, "" if free == 1 else "s"]
	elif stage < Economy.max_stage():
		var nxt := Economy.stage_info(stage + 1)
		_slot_label.text = "[color=#%s]Stage %d (%s, %s people) allows %d lines and Tier %d goods.[/color]" % [
			muted, stage + 1, nxt["name"], Fmt.coins(int(nxt["min_pop"])), int(nxt["max_lines"]), stage + 1]
	else:
		_slot_label.text = ""


func _vehicle_text(v: Dictionary) -> String:
	var s: Dictionary = game.state
	var muted := Style.hex(Style.MUTED)
	var col := Style.hex(Style.VEHICLE_COLORS[v["type"]])
	var head := "[color=#%s][b]%s[/b][/color] [color=#%s](%d lots, %s)[/color]" % [
		col, v["name"], muted, int(v["capacity"]), Transport.ROUTE_WORDS[Transport.route_of(v["type"])]]
	var stats: Dictionary = v["stats"]
	if v["route"].is_empty():
		var tail := ""
		if int(stats["loops"]) > 0:
			tail = " · last trip [color=#%s]%s[/color]" % [Style.hex(Style.GOOD if int(stats["last_profit"]) >= 0 else Style.BAD), Fmt.signed(int(stats["last_profit"]))]
		return head + "\n[color=#%s]At home, ready[/color]%s" % [Style.hex(Style.GOOD), tail]
	var route: Dictionary = v["route"]
	var kind := "Route (repeating)" if bool(route["repeat"]) else "Trip"
	var line1 := "%s: %s" % [kind, Transport.route_names(s, route)]
	if bool(route["repeat"]):
		line1 += " · loop %d" % int(v["loop"].get("n", 1))
	var leg: Dictionary = v["leg"]
	var where := ""
	if not leg.is_empty():
		var to_name: String = s["cities"][leg["to"]]["name"]
		where = "%s %s, arrives %s · %s" % ["←" if int(leg["next"]) < 0 else "→", to_name,
			Simulation.short_date(s, int(leg["end"])), _cargo_text(v["cargo"])]
	var tail := ""
	if int(stats["loops"]) > 0:
		tail = "\n[color=#%s]Last loop profit %s · total %s[/color]" % [muted, Fmt.signed(int(stats["last_profit"])), Fmt.signed(int(stats["total_profit"]))]
	if bool(v["stop_requested"]):
		tail += "\n[color=#%s]Stops when this loop ends[/color]" % Style.hex(Style.WARN)
	return head + "\n" + line1 + "\n" + where + tail


func _cargo_text(cargo: Dictionary) -> String:
	if cargo.is_empty():
		return "empty"
	var parts: PackedStringArray = []
	for good in Data.good_ids():
		if cargo.has(good):
			parts.append("%d %s" % [int(cargo[good]["lots"]), good])
	return ", ".join(parts)
