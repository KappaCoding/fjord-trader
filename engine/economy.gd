## The player's economy: treasury, ledger, production lines, warehouses, running costs,
## the home market and net worth. See DESIGN.md batches 3–5 and 2c.
##
## Player cities carry:
##   owner     — "player"
##   stage     — 1..4
##   lines     — [{good, value, output, progress, retool_to, retool_until}]
##   warehouse — {good: {lots, cost}}   cost = total cost basis in coins (DESIGN 4A)
extends RefCounted

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const News := preload("res://engine/news.gd")
const Fmt := preload("res://engine/format.gd")

const INCOME := ["sales"]
const EXPENSES := ["purchases", "trip_fees", "upkeep", "tax", "storage", "vehicles", "retooling"]
const CATEGORY_LABELS := {
	"sales": "Sales",
	"purchases": "Purchases",
	"trip_fees": "Trip fees",
	"upkeep": "Vehicle upkeep",
	"tax": "Tax",
	"storage": "Storage fee",
	"vehicles": "Vehicles bought",
	"retooling": "Retooling",
}


static func econ() -> Dictionary:
	return Data.balance()["economy"]


static func stage_info(stage: int) -> Dictionary:
	for s in Data.balance()["stages"]:
		if int(s["stage"]) == stage:
			return s
	return Data.balance()["stages"][0]


# ------------------------------------------------------------------ setup

static func init_player(state: Dictionary) -> void:
	var start: Dictionary = Data.balance()["start"]
	state["treasury"] = int(start["treasury"])
	state["accruals"] = {}
	state["ledger"] = {"current": _zero_ledger(), "last": _zero_ledger()}
	var home: Dictionary = state["cities"][state["home_id"]]
	home["owner"] = "player"
	home["stage"] = int(start["stage"])
	home["warehouse"] = {}
	home["lines"] = []
	for i in int(stage_info(int(home["stage"]))["max_lines"]):
		home["lines"].append(new_line(1))


static func new_line(tier: int) -> Dictionary:
	return {
		"good": "",
		"value": line_cost(tier),
		"output": int(econ()["line_output_per_month"]),
		"progress": 0,
		"retool_to": "",
		"retool_until": -1,
	}


static func line_cost(tier: int) -> int:
	return int(econ()["line_cost_by_tier"][str(tier)])


static func player_city_ids(state: Dictionary) -> Array:
	var out: Array = []
	for id in state["city_order"]:
		if state["cities"][id].get("owner", "") == "player":
			out.append(id)
	return out


static func home(state: Dictionary) -> Dictionary:
	return state["cities"][state["home_id"]]


# ------------------------------------------------------------------ stock containers
# A container is a warehouse or a vehicle's cargo: {good: {"lots": int, "cost": int}}.

static func stock(container: Dictionary, good: String) -> int:
	return int(container[good]["lots"]) if container.has(good) else 0


static func add_stock(container: Dictionary, good: String, lots: int, cost: int) -> void:
	if lots <= 0:
		return
	if not container.has(good):
		container[good] = {"lots": 0, "cost": 0}
	container[good]["lots"] = int(container[good]["lots"]) + lots
	container[good]["cost"] = int(container[good]["cost"]) + cost


## The cost basis that removing `lots` would take with it (average cost × lots; all of it when emptied).
static func cost_of(container: Dictionary, good: String, lots: int) -> int:
	var have := stock(container, good)
	lots = mini(lots, have)
	if lots <= 0:
		return 0
	var total := int(container[good]["cost"])
	if lots == have:
		return total
	return int(round(float(total) * float(lots) / float(have)))


## Removes up to `lots`; returns the cost basis removed.
static func remove_stock(container: Dictionary, good: String, lots: int) -> int:
	var have := stock(container, good)
	lots = mini(lots, have)
	if lots <= 0:
		return 0
	var removed := cost_of(container, good, lots)
	var entry: Dictionary = container[good]
	entry["lots"] = have - lots
	entry["cost"] = int(entry["cost"]) - removed
	if int(entry["lots"]) == 0:
		container.erase(good)
	return removed


static func avg_cost(container: Dictionary, good: String) -> int:
	var have := stock(container, good)
	return 0 if have == 0 else int(round(float(container[good]["cost"]) / float(have)))


