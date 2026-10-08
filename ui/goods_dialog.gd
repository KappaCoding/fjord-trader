## "What can I make?" — every good, whether your settlement can make it, why not, its inputs and best market.
## Also used to choose a line's good and to buy a new line.
extends AcceptDialog

signal line_chosen(index: int, good: String)
signal line_added(good: String)

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

const MODE_OVERVIEW := "overview"
const MODE_LINE := "line"
const MODE_ADD := "add"

var _intro: RichTextLabel
var _grid: GridContainer
var _mode := MODE_OVERVIEW
var _index := -1


func _ready() -> void:
	ok_button_text = "Close"
	min_size = Vector2i(1100, 760)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)
	_intro = Style.rich()
	_intro.custom_minimum_size.x = 1060
	root.add_child(_intro)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 560
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 6
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(_grid)


func open_overview(game: RefCounted) -> void:
	_open(game, MODE_OVERVIEW, -1)


func open_for_line(game: RefCounted, index: int) -> void:
	_open(game, MODE_LINE, index)


func open_add_line(game: RefCounted) -> void:
	_open(game, MODE_ADD, -1)


func _open(game: RefCounted, mode: String, index: int) -> void:
	_mode = mode
	_index = index
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)
	var muted := Style.hex(Style.MUTED)
	var stage := int(home["stage"])
	var prices: PackedStringArray = []
	for t in [1, 2, 3, 4]:
		prices.append("Tier %d %s" % [t, Fmt.coins(Economy.line_cost(t))])
	match mode:
		MODE_LINE:
			var line: Dictionary = home["lines"][index]
			if String(line["good"]) == "":
				title = "Line %d — what should it make?" % (index + 1)
				_intro.text = "Choose what line %d makes. The first choice is [b]free[/b]; a good above the line's tier (Tier %d) costs the price difference.\n[color=#%s]Line prices: %s.[/color]" % [
					index + 1, int(line["tier"]), muted, " · ".join(prices)]
			else:
				title = "Line %d — switch to another good" % (index + 1)
				_intro.text = "Line %d makes [b]%s[/b] (Tier %d line). Switching costs [b]%s[/b] (25%% of the line's price) and [b]%s[/b] without production. Moving up a tier also costs the price difference.\n[color=#%s]Line prices: %s.[/color]" % [
					index + 1, line["good"], int(line["tier"]), Fmt.coins(Economy.retool_cost(line)),
					Style.days(Economy.retool_days(home)), muted, " · ".join(prices)]
		MODE_ADD:
			title = "Add a production line"
			var maxl := int(Economy.stage_info(stage)["max_lines"])
			_intro.text = "You have [b]%d of %d[/b] lines. A new line costs its tier's price and starts producing at once.\n[color=#%s]%s.[/color]" % [
				home["lines"].size(), maxl, muted, " · ".join(prices)]
		_:
			title = "What can I make?"
			_intro.text = "Everything there is to make, and why your settlement can or can't make it yet. Raw goods depend on your land; processed goods can be made anywhere once their tier is unlocked, if you bring the inputs.\n[color=#%s]Stage %d unlocks Tier %d. Green prices: a city wants it and pays a premium.[/color]" % [muted, stage, stage]

	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_grid.columns = 6 if mode != MODE_OVERVIEW else 5
	var heads := ["Good", "Tier", "Can you make it?", "Inputs per lot", "Best market for your vehicles"]
	if mode != MODE_OVERVIEW:
		heads.append("")
	for h in heads:
		_grid.add_child(Style.label(h, Style.MUTED, 13))

	var order: Array = []
	for t in [1, 2, 3, 4, 0]:
		for good in Data.good_ids():
			if Data.tier(good) == t:
				order.append(good)
	for good in order:
		var why := Economy.cannot_produce_reason(home, good)
		var ok := why == ""
		_grid.add_child(Style.label(good, Color.WHITE if ok else Style.MUTED))
		_grid.add_child(Style.label("Import" if Data.is_import_only(good) else "T%d" % Data.tier(good), Style.MUTED))
		var status := Style.label("Yes" if ok else why, Style.GOOD if ok else Style.MUTED)
		status.custom_minimum_size.x = 340
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_grid.add_child(status)
		var inputs: Dictionary = Data.good(good)["inputs"]
		var parts: PackedStringArray = []
		for g in Data.good_ids():
			if inputs.has(g):
				parts.append("%d %s" % [int(inputs[g]), g])
		var in_label := Style.label(", ".join(parts) if not parts.is_empty() else "—", Color.WHITE if not parts.is_empty() else Style.MUTED)
		in_label.custom_minimum_size.x = 200
		in_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_grid.add_child(in_label)
		var market := Style.rich()
		market.custom_minimum_size.x = 300
		market.text = _best_market(s, good)
		_grid.add_child(market)
		if mode == MODE_OVERVIEW:
			continue
		var btn := Button.new()
		btn.custom_minimum_size.x = 210
		if mode == MODE_ADD:
			var cost := Economy.line_cost(maxi(1, Data.tier(good)))
			btn.text = "Add line · %s" % Fmt.coins(cost) if ok else "Not available"
			btn.disabled = not ok or not Economy.can_add_line(home) or int(s["treasury"]) < cost
			btn.pressed.connect(_on_add.bind(good))
		else:
			var line: Dictionary = home["lines"][_index]
			var current := String(line["good"])
			if good == current:
				btn.text = "Current"
				btn.disabled = true
			elif not ok:
				btn.text = "Not available"
				btn.disabled = true
				btn.tooltip_text = why
			else:
				var c := Economy.line_change_cost(home, line, good) if ok else {"cost": 0, "days": 0, "tier_diff": 0, "retool": 0}
				btn.text = ("Choose · free" if int(c["cost"]) == 0 else "Choose · %s" % Fmt.coins(c["cost"])) if current == "" else "Switch · %s" % Fmt.coins(c["cost"])
				btn.disabled = not ok or String(line["retool_to"]) != "" or int(s["treasury"]) < int(c["cost"])
				var tip: PackedStringArray = []
				if int(c["tier_diff"]) > 0:
					tip.append("Tier difference %s" % Fmt.coins(c["tier_diff"]))
				if int(c["retool"]) > 0:
					tip.append("retooling %s" % Fmt.coins(c["retool"]))
				if int(c["days"]) > 0:
					tip.append("%s without production" % Style.days(int(c["days"])))
				btn.tooltip_text = ", ".join(tip) if not tip.is_empty() else "Starts at once"
				btn.pressed.connect(_on_choose.bind(good))
		_grid.add_child(btn)
	popup_centered(Vector2i(1100, 760))


func _best_market(s: Dictionary, good: String) -> String:
	for opt in Transport.sell_options(s, good):
		if opt["reach"].is_empty():
			continue
		var r: Dictionary = opt["reach"][0]
		return "[color=#%s]%s[/color] in %s [color=#%s](%s %s)[/color]" % [
			Style.hex(Style.band_color(opt["band"])), Fmt.coins(opt["price"]), s["cities"][opt["city"]]["name"],
			Style.hex(Style.MUTED), String(Transport.label_of(r["type"])).to_lower(), Style.days(int(r["days"]))]
	return "[color=#%s]no city your vehicles reach[/color]" % Style.hex(Style.MUTED)


func _on_choose(good: String) -> void:
	hide()
	line_chosen.emit(_index, good)


func _on_add(good: String) -> void:
	hide()
	line_added.emit(good)
