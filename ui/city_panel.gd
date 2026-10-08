## Right-hand panel: the selected city, how your vehicles get there, and its market with Buy/Sell.
extends VBoxContainer

signal plan_trip(dest: String, sell: Dictionary, buy: Dictionary)
signal sell_home(good: String)
signal show_prices(good: String)

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

const COLS := ["Good", "Status", "Sells to you", "Pays you", "You have", ""]

var game: RefCounted
var city_id := ""
var _header: RichTextLabel
var _reach: RichTextLabel
var _grid: GridContainer
var _rows := {}  # good -> {status, sells, pays, have, buy, sell}


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_header = Style.rich()
	add_child(_header)
	_reach = Style.rich()
	add_child(_reach)
	add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = COLS.size()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 3)
	scroll.add_child(_grid)


func set_city(g: RefCounted, id: String) -> void:
	game = g
	city_id = id
	_build_rows()
	refresh()


func _is_home() -> bool:
	return city_id == game.state["home_id"]


func _build_rows() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_rows.clear()
	for i in COLS.size():
		var h := Style.label(COLS[i], Style.MUTED, 13)
		if i >= 2 and i <= 4:
			Style.right(h)
		_grid.add_child(h)
	for good in Data.good_ids():
		var name_btn := LinkButton.new()
		name_btn.text = good
		name_btn.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
		name_btn.tooltip_text = "Show %s prices on the map" % good
		name_btn.pressed.connect(func(): show_prices.emit(good))
		name_btn.custom_minimum_size.x = 82
		_grid.add_child(name_btn)
		var status := Style.label("")
		status.custom_minimum_size.x = 66
		_grid.add_child(status)
		var sells := Style.right(Style.label(""))
		sells.custom_minimum_size.x = 82
		_grid.add_child(sells)
		var pays := Style.right(Style.label(""))
		pays.custom_minimum_size.x = 82
		_grid.add_child(pays)
		var have := Style.right(Style.label(""))
		have.custom_minimum_size.x = 56
		_grid.add_child(have)
		var actions := HBoxContainer.new()
		actions.add_theme_constant_override("separation", 4)
		var buy := Button.new()
		buy.text = "Buy"
		buy.custom_minimum_size.x = 48
		buy.pressed.connect(func(): plan_trip.emit(city_id, {}, {good: -1}))
		var sell := Button.new()
		sell.text = "Sell"
		sell.custom_minimum_size.x = 48
		sell.pressed.connect(_on_sell.bind(good))
		actions.add_child(buy)
		actions.add_child(sell)
		_grid.add_child(actions)
		_rows[good] = {"name": name_btn, "status": status, "sells": sells, "pays": pays, "have": have, "buy": buy, "sell": sell}


func _on_sell(good: String) -> void:
	if _is_home():
		sell_home.emit(good)
	else:
		plan_trip.emit(city_id, {good: -1}, {})


func refresh() -> void:
	if game == null or city_id == "":
		return
	var s: Dictionary = game.state
	var c: Dictionary = s["cities"][city_id]
	var home := _is_home()
	_refresh_header(c, home)
	_refresh_reach(home)
	var idle_reach := _idle_vehicle_can_reach()
	var wh: Dictionary = Economy.home(s)["warehouse"]
	for good in _rows:
		var row: Dictionary = _rows[good]
		var band: String = c["market"][good]["band"]
		var col := Style.band_color(band)
		row["name"].add_theme_color_override("font_color", col)
		row["status"].text = Style.band_label(band)
		row["status"].add_theme_color_override("font_color", col)
		var sells_to_you := Market.city_sells(s, city_id, good)
		row["sells"].text = Fmt.coins(Market.listed_price(s, city_id, good)) if sells_to_you else "—"
		row["sells"].add_theme_color_override("font_color", Color.WHITE if sells_to_you else Style.MUTED)
		row["pays"].text = Fmt.coins(Market.sell_lot_prices(s, city_id, good, 1)[0])
		var stock := Economy.stock(wh, good)
		row["have"].text = str(stock) if stock > 0 else "—"
		row["have"].add_theme_color_override("font_color", Color.WHITE if stock > 0 else Style.MUTED)
		var buy: Button = row["buy"]
		var sell: Button = row["sell"]
		buy.visible = not home
		if home:
			sell.disabled = stock <= 0
			sell.tooltip_text = "Sell %s to your home market now (it pays 75%% of normal prices)" % good if stock > 0 else "You have no %s" % good
			continue
		buy.disabled = not sells_to_you or not idle_reach
		if not sells_to_you:
			buy.tooltip_text = "%s doesn't produce %s, so it doesn't sell it" % [c["name"], good]
		elif not idle_reach:
			buy.tooltip_text = "None of your vehicles at home can reach %s right now" % c["name"]
		else:
			buy.tooltip_text = "Plan a trip to buy %s in %s and bring it home" % [good, c["name"]]
		sell.disabled = stock <= 0 or not idle_reach
		if stock <= 0:
			sell.tooltip_text = "You have no %s in your warehouse" % good
		elif not idle_reach:
			sell.tooltip_text = "None of your vehicles at home can reach %s right now" % c["name"]
		else:
			sell.tooltip_text = "Plan a trip to sell %s in %s" % [good, c["name"]]