static func inventory_value(container: Dictionary) -> int:
	var total := 0
	for good in container:
		total += int(container[good]["cost"])
	return total


static func total_lots(container: Dictionary) -> int:
	var total := 0
	for good in container:
		total += int(container[good]["lots"])
	return total


## Value a produced lot enters the warehouse at (DESIGN 4A: 0.75 × base).
static func produced_lot_value(good: String) -> int:
	return int(round(Data.base_price(good) * float(econ()["produced_goods_value_share"])))


# ------------------------------------------------------------------ money

static func _zero_ledger() -> Dictionary:
	var l := {}
	for c in INCOME + EXPENSES:
		l[c] = 0
	return l


static func earn(state: Dictionary, category: String, amount: int) -> void:
	state["treasury"] = int(state["treasury"]) + amount
	state["ledger"]["current"][category] = int(state["ledger"]["current"][category]) + amount


static func spend(state: Dictionary, category: String, amount: int) -> void:
	state["treasury"] = int(state["treasury"]) - amount
	state["ledger"]["current"][category] = int(state["ledger"]["current"][category]) + amount


static func can_afford(state: Dictionary, amount: int) -> bool:
	return int(state["treasury"]) >= amount


## Adds a fractional cost; whole coins are deducted as they accumulate (DESIGN 2b-C).
static func accrue(state: Dictionary, category: String, amount: float) -> void:
	var acc: Dictionary = state["accruals"]
	var v := float(acc.get(category, 0.0)) + amount
	var whole := int(floor(v))
	if whole > 0:
		spend(state, category, whole)
		v -= whole
	acc[category] = v


static func roll_ledger(state: Dictionary) -> void:
	state["ledger"]["last"] = state["ledger"]["current"]
	state["ledger"]["current"] = _zero_ledger()


# ------------------------------------------------------------------ production

static func step_production(state: Dictionary, city: Dictionary, hours: int) -> void:
	var t := int(state["time_hours"])
	var hpm := Data.hours_per_month()
	for line in city["lines"]:
		if String(line["retool_to"]) != "":
			if t < int(line["retool_until"]):
				continue
			line["good"] = line["retool_to"]
			line["retool_to"] = ""
			line["retool_until"] = -1
			line["progress"] = 0
			News.add(state, "%s: a production line now makes %s." % [city["name"], line["good"]], News.KIND_CITY)
		if String(line["good"]) == "":
			continue
		line["progress"] = int(line["progress"]) + int(line["output"]) * hours
		while int(line["progress"]) >= hpm:
			line["progress"] = int(line["progress"]) - hpm
			add_stock(city["warehouse"], line["good"], 1, produced_lot_value(line["good"]))


## Hours until the line's next lot, or -1 if it isn't producing.
static func hours_to_next_lot(line: Dictionary) -> int:
	if String(line["good"]) == "" or String(line["retool_to"]) != "" or int(line["output"]) <= 0:
		return -1
	var remaining := Data.hours_per_month() - int(line["progress"])
	return int(ceil(float(remaining) / float(line["output"])))


static func retool_cost(line: Dictionary) -> int:
	return int(round(int(line["value"]) * float(econ()["retool_cost_share"])))


static func retool_days(_city: Dictionary) -> int:
	return int(econ()["retool_days"])  # Retooling upgrades (5D) arrive with stages in Milestone 3.


## Sets what a line produces. Free and instant for an unassigned line, otherwise retooling (DESIGN 5D).
## Returns "" on success or an error message.
static func set_line(state: Dictionary, city_id: String, index: int, good: String) -> String:
	var city: Dictionary = state["cities"][city_id]
	if city.get("owner", "") != "player":
		return "That isn't your city."
	if index < 0 or index >= city["lines"].size():
		return "No such production line."
	var options: Array = city["production_options"]
	if not options.has(good):
		return "%s can't produce %s." % [city["name"], good]
	var line: Dictionary = city["lines"][index]
	if String(line["retool_to"]) != "":
		return "This line is already being retooled to %s." % line["retool_to"]
	if String(line["good"]) == good:
		return "This line already produces %s." % good
	if String(line["good"]) == "":
		line["good"] = good
		line["progress"] = 0
		News.add(state, "%s: a production line starts making %s." % [city["name"], good], News.KIND_CITY)
		return ""
	var cost := retool_cost(line)
	if not can_afford(state, cost):
		return "Not enough money: retooling costs %s." % Fmt.coins(cost)
	spend(state, "retooling", cost)
	line["retool_to"] = good
	line["retool_until"] = int(state["time_hours"]) + retool_days(city) * 24
	News.add(state, "%s: retooling a line from %s to %s (%d days, %s)." % [
		city["name"], line["good"], good, retool_days(city), Fmt.coins(cost)], News.KIND_CITY)
	return ""


