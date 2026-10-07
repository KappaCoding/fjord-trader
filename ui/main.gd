## Milestone 1 dashboard: watch a generated world's markets run in real time.
## The UI only reads the game state and calls Game methods; all rules live in engine/.
extends Control

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const Simulation := preload("res://engine/simulation.gd")
const Game := preload("res://engine/game.gd")

const SAVE_PATH := "user://saves/quicksave.sav"
const COLOR_WANT := Color(0.45, 0.85, 0.45)
const COLOR_SURPLUS := Color(0.95, 0.68, 0.32)
const COLOR_NEUTRAL := Color(0.85, 0.85, 0.85)
const COLOR_MUTED := Color(0.6, 0.6, 0.6)
const COLUMNS := ["Good", "Tier", "Base", "Status", "Listed price", "vs base", "Sells to you", "Pays you (1st lot)"]
const ROUTE_LABELS := {"land": "Land", "sheltered": "Water", "ocean": "Ocean"}

var game: Game
var speed := 1
var paused := false
var time_acc := 0.0
var selected_id := ""
var _tree_items := {}
var _news_count := -1
var _last_day := -1

var date_label: Label
var pause_button: Button
var speed_buttons := {}
var seed_edit: LineEdit
var count_spin: SpinBox
var status_label: Label
var city_tree: Tree
var _city_items := {}
var city_header: RichTextLabel
var price_tree: Tree
var news_list: ItemList


func _ready() -> void:
	_build_ui()
	count_spin.value = int(Data.balance()["world"]["npc_cities_default"])
	seed_edit.text = _random_seed_text()
	_start_new_world()


# ------------------------------------------------------------------ time

func _process(delta: float) -> void:
	if game == null or paused:
		return
	var clock: Dictionary = Data.balance()["clock"]
	var hours_per_second := 24.0 / float(clock["seconds_per_day_at_1x"])
	time_acc += delta * speed * hours_per_second
	var steps := int(time_acc)
	if steps <= 0:
		return
	time_acc -= steps
	game.advance_hours(mini(steps, int(clock["max_steps_per_frame"])))
	_refresh_live()


func _set_speed(s: int) -> void:
	speed = s
	speed_buttons[s].button_pressed = true
	_set_paused(false)


func _set_paused(p: bool) -> void:
	paused = p
	pause_button.set_pressed_no_signal(p)
	pause_button.text = "Paused" if p else "Pause"
	_refresh_date()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			_set_paused(not paused)
		KEY_ESCAPE:
			_set_paused(true)  # The settings menu comes in a later milestone.
		KEY_1:
			_set_speed(1)
		KEY_2:
			_set_speed(2)
		KEY_3:
			_set_speed(4)
		_:
			return
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ actions

func _start_new_world() -> void:
	var text := seed_edit.text.strip_edges()
	if text == "":
		text = _random_seed_text()
		seed_edit.text = text
	game = Game.new()
	game.new_game(text, int(count_spin.value))
	time_acc = 0.0
	_after_state_replaced()
	status_label.text = "New world generated from seed \"%s\"." % text


func _on_save() -> void:
	var err := game.save_to(SAVE_PATH)
	status_label.text = "Game saved." if err == OK else "Save failed (error %d)." % err


func _on_load() -> void:
	var g := Game.new()
	if not g.load_from(SAVE_PATH):
		status_label.text = "No save found."
		return
	game = g
	seed_edit.text = String(game.state.get("seed_text", ""))
	count_spin.set_value_no_signal(int(game.state["npc_count"]))
	time_acc = 0.0
	_after_state_replaced()
	status_label.text = "Game loaded."


func _after_state_replaced() -> void:
	selected_id = game.state["home_id"]
	_news_count = -1
	_last_day = -1
	_refresh_city_list()
	_city_items[selected_id].select(0)
	_rebuild_price_tree()
	_refresh_live()


func _on_city_selected() -> void:
	var item := city_tree.get_selected()
	if item == null:
		return
	selected_id = item.get_metadata(0)
	_rebuild_price_tree()
	_refresh_header()


# ------------------------------------------------------------------ refresh

@warning_ignore("integer_division")
func _refresh_live() -> void:
	_refresh_date()
	_refresh_prices()
	var day := int(game.state["time_hours"]) / 24
	if day != _last_day:
		_last_day = day
		_refresh_header()
	if game.state["news"].size() != _news_count:
		_refresh_news()


func _refresh_date() -> void:
	if game == null:
		return
	var suffix := "   ⏸ paused" if paused else "   ▶ %d×" % speed
	date_label.text = game.date_string() + suffix


