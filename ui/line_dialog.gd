## Choose what a production line makes. Shows, for each good your home can make, what it fetches
## at home and where it sells best with the vehicles you own.
extends AcceptDialog

signal chosen(index: int, good: String)

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

var _intro: RichTextLabel
var _list: VBoxContainer
var _index := -1


func _ready() -> void:
	ok_button_text = "Close"
	min_size = Vector2i(760, 420)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)
	_intro = Style.rich()
	_intro.custom_minimum_size.x = 720
	root.add_child(_intro)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	root.add_child(_list)


func open_for(game: RefCounted, index: int) -> void:
	_index = index
	var s: Dictionary = game.state
	var home: Dictionary = Economy.home(s)
	var line: Dictionary = home["lines"][index]
	var current := String(line["good"])
	title = "Line %d — what should it produce?" % (index + 1)
	var muted := Style.hex(Style.MUTED)
	if current == "":
		_intro.text = "Each line makes [b]%d lots a month[/b] (one every 3 days). The first choice is [b]free[/b].\n[color=#%s]Your home market pays 75%% of normal prices; selling elsewhere usually pays far more. Best markets below are for the vehicles you own today.[/color]" % [int(line["output"]), muted]
	else:
		_intro.text = "Line %d makes [b]%s[/b]. Switching costs [b]%s[/b] and the line stops for [b]%s[/b] while it is retooled." % [
			index + 1, current, Fmt.coins(Economy.retool_cost(line)), Style.days(Economy.retool_days(home))]

	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	for good in home["production_options"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var btn := Button.new()
		btn.text = good
		btn.custom_minimum_size.x = 120
		btn.disabled = good == current
		btn.pressed.connect(_on_pick.bind(good))
		row.add_child(btn)
		var info := Style.rich()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.custom_minimum_size.x = 580
		info.text = _good_info(s, good)
		row.add_child(info)
		_list.add_child(row)
	popup_centered(Vector2i(760, 0))


func _good_info(s: Dictionary, good: String) -> String:
	var muted := Style.hex(Style.MUTED)
	var home_pays := int(Market.sell_lot_prices(s, s["home_id"], good, 1)[0])
	var text := "Base %s · home pays %s" % [Fmt.coins(Data.base_price(good)), Fmt.coins(home_pays)]
	var shown := 0
	var best: PackedStringArray = []
	for opt in Transport.sell_options(s, good):
		if opt["reach"].is_empty():
			continue
		var r: Dictionary = opt["reach"][0]
		best.append("[color=#%s]%s[/color] in %s (%s %s)" % [
			Style.hex(Style.band_color(opt["band"])), Fmt.coins(opt["price"]), s["cities"][opt["city"]]["name"],
			String(Transport.label_of(r["type"])).to_lower(), Style.days(int(r["days"]))])
		shown += 1
		if shown == 2:
			break
	if best.is_empty():
		text += "\n[color=#%s]No city your vehicles reach pays more.[/color]" % muted
	else:
		text += "\n[color=#%s]Best:[/color] %s" % [muted, " · ".join(best)]
	return text


func _on_pick(good: String) -> void:
	hide()
	chosen.emit(_index, good)