# ------------------------------------------------------------------ running costs

## Current running costs per month: {upkeep, tax, storage} as floats.
## Tax with several player cities is decided when founding cities is reviewed (Milestone 8);
## for now the minimum is the sum of each player city's stage minimum.
static func running_costs(state: Dictionary) -> Dictionary:
	var upkeep := 0.0
	var share := float(Data.balance()["vehicles"]["upkeep_share_per_month"])
	for v in state["vehicles"]:
		upkeep += float(v["value"]) * share
	var tax_min := 0.0
	var stored := 0
	for id in player_city_ids(state):
		var c: Dictionary = state["cities"][id]
		tax_min += float(stage_info(int(c["stage"]))["tax_min_per_month"])
		stored += inventory_value(c["warehouse"])
	var tax := maxf(float(state["treasury"]) * float(econ()["tax_share_per_month"]), tax_min)
	var storage := float(stored) * float(econ()["storage_share_per_month"])
	return {"upkeep": upkeep, "tax": tax, "storage": storage}


static func step_costs(state: Dictionary, hours: int) -> void:
	var c := running_costs(state)
	var f := float(hours) / float(Data.hours_per_month())
	for key in ["upkeep", "tax", "storage"]:
		accrue(state, key, float(c[key]) * f)


# ------------------------------------------------------------------ home market

## Sells lots from the home warehouse to the home market, instantly.
static func sell_at_home(state: Dictionary, good: String, n: int) -> Dictionary:
	var home_id: String = state["home_id"]
	var wh: Dictionary = home(state)["warehouse"]
	if n <= 0:
		return {"error": "Choose how many lots to sell."}
	if stock(wh, good) < n:
		return {"error": "You only have %d lots of %s." % [stock(wh, good), good]}
	var revenue := sum(Market.sell_lot_prices(state, home_id, good, n))
	var cost := remove_stock(wh, good, n)
	Market.apply_sell(state, home_id, good, n)
	earn(state, "sales", revenue)
	News.add(state, "Sold %d %s at home for %s (%s against cost)." % [
		n, good, Fmt.coins(revenue), Fmt.signed(revenue - cost)], News.KIND_TRADE)
	return {"error": "", "revenue": revenue, "cost": cost}


static func sum(values: Array) -> int:
	var total := 0
	for v in values:
		total += int(v)
	return total


# ------------------------------------------------------------------ net worth and forecast

## DESIGN 4A. Loans arrive in Milestone 6; infrastructure in Milestone 3.
static func net_worth(state: Dictionary) -> int:
	var total := int(state["treasury"])
	for id in player_city_ids(state):
		var c: Dictionary = state["cities"][id]
		total += inventory_value(c["warehouse"])
		for line in c["lines"]:
			total += int(line["value"])
	for v in state["vehicles"]:
		total += int(v["value"]) + inventory_value(v["cargo"])
	return total


static func forecast(state: Dictionary) -> Dictionary:
	var c := running_costs(state)
	var per_month := float(c["upkeep"]) + float(c["tax"]) + float(c["storage"])
	var per_day := per_month / float(Data.balance()["clock"]["days_per_month"])
	var committed := 0
	for v in state["vehicles"]:
		var trip: Dictionary = v["trip"]
		if not trip.is_empty() and trip["phase"] == "out":
			committed += int(trip["fee_back"])
	var treasury := int(state["treasury"])
	var runway := -1
	if per_day > 0.0:
		runway = maxi(0, int(floor(float(treasury - committed) / per_day)))
	return {
		"upkeep": int(round(c["upkeep"])),
		"tax": int(round(c["tax"])),
		"storage": int(round(c["storage"])),
		"per_month": int(round(per_month)),
		"per_day": int(round(per_day)),
		"committed_return_fees": committed,
		"runway_days": runway,
		"ledger_current": state["ledger"]["current"],
		"ledger_last": state["ledger"]["last"],
	}