func _refresh_city_list() -> void:
	city_tree.clear()
	_city_items.clear()
	var s := game.state
	var home_id: String = s["home_id"]
	var root := city_tree.create_item()
	for id in s["city_order"]:
		var c: Dictionary = s["cities"][id]
		var item := city_tree.create_item(root)
		item.set_metadata(0, id)
		item.set_text(0, ("★ " + c["name"]) if id == home_id else c["name"])
		item.set_text(1, fmt(int(c["pop"])))
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		for i in Geo.ROUTE_TYPES.size():
			var col := 2 + i
			item.set_text_alignment(col, HORIZONTAL_ALIGNMENT_RIGHT)
			if id == home_id:
				item.set_text(col, "")
				continue
			var path := Geo.best_path(s, home_id, id, Geo.ROUTE_TYPES[i])
			var days := int(path["days"])
			if days < 0:
				item.set_text(col, "—")
				item.set_custom_color(col, COLOR_MUTED)
			else:
				var stops: Array = path["stops"]
				item.set_text(col, "%dd%s" % [days, " ↪" if stops.size() > 2 else ""])
				if stops.size() > 2:
					item.set_tooltip_text(col, "Via " + _via_names(stops))
		_city_items[id] = item


## Names of the cities a path passes through, excluding its start and end.
func _via_names(stops: Array) -> String:
	var names: Array = []
	for i in range(1, stops.size() - 1):
		names.append(game.state["cities"][stops[i]]["name"])
	return ", ".join(PackedStringArray(names))


func _route_summary(from_id: String, to_id: String) -> String:
	var parts: Array = []
	for rt in Geo.ROUTE_TYPES:
		var path := Geo.best_path(game.state, from_id, to_id, rt)
		var days := int(path["days"])
		if days > 0:
			var text := "%s %d days" % [ROUTE_LABELS[rt], days]
			if path["stops"].size() > 2:
				text += " (via %s)" % _via_names(path["stops"])
			parts.append(text)
	return "unreachable" if parts.is_empty() else " · ".join(PackedStringArray(parts))


func _site_label(c: Dictionary) -> String:
	if c["region"] == Geo.REGION_OVERSEAS:
		return "overseas port"
	match c["site"]:
		"fjord":
			return "fjord"
		"coast":
			return "open coast"
	return "inland"


func _refresh_header() -> void:
	var s := game.state
	var c: Dictionary = s["cities"][selected_id]
	var home_id: String = s["home_id"]
	var lines: Array = []
	var title := "[font_size=22][b]%s[/b][/font_size]" % c["name"]
	if c["is_home"]:
		title += "   [color=#8fb8de]your settlement[/color]"
	lines.append(title)
	lines.append("%s culture · %s · %s climate" % [String(c["culture"]).capitalize(), _site_label(c), c["climate"]])
	lines.append("Population %s · price impact %.1f%% per lot" % [fmt(int(c["pop"])), Market.impact_step(int(c["pop"])) * 100.0])
	var feats: Array = c["features"]
	lines.append("Terrain: %s" % (", ".join(PackedStringArray(feats)) if not feats.is_empty() else "flat lowland"))
	if c["is_home"]:
		lines.append("Can produce: [color=#f2ad52]%s[/color]   (you choose your two lines in Milestone 2)" % ", ".join(PackedStringArray(c["production_options"])))
		lines.append("[color=#999999]Your home market pays 75% of normal prices — a safety valve, not a main outlet.[/color]")
	else:
		lines.append("Produces: [color=#f2ad52]%s[/color]" % ", ".join(PackedStringArray(c["produces"])))
	var days_left := ceili(float(c["want_timer_hours"]) / 24.0)
	lines.append("Wants: [color=#73d973]%s[/color]   (changes in %d days)" % [", ".join(PackedStringArray(c["wants"])), days_left])
	if not c["is_home"]:
		lines.append("From %s: %s" % [s["cities"][home_id]["name"], _route_summary(home_id, selected_id)])
	city_header.text = "\n".join(PackedStringArray(lines))


