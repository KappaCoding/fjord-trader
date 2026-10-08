## The dashboard. Builds the layout, runs the clock, and turns button presses into Game commands.
## All rules live in engine/; the panels in ui/ only read state and emit requests.
extends Control

const Data := preload("res://engine/data.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Simulation := preload("res://engine/simulation.gd")
const News := preload("res://engine/news.gd")
const Fmt := preload("res://engine/format.gd")
const Game := preload("res://engine/game.gd")
const Style := preload("res://ui/style.gd")
const WorldMap := preload("res://ui/world_map.gd")
const CityPanel := preload("res://ui/city_panel.gd")
const SettlementPanel := preload("res://ui/settlement_panel.gd")
const FinancePanel := preload("res://ui/finance_panel.gd")
const TripPlanner := preload("res://ui/trip_planner.gd")
const LineDialog := preload("res://ui/line_dialog.gd")
const SellHomeDialog := preload("res://ui/sell_home_dialog.gd")

const SAVE_PATH := "user://saves/quicksave.sav"
const UI_REFRESH_SECONDS := 0.2

var game: Game
var speed := 1
var paused := false
var time_acc := 0.0
var refresh_acc := 0.0
var selected_id := ""
var _news_count := -1
var _choosing_lines := false

var date_label: Label
var pause_button: Button
var speed_buttons := {}
var treasury_label: Label
var worth_label: Label
var costs_label: Label
var status_label: Label
var world_map: WorldMap
var route_checks := {}
var price_opt: OptionButton
var city_panel: CityPanel
var settlement: SettlementPanel
var finance: FinancePanel
var news_list: ItemList
var planner: TripPlanner
var line_dialog: LineDialog
var sell_dialog: SellHomeDialog
var new_world_dialog: ConfirmationDialog
var seed_edit: LineEdit
var count_spin: SpinBox
var message_dialog: AcceptDialog


func _ready() -> void:
	var t := Theme.new()
	t.default_font_size = 14
	theme = t
	_build_ui()
	_start_new_world(_random_seed_text(), int(Data.balance()["world"]["npc_cities_default"]))


# ------------------------------------------------------------------ time

func _process(delta: float) -> void:
	if game == null:
		return
	if not paused:
		var clock: Dictionary = Data.balance()["clock"]
		time_acc += delta * speed * 24.0 / float(clock["seconds_per_day_at_1x"])
		var steps := int(time_acc)
		if steps > 0:
			time_acc -= steps
			game.advance_hours(mini(steps, int(clock["max_steps_per_frame"])))
			world_map.queue_redraw()
	refresh_acc += delta
	if refresh_acc >= UI_REFRESH_SECONDS:
		refresh_acc = 0.0
		_refresh()


func _set_speed(s: int) -> void:
	speed = s
	speed_buttons[s].button_pressed = true
	_set_paused(false)


func _set_paused(p: bool) -> void:
	paused = p
	pause_button.set_pressed_no_signal(p)
	pause_button.text = "▶ Resume" if p else "⏸ Pause"
	_refresh_top()


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


# ------------------------------------------------------------------ game lifecycle

func _start_new_world(seed_text: String, npc_count: int) -> void:
	game = Game.new()
	game.new_game(seed_text, npc_count)
	time_acc = 0.0
	_after_game_replaced()
	_status("New world from seed \"%s\"." % seed_text)
	_set_paused(true)
	_choosing_lines = true
	_ask_next_line()


func _after_game_replaced() -> void:
	selected_id = game.state["home_id"]
	_news_count = -1
	world_map.set_game(game)
	world_map.price_good = ""
	price_opt.select(0)
	settlement.set_game(game)
	finance.game = game
	city_panel.set_city(game, selected_id)
	planner.hide()
	_refresh()


func _ask_next_line() -> void:
	var lines: Array = game.home()["lines"]
	for i in lines.size():
		if String(lines[i]["good"]) == "" and String(lines[i]["retool_to"]) == "":
			line_dialog.open_for(game, i)
			return
	if _choosing_lines:
		_choosing_lines = false
		_set_paused(false)
		_status("Production started. Goods arrive in your warehouse every few days.")


func _on_save() -> void:
	var err := game.save_to(SAVE_PATH)
	_status("Game saved." if err == OK else "Save failed (error %d)." % err)


func _on_load() -> void:
	var g := Game.new()
	if not g.load_from(SAVE_PATH):
		_message("Load", g.last_load_error)
		return
	game = g
	time_acc = 0.0
	_after_game_replaced()
	_set_paused(true)
	_status("Game loaded (paused).")


# ------------------------------------------------------------------ requests from panels

func _on_city_clicked(id: String) -> void:
	selected_id = id
	world_map.selected_id = id
	city_panel.set_city(game, id)
	world_map.queue_redraw()


func _on_plan_trip(dest: String, sell: Dictionary, buy: Dictionary) -> void:
	if not planner.open_for(game, "", dest, sell, buy):
		_message("Plan a trip", "All your vehicles are away. Wait for one to come home, or buy another.")


func _on_plan_with_vehicle(vehicle_id: String) -> void:
	var dest := selected_id if selected_id != game.state["home_id"] else ""
	if not planner.open_for(game, vehicle_id, dest, {}, {}):
		_message("Plan a trip", "That vehicle is away.")


func _on_trip_submitted(vehicle_id: String, dest: String, sell: Dictionary, buy: Dictionary) -> void:
	var r := game.send_trip(vehicle_id, dest, sell, buy)
	if r["errors"].is_empty():
		_status("%s is on its way to %s." % [Transport.vehicle(game.state, vehicle_id)["name"], game.state["cities"][dest]["name"]])
	else:
		_message("Trip not sent", "\n".join(PackedStringArray(r["errors"])))
	_refresh()


func _on_line_chosen(index: int, good: String) -> void:
	var err := game.choose_line(index, good)
	if err != "":
		_message("Production", err)
	_refresh()
	if _choosing_lines:
		_ask_next_line.call_deferred()


func _on_line_dialog_closed() -> void:
	if _choosing_lines and game.needs_line_choice():
		_choosing_lines = false
		_status("Some lines aren't producing yet. Use Choose in the Production list; press Space to start time.")


func _on_sell_home(good: String) -> void:
	sell_dialog.open_for(game, good)


func _on_sell_home_confirmed(good: String, lots: int) -> void:
	var r := game.sell_at_home(good, lots)
	if r["error"] != "":
		_message("Sell", r["error"])
	else:
		_status("Sold %d %s at home for %s." % [lots, good, Fmt.coins(r["revenue"])])
	_refresh()


func _on_buy_vehicle(vtype: String) -> void:
	var err := game.buy_vehicle(vtype)
	if err != "":
		_message("Buy vehicle", err)
	else:
		_status("Bought a new %s." % Transport.label_of(vtype).to_lower())
	_refresh()


func _on_show_prices(good: String) -> void:
	for i in price_opt.item_count:
		if price_opt.get_item_text(i) == good:
			price_opt.select(i)
	world_map.price_good = good
	world_map.queue_redraw()


func _on_price_selected(index: int) -> void:
	world_map.price_good = "" if index == 0 else price_opt.get_item_text(index)
	world_map.queue_redraw()


# ------------------------------------------------------------------ refresh

func _refresh() -> void:
	if game == null:
		return
	_refresh_top()
	settlement.refresh()
	city_panel.refresh()
	world_map.refresh()
	if finance.is_visible_in_tree():
		finance.refresh()
	if planner.visible:
		planner.refresh_estimate()
	if game.state["news"].size() != _news_count:
		_refresh_news()


func _refresh_top() -> void:
	if game == null:
		return
	date_label.text = game.date_string()
	var treasury := int(game.state["treasury"])
	treasury_label.text = Fmt.coins(treasury)
	treasury_label.add_theme_color_override("font_color", Style.BAD if treasury < 0 else Color.WHITE)
	worth_label.text = Fmt.coins(game.net_worth())
	var f: Dictionary = game.forecast()
	costs_label.text = "−%s / month" % Fmt.coins(f["per_month"])


func _refresh_news() -> void:
	var news: Array = game.state["news"]
	_news_count = news.size()
	news_list.clear()
	var start := maxi(0, news.size() - 300)
	for i in range(news.size() - 1, start - 1, -1):
		var entry: Dictionary = news[i]
		var idx := news_list.add_item("%s   %s" % [Simulation.short_date(game.state, int(entry["t"])), entry["text"]])
		match entry.get("kind", News.KIND_MARKET):
			News.KIND_TRADE:
				news_list.set_item_custom_fg_color(idx, Style.TRADE_NEWS)
			News.KIND_CITY:
				news_list.set_item_custom_fg_color(idx, Style.CITY_NEWS)


func _status(text: String) -> void:
	status_label.text = text


func _message(title_text: String, text: String) -> void:
	message_dialog.title = title_text
	message_dialog.dialog_text = text
	message_dialog.popup_centered()


# ------------------------------------------------------------------ layout

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("23262b")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	root.add_child(_build_top_bar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	root.add_child(body)

	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size.x = 380
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(left_scroll)
	settlement = SettlementPanel.new()
	settlement.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(settlement)
	settlement.change_line.connect(func(i): line_dialog.open_for(game, i))
	settlement.sell_home.connect(_on_sell_home)
	settlement.plan_with_vehicle.connect(_on_plan_with_vehicle)
	settlement.buy_vehicle.connect(_on_buy_vehicle)
	settlement.show_prices.connect(_on_show_prices)

	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(center)
	center.add_child(_build_map_toolbar())
	world_map = WorldMap.new()
	world_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	world_map.city_clicked.connect(_on_city_clicked)
	center.add_child(world_map)
	status_label = Style.label("", Style.MUTED)
	status_label.clip_text = true
	status_label.custom_minimum_size.x = 50
	center.add_child(status_label)

	city_panel = CityPanel.new()
	city_panel.custom_minimum_size.x = 540
	body.add_child(city_panel)
	city_panel.plan_trip.connect(_on_plan_trip)
	city_panel.sell_home.connect(_on_sell_home)
	city_panel.show_prices.connect(_on_show_prices)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size.y = 190
	root.add_child(tabs)
	news_list = ItemList.new()
	news_list.name = "News"
	tabs.add_child(news_list)
	finance = FinancePanel.new()
	finance.name = "Finances"
	tabs.add_child(finance)
	tabs.tab_changed.connect(func(_i): _refresh())

	planner = TripPlanner.new()
	add_child(planner)
	planner.submitted.connect(_on_trip_submitted)
	planner.preview_changed.connect(func(stops, vtype):
		world_map.preview_stops = stops
		world_map.preview_type = vtype
		world_map.queue_redraw())

	line_dialog = LineDialog.new()
	add_child(line_dialog)
	line_dialog.chosen.connect(_on_line_chosen)
	line_dialog.canceled.connect(_on_line_dialog_closed)
	line_dialog.confirmed.connect(_on_line_dialog_closed)

	sell_dialog = SellHomeDialog.new()
	add_child(sell_dialog)
	sell_dialog.sell.connect(_on_sell_home_confirmed)

	message_dialog = AcceptDialog.new()
	add_child(message_dialog)

	_build_new_world_dialog()


func _build_top_bar() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)

	date_label = Style.label("", Color.WHITE, 18)
	date_label.custom_minimum_size.x = 200
	top.add_child(date_label)

	pause_button = Button.new()
	pause_button.toggle_mode = true
	pause_button.custom_minimum_size.x = 96
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
		b.tooltip_text = "Game speed (key %s). 1× = one day every 10 seconds." % keys[s]
		b.pressed.connect(_set_speed.bind(s))
		top.add_child(b)
		speed_buttons[s] = b
	speed_buttons[1].button_pressed = true

	top.add_child(VSeparator.new())
	top.add_child(Style.label("Treasury", Style.MUTED))
	treasury_label = Style.label("", Color.WHITE, 17)
	treasury_label.custom_minimum_size.x = 110
	top.add_child(treasury_label)
	top.add_child(Style.label("Net worth", Style.MUTED))
	worth_label = Style.label("", Color.WHITE, 17)
	worth_label.custom_minimum_size.x = 110
	worth_label.tooltip_text = "Treasury + goods at what they cost you + vehicles + production lines"
	top.add_child(worth_label)
	top.add_child(Style.label("Running costs", Style.MUTED))
	costs_label = Style.label("", Style.WARN, 15)
	costs_label.tooltip_text = "Upkeep, tax and storage, charged continuously. Details in the Finances tab."
	top.add_child(costs_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var menu := MenuButton.new()
	menu.text = "Game ▾"
	menu.flat = false
	var popup := menu.get_popup()
	popup.add_item("New world…", 0)
	popup.add_item("Save", 1)
	popup.add_item("Load", 2)
	popup.id_pressed.connect(_on_game_menu)
	top.add_child(menu)
	return top


func _on_game_menu(id: int) -> void:
	match id:
		0:
			seed_edit.text = _random_seed_text()
			new_world_dialog.popup_centered(Vector2i(420, 0))
		1:
			_on_save()
		2:
			_on_load()


func _build_map_toolbar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.add_child(Style.label("Routes:", Style.MUTED))
	var names := {"land": "Road", "sheltered": "Water", "ocean": "Open sea"}
	var tips := {"land": "Roads your wagons use", "sheltered": "Sheltered water your barges use",
		"ocean": "Open-sea routes for ocean ships (available from Stage 3)"}
	for rt in ["land", "sheltered", "ocean"]:
		var cb := CheckBox.new()
		cb.text = names[rt]
		cb.tooltip_text = tips[rt]
		cb.button_pressed = world_map.show_route[rt] if world_map != null else rt != "ocean"
		cb.add_theme_color_override("font_color", Style.ROUTE_COLORS[rt])
		cb.add_theme_color_override("font_pressed_color", Style.ROUTE_COLORS[rt])
		cb.toggled.connect(func(on: bool):
			world_map.show_route[rt] = on
			world_map.queue_redraw())
		bar.add_child(cb)
		route_checks[rt] = cb
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	bar.add_child(Style.label("Prices:", Style.MUTED))
	price_opt = OptionButton.new()
	price_opt.add_item("off")
	for good in Data.good_ids():
		price_opt.add_item(good)
	price_opt.tooltip_text = "Colour cities by what they pay you for a good (green = pays a premium)"
	price_opt.item_selected.connect(_on_price_selected)
	bar.add_child(price_opt)
	return bar


func _build_new_world_dialog() -> void:
	new_world_dialog = ConfirmationDialog.new()
	new_world_dialog.title = "New world"
	new_world_dialog.ok_button_text = "Generate"
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_child(Style.label("Seed"))
	seed_edit = LineEdit.new()
	seed_edit.custom_minimum_size.x = 200
	seed_edit.tooltip_text = "Any text. The same seed and city count always give the same world."
	grid.add_child(seed_edit)
	grid.add_child(Style.label("Other cities"))
	count_spin = SpinBox.new()
	var w: Dictionary = Data.balance()["world"]
	count_spin.min_value = int(w["npc_cities_min"])
	count_spin.max_value = int(w["npc_cities_max"])
	count_spin.value = int(w["npc_cities_default"])
	grid.add_child(count_spin)
	new_world_dialog.add_child(grid)
	new_world_dialog.confirmed.connect(func():
		var text := seed_edit.text.strip_edges()
		_start_new_world(text if text != "" else _random_seed_text(), int(count_spin.value)))
	add_child(new_world_dialog)


func _random_seed_text() -> String:
	var r := RandomNumberGenerator.new()
	r.randomize()
	return "%06d" % r.randi_range(0, 999999)