func _idle_vehicle_can_reach() -> bool:
	var s: Dictionary = game.state
	for v in Transport.idle_vehicles(s):
		if int(Transport.path_for(s, s["home_id"], city_id, v["type"])["days"]) > 0:
			return true
	return false


func _refresh_header(c: Dictionary, home: bool) -> void:
	var site: String = "overseas port" if c["region"] == "overseas" else {"fjord": "fjord", "coast": "open coast", "inland": "inland"}[c["site"]]
	var lines: PackedStringArray = []
	var title := "[font_size=21][b]%s[/b][/font_size]" % c["name"]
	if home:
		title += "  [color=#%s]your settlement[/color]" % Style.hex(Style.HOME)
	lines.append(title)
	lines.append("[color=#%s]%s · %s · %s climate · population %s[/color]" % [
		Style.hex(Style.MUTED), String(c["culture"]).capitalize(), site, c["climate"], Fmt.coins(int(c["pop"]))])
	var produces: Array = c["production_options"] if home else c["produces"]
	lines.append("%s: [color=#%s]%s[/color]" % ["Can produce" if home else "Produces", Style.hex(Style.SURPLUS), ", ".join(PackedStringArray(produces))])
	var days_left := ceili(float(c["want_timer_hours"]) / 24.0)
	lines.append("Wants: [color=#%s]%s[/color]  [color=#%s](changes in %s)[/color]" % [
		Style.hex(Style.WANT), ", ".join(PackedStringArray(c["wants"])), Style.hex(Style.MUTED), Style.days(days_left)])
	if home:
		lines.append("[color=#%s]Your home market buys at 75%% of normal prices and sells nothing yet.[/color]" % Style.hex(Style.MUTED))
	_header.text = "\n".join(lines)


func _refresh_reach(home: bool) -> void:
	var s: Dictionary = game.state
	var home_id: String = s["home_id"]
	var lines: PackedStringArray = []
	if home:
		lines.append("[b]Your vehicles leave from here.[/b]")
		for vtype in ["wagon", "barge", "ocean"]:
			var n := Transport.reachable(s, home_id, vtype).size()
			lines.append("[color=#%s]■[/color] %s can reach %d cit%s" % [
				Style.hex(Style.ROUTE_COLORS[Transport.route_of(vtype)]), Transport.label_of(vtype) + "s", n, "y" if n == 1 else "ies"])
		_reach.text = "\n".join(lines)
		return
	lines.append("[b]Getting there from %s[/b]" % s["cities"][home_id]["name"])
	for vtype in ["wagon", "barge", "ocean"]:
		var rt := Transport.route_of(vtype)
		var swatch := "[color=#%s]■[/color]" % Style.hex(Style.ROUTE_COLORS[rt])
		var p := Transport.path_for(s, home_id, city_id, vtype)
		var days := int(p["days"])
		var label := Transport.label_of(vtype)
		if days <= 0:
			lines.append("%s [color=#%s]%s — no %s route[/color]" % [swatch, Style.hex(Style.MUTED), label, Transport.ROUTE_WORDS[rt]])
			continue
		var text := "%s %s — [b]%s[/b] by %s" % [swatch, label, Style.days(days), Transport.ROUTE_WORDS[rt]]
		var stops: Array = p["stops"]
		if stops.size() > 2:
			var via: PackedStringArray = []
			for i in range(1, stops.size() - 1):
				via.append(s["cities"][stops[i]]["name"])
			text += " via " + ", ".join(via)
		text += "  " + _availability(vtype)
		lines.append(text)
	_reach.text = "\n".join(lines)


func _availability(vtype: String) -> String:
	var s: Dictionary = game.state
	var total := 0
	var idle := 0
	for v in s["vehicles"]:
		if v["type"] == vtype:
			total += 1
			if Transport.is_idle_at_home(s, v):
				idle += 1
	var muted := Style.hex(Style.MUTED)
	if total > 0:
		return "[color=#%s](you have %d, %d at home)[/color]" % [muted, total, idle]
	if not Transport.can_buy_type(s, vtype):
		return "[color=#%s](available at Stage %d)[/color]" % [muted, int(Transport.type_info(vtype)["min_stage"])]
	return "[color=#%s](you have none)[/color]" % muted
