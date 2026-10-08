## The forecast panel (DESIGN 2b-C): running costs right now, what is already committed,
## how long the money lasts, and this month's and last month's books.
extends HBoxContainer

const Economy := preload("res://engine/economy.gd")
const Fmt := preload("res://engine/format.gd")
const Style := preload("res://ui/style.gd")

var game: RefCounted
var _costs: RichTextLabel
var _books: GridContainer
var _book_cells := {}


func _ready() -> void:
	add_theme_constant_override("separation", 40)
	_costs = Style.rich()
	_costs.custom_minimum_size.x = 420
	add_child(_costs)

	_books = GridContainer.new()
	_books.columns = 3
	_books.add_theme_constant_override("h_separation", 24)
	_books.add_theme_constant_override("v_separation", 1)
	add_child(_books)
	for h in ["", "This month", "Last month"]:
		_books.add_child(Style.right(Style.label(h, Style.MUTED, 13)) if h != "" else Style.label(""))
	for cat in Economy.INCOME + Economy.EXPENSES + ["net"]:
		var cat_name: String = "Net" if cat == "net" else Economy.CATEGORY_LABELS[cat]
		_books.add_child(Style.label(cat_name, Color.WHITE if cat == "net" else Style.MUTED, 13))
		var cur := Style.right(Style.label("", Color.WHITE, 13))
		cur.custom_minimum_size.x = 110
		var last := Style.right(Style.label("", Color.WHITE, 13))
		last.custom_minimum_size.x = 110
		_books.add_child(cur)
		_books.add_child(last)
		_book_cells[cat] = [cur, last]


func refresh() -> void:
	if game == null:
		return
	var f: Dictionary = game.forecast()
	var muted := Style.hex(Style.MUTED)
	var lines: PackedStringArray = []
	lines.append("[b]Running costs right now[/b]  [color=#%s](per month, charged continuously)[/color]" % muted)
	lines.append("Vehicle upkeep  %s   ·   Tax  %s   ·   Storage  %s" % [Fmt.coins(f["upkeep"]), Fmt.coins(f["tax"]), Fmt.coins(f["storage"])])
	lines.append("Total  [b]%s / month[/b]  ≈ %s / day" % [Fmt.coins(f["per_month"]), Fmt.coins(f["per_day"])])
	if int(f["committed_return_fees"]) > 0:
		lines.append("Already committed: %s in return-trip fees" % Fmt.coins(f["committed_return_fees"]))
	var runway := int(f["runway_days"])
	if runway >= 0:
		var col := Style.GOOD if runway > 90 else (Style.WARN if runway > 30 else Style.BAD)
		lines.append("[color=#%s]Without any income, your money lasts about %s.[/color]" % [Style.hex(col), Style.days(runway)])
	lines.append("[color=#%s]Tax is 1%% of your treasury per month, never less than your stage minimum. Storage is 0.5%% of the warehouse's value.[/color]" % muted)
	_costs.text = "\n".join(lines)

	var cur: Dictionary = f["ledger_current"]
	var last: Dictionary = f["ledger_last"]
	var net_cur := 0
	var net_last := 0
	for cat in Economy.INCOME + Economy.EXPENSES:
		var sign := 1 if cat in Economy.INCOME else -1
		net_cur += sign * int(cur[cat])
		net_last += sign * int(last[cat])
		_set_cell(_book_cells[cat][0], sign * int(cur[cat]))
		_set_cell(_book_cells[cat][1], sign * int(last[cat]))
	_set_cell(_book_cells["net"][0], net_cur)
	_set_cell(_book_cells["net"][1], net_last)


func _set_cell(l: Label, value: int) -> void:
	l.text = Fmt.signed(value) if value != 0 else "—"
	l.add_theme_color_override("font_color", Style.GOOD if value > 0 else (Style.BAD if value < 0 else Style.MUTED))
