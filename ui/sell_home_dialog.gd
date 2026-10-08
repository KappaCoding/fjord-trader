## Sell goods from the warehouse to your own home market, instantly.
extends ConfirmationDialog

signal sell(good: String, lots: int)

const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

var game: RefCounted
var _good := ""
var _spin: SpinBox
var _info: RichTextLabel


func _ready() -> void:
	ok_button_text = "Sell"
	min_size = Vector2i(460, 200)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	var row := HBoxContainer.new()
	row.add_child(Style.label("Lots to sell"))
	_spin = SpinBox.new()
	_spin.min_value = 1
	_spin.step = 1
	_spin.rounded = true
	_spin.value_changed.connect(func(_v): _update())
	row.add_child(_spin)
	root.add_child(row)
	_info = Style.rich()
	_info.custom_minimum_size.x = 420
	root.add_child(_info)
	confirmed.connect(func(): sell.emit(_good, int(_spin.value)))


func open_for(g: RefCounted, good: String) -> void:
	game = g
	_good = good
	var have := Economy.stock(Economy.home(game.state)["warehouse"], good)
	title = "Sell %s at home" % good
	_spin.max_value = maxi(1, have)
	_spin.value = have
	_update()
	popup_centered(Vector2i(460, 0))


func _update() -> void:
	if game == null:
		return
	var s: Dictionary = game.state
	var n := int(_spin.value)
	var wh: Dictionary = Economy.home(s)["warehouse"]
	var revenue := Economy.sum(Market.sell_lot_prices(s, s["home_id"], _good, n))
	var cost := Economy.cost_of(wh, _good, n)
	var profit := revenue - cost
	_info.text = "You receive [b]%s[/b]  ([color=#%s]%s[/color] against what it cost you).\n[color=#%s]Your home market pays 75%% of normal prices, and each lot sold lowers the price a little. Trips to other cities usually pay more.[/color]" % [
		Fmt.coins(revenue), Style.hex(Style.GOOD if profit >= 0 else Style.BAD), Fmt.signed(profit), Style.hex(Style.MUTED)]