func _rebuild_price_tree() -> void:
	price_tree.clear()
	_tree_items.clear()
	var root := price_tree.create_item()
	for id in Data.good_ids():
		var item := price_tree.create_item(root)
		item.set_text(0, id)
		item.set_text(1, "Import" if Data.is_import_only(id) else "T%d" % Data.tier(id))
		item.set_text(2, fmt(Data.base_price(id)))
		for col in [2, 4, 5, 7]:
			item.set_text_alignment(col, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(1, COLOR_MUTED)
		item.set_custom_color(2, COLOR_MUTED)
		_tree_items[id] = item
	_refresh_prices()


func _refresh_prices() -> void:
	if selected_id == "" or _tree_items.is_empty():
		return
	var s := game.state
	var city: Dictionary = s["cities"][selected_id]
	for id in _tree_items:
		var item: TreeItem = _tree_items[id]
		var band: String = city["market"][id]["band"]
		var listed := Market.listed_price(s, selected_id, id)
		var pct := (float(listed) / float(Data.base_price(id)) - 1.0) * 100.0
		var color := COLOR_WANT if band == "want" else (COLOR_SURPLUS if band == "surplus" else COLOR_NEUTRAL)
		item.set_text(3, band.capitalize())
		item.set_text(4, fmt(listed))
		item.set_text(5, "%+.1f%%" % pct)
		item.set_text(6, "Yes" if Market.city_sells(s, selected_id, id) else "—")
		item.set_text(7, fmt(Market.sell_lot_prices(s, selected_id, id, 1)[0]))
		item.set_custom_color(0, color)
		item.set_custom_color(3, color)
		item.set_custom_color(5, COLOR_WANT if pct >= 0.0 else COLOR_SURPLUS)


func _refresh_news() -> void:
	var news: Array = game.state["news"]
	_news_count = news.size()
	news_list.clear()
	var start := maxi(0, news.size() - 200)
	for i in range(news.size() - 1, start - 1, -1):
		var entry: Dictionary = news[i]
		news_list.add_item("%s   %s" % [Simulation.short_date(game.state, int(entry["t"])), entry["text"]])


# ------------------------------------------------------------------ layout

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	# Top bar: clock, speed, world controls
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	root.add_child(top)

	date_label = Label.new()
	date_label.custom_minimum_size.x = 300
	date_label.add_theme_font_size_override("font_size", 18)
	top.add_child(date_label)

	pause_button = Button.new()
	pause_button.text = "Pause"
	pause_button.toggle_mode = true
	pause_button.tooltip_text = "Space"
	pause_button.toggled.connect(func(on: bool): _set_paused(on))
	top.add_child(pause_button)

	var group := ButtonGroup.new()
	var keys := {1: "1", 2: "2", 4: "3"}
	for s in [1, 2, 4]:
		var b := Button.new()
		b.text = "%d×" % s
		b.toggle_mode = true
		b.button_group = group
		b.tooltip_text = "Key %s" % keys[s]
		b.pressed.connect(_set_speed.bind(s))
		top.add_child(b)
		speed_buttons[s] = b
	speed_buttons[1].button_pressed = true

	top.add_child(VSeparator.new())
	top.add_child(_label("Seed"))
	seed_edit = LineEdit.new()
	seed_edit.custom_minimum_size.x = 140
	seed_edit.tooltip_text = "Any text. The same seed and city count always give the same world."
	seed_edit.text_submitted.connect(func(_t): _start_new_world())
	top.add_child(seed_edit)

	top.add_child(_label("Cities"))
	count_spin = SpinBox.new()
	var w: Dictionary = Data.balance()["world"]
	count_spin.min_value = int(w["npc_cities_min"])
	count_spin.max_value = int(w["npc_cities_max"])
	count_spin.tooltip_text = "Number of other cities in the world"
	top.add_child(count_spin)

	var new_btn := Button.new()
	new_btn.text = "New world"
	new_btn.pressed.connect(_start_new_world)
	top.add_child(new_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", COLOR_MUTED)
	top.add_child(status_label)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save)
	top.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(_on_load)
	top.add_child(load_btn)

	# Body: city list | city details + prices
	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 470
	body.add_child(left)
	left.add_child(_label("Cities — travel days from home  (↪ = via other cities)"))
	city_tree = Tree.new()
	city_tree.columns = 5
	city_tree.column_titles_visible = true
	city_tree.hide_root = true
	city_tree.select_mode = Tree.SELECT_ROW
	city_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var city_cols := ["City", "Population", "Land", "Water", "Ocean"]
	for i in city_cols.size():
		city_tree.set_column_title(i, city_cols[i])
		city_tree.set_column_expand(i, true)
		city_tree.set_column_expand_ratio(i, 3 if i == 0 else 2 if i == 1 else 1)
	city_tree.item_selected.connect(_on_city_selected)
	left.add_child(city_tree)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)

	city_header = RichTextLabel.new()
	city_header.bbcode_enabled = true
	city_header.fit_content = true
	city_header.scroll_active = false
	right.add_child(city_header)

	price_tree = Tree.new()
	price_tree.columns = COLUMNS.size()
	price_tree.column_titles_visible = true
	price_tree.hide_root = true
	price_tree.select_mode = Tree.SELECT_ROW
	price_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for i in COLUMNS.size():
		price_tree.set_column_title(i, COLUMNS[i])
		price_tree.set_column_expand(i, true)
		price_tree.set_column_expand_ratio(i, 2 if i == 0 else 1)
	right.add_child(price_tree)

	# News feed
	root.add_child(_label("News"))
	news_list = ItemList.new()
	news_list.custom_minimum_size.y = 130
	root.add_child(news_list)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _random_seed_text() -> String:
	var r := RandomNumberGenerator.new()
	r.randomize()
	return "%06d" % r.randi_range(0, 999999)


## 1234567 -> "1,234,567"
static func fmt(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out
