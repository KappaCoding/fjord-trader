## The player's economy: treasury, ledger, production lines, warehouses, food and growth, stages,
## infrastructure, running costs, the home market and net worth.
## See DESIGN.md batches 3–5 and 2c.
##
## Player cities carry:
##   owner          — "player"
##   stage          — 1..4
##   pop / pop_exact — population (int for display, float for continuous growth)
##   lines          — [{good, tier, base_value, upgrade_value, level, progress, retool_to, retool_until, waiting}]
##                    array order is input priority (DESIGN 5E)
##   warehouse      — {good: {lots, cost}}   cost = total cost basis in coins (DESIGN 4A)
##   reserves       — {good: lots} kept back from routes (DESIGN 5E)
##   infrastructure — {housing, harbor, roads, retooling: count}; infra_value — coins spent on it
##   food_acc, hours_without_food — food bookkeeping (DESIGN 3A)
extends RefCounted

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const News := preload("res://engine/news.gd")
const Fmt := preload("res://engine/format.gd")

const INCOME := ["sales"]
const EXPENSES := ["purchases", "trip_fees", "upkeep", "tax", "storage", "vehicles", "lines", "retooling", "infrastructure"]
const CATEGORY_LABELS := {
	"sales": "Sales",
	"purchases": "Purchases",
	"trip_fees": "Trip fees",
	"upkeep": "Vehicle upkeep",
	"tax": "Tax",
	"storage": "Storage fee",
	"vehicles": "Vehicles bought",
	"lines": "Production lines",
	"retooling": "Retooling",
	"infrastructure": "Infrastructure",
}


static func econ() -> Dictionary:
	return Data.balance()["economy"]


static func growth_cfg() -> Dictionary:
	return Data.balance()["growth"]


static func infra_cfg() -> Dictionary:
	return Data.balance()["infrastructure"]


static func max_stage() -> int:
	return Data.balance()["stages"].size()


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
	state["loans"] = []
	var home: Dictionary = state["cities"][state["home_id"]]
	home["owner"] = "player"
	home["stage"] = int(start["stage"])
	home["pop_exact"] = float(home["pop"])
	home["warehouse"] = {}
	home["reserves"] = {}
	home["infrastructure"] = {"housing": 0, "harbor": 0, "roads": 0, "retooling": 0}
	home["infra_value"] = 0
	home["housing_this_stage"] = 0
	home["want_acc"] = {}
	home["wants_stale"] = false
	home["food_acc"] = 0.0
	home["hours_without_food"] = 0
	home["lines"] = []
	for i in int(stage_info(int(home["stage"]))["max_lines"]):
		home["lines"].append(new_line(1, ""))


static func new_line(tier: int, good: String) -> Dictionary:
	return {
		"good": good,
		"tier": tier,
		"base_value": line_cost(tier),
		"upgrade_value": 0,
		"level": 0,
		"progress": 0,
		"retool_to": "",
		"retool_until": -1,
		"waiting": "",
	}


static func line_cost(tier: int) -> int:
	return int(econ()["line_cost_by_tier"][str(tier)])


static func line_output(line: Dictionary) -> int:
	return int(econ()["line_output_by_level"][int(line["level"])])


static func line_value(line: Dictionary) -> int:
	return int(line["base_value"]) + int(line["upgrade_value"])


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


# ------------------------------------------------------------------ reserves (DESIGN 5E)

static func reserve(city: Dictionary, good: String) -> int:
	return int(city["reserves"].get(good, 0))


static func set_reserve(state: Dictionary, city_id: String, good: String, lots: int) -> void:
	var city: Dictionary = state["cities"][city_id]
	if lots <= 0:
		city["reserves"].erase(good)
	else:
		city["reserves"][good] = lots


## Lots a route may take from the warehouse: stock above the reserve.
static func available_for_load(city: Dictionary, good: String) -> int:
	return maxi(0, stock(city["warehouse"], good) - reserve(city, good))


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


static func sum(values: Array) -> int:
	var total := 0
	for v in values:
		total += int(v)
	return total


# ------------------------------------------------------------------ what can be produced (DESIGN 3H)

## "" if the city can produce the good now, otherwise the reason it can't.
static func cannot_produce_reason(city: Dictionary, good: String) -> String:
	if Data.is_import_only(good):
		return "Import only — made overseas, you can't produce it"
	if Geo.is_raw(good) and not Geo.site_allows(city, good):
		if Geo.zones()["water_goods"].has(good):
			return "Needs a coast, fjord or river"
		return "Not found in the %s — comes from: %s" % [Geo.zone_label(city["zone"]), ", ".join(Geo.where_found(good))]
	var tier := Data.tier(good)
	if tier > int(city["stage"]):
		var info := stage_info(tier)
		return "Unlocks at Stage %d (%s, %s people)" % [tier, info["name"], Fmt.coins(int(info["min_pop"]))]
	return ""


static func producible_goods(city: Dictionary) -> Array:
	var out: Array = []
	for good in Data.good_ids():
		if cannot_produce_reason(city, good) == "":
			out.append(good)
	return out


# ------------------------------------------------------------------ lines

static func retool_days(city: Dictionary) -> int:
	var by: Array = econ()["retool_days_by_upgrades"]
	return int(by[mini(int(city["infrastructure"]["retooling"]), by.size() - 1)])


static func retool_cost(line: Dictionary) -> int:
	return int(round(int(line["base_value"]) * float(econ()["retool_cost_share"])))


## What switching a line to `good` would cost: {cost, tier_diff, retool, days}. Days 0 = instant.
static func line_change_cost(city: Dictionary, line: Dictionary, good: String) -> Dictionary:
	var new_tier := Data.tier(good)
	var tier_diff := maxi(0, line_cost(new_tier) - int(line["base_value"])) if new_tier > int(line["tier"]) else 0
	if String(line["good"]) == "":
		return {"cost": tier_diff, "tier_diff": tier_diff, "retool": 0, "days": 0}
	var r := retool_cost(line)
	return {"cost": tier_diff + r, "tier_diff": tier_diff, "retool": r, "days": retool_days(city)}


## Sets what a line produces (DESIGN 3I, 5D). Returns "" on success or an error message.
static func set_line(state: Dictionary, city_id: String, index: int, good: String) -> String:
	var city: Dictionary = state["cities"][city_id]
	if city.get("owner", "") != "player":
		return "That isn't your city."
	if index < 0 or index >= city["lines"].size():
		return "No such production line."
	var why := cannot_produce_reason(city, good)
	if why != "":
		return "%s: %s." % [good, why]
	var line: Dictionary = city["lines"][index]
	if String(line["retool_to"]) != "":
		return "This line is already switching to %s." % line["retool_to"]
	if String(line["good"]) == good:
		return "This line already produces %s." % good
	var c := line_change_cost(city, line, good)
	if not can_afford(state, int(c["cost"])):
		return "Not enough money: this costs %s." % Fmt.coins(c["cost"])
	if int(c["tier_diff"]) > 0:
		spend(state, "lines", int(c["tier_diff"]))
		line["tier"] = Data.tier(good)
		line["base_value"] = line_cost(Data.tier(good))
	if int(c["retool"]) > 0:
		spend(state, "retooling", int(c["retool"]))
	if int(c["days"]) == 0:
		line["good"] = good
		line["progress"] = 0
		line["waiting"] = ""
		News.add(state, "%s: a production line starts making %s." % [city["name"], good], News.KIND_CITY)
		return ""
	line["retool_to"] = good
	line["retool_until"] = int(state["time_hours"]) + int(c["days"]) * 24
	News.add(state, "%s: switching a line from %s to %s (%d days, %s)." % [
		city["name"], line["good"], good, int(c["days"]), Fmt.coins(c["cost"])], News.KIND_CITY)
	return ""


static func can_add_line(city: Dictionary) -> bool:
	return city["lines"].size() < int(stage_info(int(city["stage"]))["max_lines"])


## Buys a new line making `good`; it starts producing at once (DESIGN 3I).
static func add_line(state: Dictionary, city_id: String, good: String) -> String:
	var city: Dictionary = state["cities"][city_id]
	if not can_add_line(city):
		var nxt := int(city["stage"]) + 1
		if nxt > max_stage():
			return "%s has no free line slots." % city["name"]
		return "No free line slots. Stage %d allows %d lines." % [nxt, int(stage_info(nxt)["max_lines"])]
	var why := cannot_produce_reason(city, good)
	if why != "":
		return "%s: %s." % [good, why]
	var cost := line_cost(Data.tier(good))
	if not can_afford(state, cost):
		return "Not enough money: a Tier %d line costs %s." % [Data.tier(good), Fmt.coins(cost)]
	spend(state, "lines", cost)
	city["lines"].append(new_line(Data.tier(good), good))
	News.add(state, "%s: a new production line makes %s (%s)." % [city["name"], good, Fmt.coins(cost)], News.KIND_CITY)
	return ""


## Cost of the line's next output upgrade, or -1 when fully upgraded (DESIGN 3C).
static func upgrade_cost(line: Dictionary) -> int:
	var factors: Array = econ()["line_upgrade_cost_factor"]
	var level := int(line["level"])
	if level >= factors.size():
		return -1
	return int(line["base_value"]) * int(factors[level])


static func upgrade_line(state: Dictionary, city_id: String, index: int) -> String:
	var city: Dictionary = state["cities"][city_id]
	if index < 0 or index >= city["lines"].size():
		return "No such production line."
	var line: Dictionary = city["lines"][index]
	var cost := upgrade_cost(line)
	if cost < 0:
		return "This line is fully upgraded."
	if not can_afford(state, cost):
		return "Not enough money: the upgrade costs %s." % Fmt.coins(cost)
	spend(state, "lines", cost)
	line["upgrade_value"] = int(line["upgrade_value"]) + cost
	line["level"] = int(line["level"]) + 1
	News.add(state, "%s: line %d now makes %d lots a month." % [city["name"], index + 1, line_output(line)], News.KIND_CITY)
	return ""


## Moves a line up (-1) or down (+1) the priority order.
static func move_line(state: Dictionary, city_id: String, index: int, delta: int) -> void:
	var lines: Array = state["cities"][city_id]["lines"]
	var j := index + delta
	if index < 0 or index >= lines.size() or j < 0 or j >= lines.size():
		return
	var tmp: Dictionary = lines[index]
	lines[index] = lines[j]
	lines[j] = tmp


static func _inputs_text(inputs: Dictionary) -> String:
	var parts: PackedStringArray = []
	for g in Data.good_ids():
		if inputs.has(g):
			parts.append("%d %s" % [int(inputs[g]), g])
	return ", ".join(parts)


static func step_production(state: Dictionary, city: Dictionary, hours: int) -> void:
	var t := int(state["time_hours"])
	var hpm := Data.hours_per_month()
	var wh: Dictionary = city["warehouse"]
	for i in city["lines"].size():
		var line: Dictionary = city["lines"][i]
		if String(line["retool_to"]) != "":
			if t < int(line["retool_until"]):
				continue
			line["good"] = line["retool_to"]
			line["retool_to"] = ""
			line["retool_until"] = -1
			line["progress"] = 0
			line["waiting"] = ""
			News.add(state, "%s: a production line now makes %s." % [city["name"], line["good"]], News.KIND_CITY)
		var good := String(line["good"])
		if good == "":
			continue
		if int(line["progress"]) < hpm:
			line["progress"] = mini(hpm, int(line["progress"]) + line_output(line) * hours)
		while int(line["progress"]) >= hpm:
			var inputs: Dictionary = Data.good(good)["inputs"]
			var missing := false
			for g in inputs:
				if stock(wh, g) < int(inputs[g]):
					missing = true
			if missing:
				if String(line["waiting"]) == "":
					line["waiting"] = _inputs_text(inputs)
					News.add(state, "%s: the %s line is waiting for inputs (%s per lot)." % [
						city["name"], good, line["waiting"]], News.KIND_CITY)
				break
			for g in Data.good_ids():
				if inputs.has(g):
					remove_stock(wh, g, int(inputs[g]))
			add_stock(wh, good, 1, produced_lot_value(good))
			line["progress"] = int(line["progress"]) - hpm
			line["waiting"] = ""


## Hours until the line's next lot, or -1 if it isn't producing.
static func hours_to_next_lot(line: Dictionary) -> int:
	if String(line["good"]) == "" or String(line["retool_to"]) != "" or String(line["waiting"]) != "":
		return -1
	var remaining := Data.hours_per_month() - int(line["progress"])
	return int(ceil(float(remaining) / float(line_output(line))))


# ------------------------------------------------------------------ infrastructure (DESIGN 3G)

static func infra_count(city: Dictionary, kind: String) -> int:
	return int(city["infrastructure"].get(kind, 0))


## Housing can be built again and again (DESIGN 3K); the others once per stage.
static func infra_repeatable(kind: String) -> bool:
	return bool(infra_cfg()["types"][kind].get("repeatable", false))


## How many of this kind the city's stage allows in total (one per stage, from the type's first stage;
## no limit for repeatable kinds once their first stage is reached).
static func infra_allowed(city: Dictionary, kind: String) -> int:
	var first := int(infra_cfg()["types"][kind]["first_stage"])
	if int(city["stage"]) < first:
		return 0
	if infra_repeatable(kind):
		return 1 << 30
	return int(city["stage"]) - first + 1


## The next one's price at the city's stage. Housing gets dearer with each one built at the same stage
## (× housing_price_growth); a new stage starts again from that stage's price.
static func infra_cost(city: Dictionary, kind: String) -> int:
	var stage := str(int(city["stage"]))
	if kind == "retooling":
		return int(infra_cfg()["retooling_cost_by_stage"].get(stage, -1))
	var cost := float(infra_cfg()["cost_by_stage"][stage])
	if kind == "housing":
		cost *= pow(float(infra_cfg()["housing_price_growth"]), int(city.get("housing_this_stage", 0)))
	return int(round(cost))


static func build(state: Dictionary, city_id: String, kind: String) -> String:
	var city: Dictionary = state["cities"][city_id]
	if not infra_cfg()["types"].has(kind):
		return "Unknown building."
	var label: String = infra_cfg()["types"][kind]["label"]
	if infra_count(city, kind) >= infra_allowed(city, kind):
		var first := int(infra_cfg()["types"][kind]["first_stage"])
		if int(city["stage"]) < first:
			return "%s becomes available at Stage %d." % [label, first]
		return "%s is built for this stage. The next one comes with Stage %d." % [label, int(city["stage"]) + 1]
	var cost := infra_cost(city, kind)
	if not can_afford(state, cost):
		return "Not enough money: %s costs %s." % [label.to_lower(), Fmt.coins(cost)]
	spend(state, "infrastructure", cost)
	city["infra_value"] = int(city["infra_value"]) + cost
	city["infrastructure"][kind] = infra_count(city, kind) + 1
	var text := "%s: built %s (%s)." % [city["name"], label.to_lower(), Fmt.coins(cost)]
	if kind == "housing":
		city["housing_this_stage"] = int(city.get("housing_this_stage", 0)) + 1
		var before := int(city["pop"])
		city["pop_exact"] = float(city["pop_exact"]) * (1.0 + float(infra_cfg()["housing_pop_jump"]))
		city["pop"] = int(round(float(city["pop_exact"])))
		text += " %s new residents moved in." % Fmt.coins(int(city["pop"]) - before)
	News.add(state, text, News.KIND_CITY)
	_check_stage(state, city)
	return ""


## Speed multiplier for the player's wagons (roads at home).
static func wagon_speed_mult(state: Dictionary) -> float:
	return 1.0 + float(infra_cfg()["roads_wagon_speed"]) * infra_count(home(state), "roads")


## Fee multiplier for the player's sheltered-water and ocean trips (harbor at home).
static func water_fee_mult(state: Dictionary) -> float:
	return maxf(0.0, 1.0 - float(infra_cfg()["harbor_fee_cut"]) * infra_count(home(state), "harbor"))


# ------------------------------------------------------------------ food and growth (DESIGN 3A, 3B, 3F)

static func food_need_per_month(city: Dictionary) -> int:
	return int(ceil(float(city["pop"]) / float(growth_cfg()["pop_per_food_lot"])))


static func food_stock(city: Dictionary) -> int:
	var total := 0
	for g in growth_cfg()["food_goods"]:
		total += stock(city["warehouse"], g)
	return total


## Eats one lot of whichever food there is most of (Grain on a tie).
static func _eat_one(city: Dictionary) -> bool:
	var best := ""
	var best_n := 0
	for g in growth_cfg()["food_goods"]:
		var n := stock(city["warehouse"], g)
		if n > best_n:
			best = g
			best_n = n
	if best == "":
		return false
	remove_stock(city["warehouse"], best, 1)
	return true


# ------------------------------------------------------------------ your people's wants (DESIGN 3J)

## Growth bonus for each wanted good in stock at the city's stage (on top of the capped base growth).
static func want_bonus(city: Dictionary) -> float:
	return float(growth_cfg()["want_bonus_by_stage"].get(str(int(city["stage"])), 0.0))


## Lots of a wanted good the city uses up per month: a fixed value per person, so dear goods go slowly.
static func want_need_per_month(city: Dictionary, good: String) -> float:
	return float(city["pop"]) * float(growth_cfg()["want_coins_per_person_month"]) / float(Data.base_price(good))


## For every good some city sells: the fewest days from `city` to a seller, with any vehicle type the player's
## stage allows (base speed). Goods no such vehicle can fetch are left out.
static func reachable_sold_goods(state: Dictionary, city: Dictionary) -> Dictionary:
	var stage := int(city["stage"])
	var types: Dictionary = Data.balance()["vehicles"]["types"]
	var out := {}
	for id in state["city_order"]:
		var other: Dictionary = state["cities"][id]
		if id == city["id"] or other.get("owner", "") == "player":
			continue
		var best := -1
		for vtype in types:
			if int(types[vtype]["min_stage"]) > stage:
				continue
			var d := int(Geo.best_path(state, city["id"], id, types[vtype]["route"], vtype, 1.0)["days"])
			if d > 0 and (best < 0 or d < best):
				best = d
		if best > 0:
			for g in other["produces"]:
				if not out.has(g) or best < int(out[g]):
					out[g] = best
	return out


## What a player city's people can want: not food, not what its own land yields, at most one tier above its
## stage (import-only goods count as Tier 3). Its own tier is likeliest, and goods sold close by are strongly
## preferred: each step out (within want_reach_days[0], within [1], anywhere a vehicle reaches, nowhere)
## makes a good ten times less likely, so a far good is only wanted when too few near ones exist.
static func player_want_weights(state: Dictionary, city: Dictionary) -> Dictionary:
	var stage := int(city["stage"])
	var top := stage + int(growth_cfg()["want_tiers_above_stage"])
	var own_raw := Geo.raw_goods_for(city)
	var sold := reachable_sold_goods(state, city)
	var limits: Array = growth_cfg()["want_reach_days"]
	var w := {}
	for id in Data.good_ids():
		if Data.is_food(id) or own_raw.has(id):
			continue
		var t := Data.tier(id)
		if t == 0:
			t = 3
		if t > top:
			continue
		var weight := 3.0 if t == stage else (2.0 if t > stage else 1.0)
		var step := limits.size() + 1  # not sold where a vehicle reaches
		if sold.has(id):
			step = limits.size()
			for k in limits.size():
				if int(sold[id]) <= int(limits[k]):
					step = k
					break
		w[id] = weight * pow(0.1, step)
	return w


## Picks the player's home wants for its stage (new game, stage-up). Returns the news text.
static func reroll_player_wants(state: Dictionary, city: Dictionary, rng: RandomNumberGenerator) -> String:
	city["wants"] = []  # nothing is excluded as "the old wants"
	Market.rotate_wants(city, rng, player_want_weights(state, city))
	city["wants_stale"] = false
	var bonus := want_bonus(city) * 100.0
	return "Your people in %s want %s. Keep them in your warehouse for +%.1f%% growth a month each." % [
		city["name"], " and ".join(PackedStringArray(city["wants"])), bonus]


## Uses up wanted goods from the warehouse. When one runs out nothing is owed later.
static func _use_wants(city: Dictionary, hours: int) -> void:
	var hpm := float(Data.hours_per_month())
	var old: Dictionary = city.get("want_acc", {})
	var acc := {}
	for g in city["wants"]:
		var a := float(old.get(g, 0.0)) + want_need_per_month(city, g) * float(hours) / hpm
		while a >= 1.0:
			if stock(city["warehouse"], g) <= 0:
				a = 0.0
				break
			remove_stock(city["warehouse"], g, 1)
			a -= 1.0
		acc[g] = a
	city["want_acc"] = acc


static func treasury_threshold(city: Dictionary) -> int:
	return int(growth_cfg()["treasury_threshold_stage_1"]) * int(pow(10.0, float(int(city["stage"]) - 1)))


## The current growth rate per month and what makes it up.
## {rate, fed, starving, capped, parts: [[label, value]], missing: [[hint, value]]}
static func growth_breakdown(state: Dictionary, city: Dictionary) -> Dictionary:
	var g := growth_cfg()
	var parts: Array = []
	var missing: Array = []
	var stock_n := food_stock(city)
	if stock_n <= 0:
		var starving := int(city["hours_without_food"]) >= int(g["starving_after_days"]) * 24
		if starving:
			parts.append(["Starving: no food for %d+ days" % int(g["starving_after_days"]), -float(g["starving_decline"])])
		else:
			parts.append(["No Grain or Fish in stock — growth has stopped", 0.0])
		var r := -float(g["starving_decline"]) if starving else 0.0
		return {"rate": r, "base": r, "wants": 0.0, "fed": false, "starving": starving, "capped": false, "parts": parts,
			"missing": [["Get Grain or Fish into your warehouse", float(g["fed"])]], "missing_wants": []}
	parts.append(["Fed", float(g["fed"])])
	var need := food_need_per_month(city)
	var months := int(g["stock_months"])
	if stock_n >= need * months:
		parts.append(["%d+ months of food stored" % months, float(g["stock_bonus"])])
	else:
		missing.append(["Store %d months of food (%d lots)" % [months, need * months], float(g["stock_bonus"])])
	var threshold := treasury_threshold(city)
	if state["loans"].is_empty() and int(state["treasury"]) >= threshold:
		parts.append(["Treasury above %s, no loans" % Fmt.coins(threshold), float(g["treasury_bonus"])])
	else:
		missing.append(["Keep %s in the treasury, no loans" % Fmt.coins(threshold), float(g["treasury_bonus"])])
	for kind in ["housing", "harbor", "roads"]:
		var n := infra_count(city, kind)
		var label: String = infra_cfg()["types"][kind]["label"]
		if n > 0:
			parts.append(["%s ×%d" % [label, n] if n > 1 else label, float(g["infrastructure_bonus"]) * n])
		elif infra_allowed(city, kind) > 0:
			missing.append(["Build %s" % label.to_lower(), float(g["infrastructure_bonus"])])
	var goods: Array = g["food_goods"]
	var variety := true
	for f in goods:
		if stock(city["warehouse"], f) <= 0:
			variety = false
	if variety:
		parts.append(["Both %s" % " and ".join(PackedStringArray(goods)), float(g["variety_bonus"])])
	else:
		missing.append(["Stock both %s" % " and ".join(PackedStringArray(goods)), float(g["variety_bonus"])])
	var base := 0.0
	for p in parts:
		base += float(p[1])
	var cap := float(g["cap"])
	# Wanted goods come on top of the capped base (DESIGN 3J).
	var wants := 0.0
	var want_parts: Array = []
	var missing_wants: Array = []
	var bonus := want_bonus(city)
	for w in city.get("wants", []):
		if stock(city["warehouse"], w) > 0:
			want_parts.append(["%s for your people" % w, bonus])
			wants += bonus
		else:
			missing_wants.append(["Bring %s home" % w, bonus])
	return {"rate": minf(base, cap) + wants, "base": minf(base, cap), "wants": wants, "fed": true, "starving": false,
		"capped": base > cap, "parts": parts + want_parts, "missing": missing, "missing_wants": missing_wants}


static func step_food_growth(state: Dictionary, city: Dictionary, hours: int) -> void:
	var hpm := float(Data.hours_per_month())
	city["food_acc"] = float(city["food_acc"]) + float(food_need_per_month(city)) * float(hours) / hpm
	while float(city["food_acc"]) >= 1.0:
		if _eat_one(city):
			city["food_acc"] = float(city["food_acc"]) - 1.0
		else:
			city["food_acc"] = 1.0  # hungry people don't eat a backlog later
			break
	if food_stock(city) > 0:
		city["hours_without_food"] = 0
	else:
		city["hours_without_food"] = int(city["hours_without_food"]) + hours
	_use_wants(city, hours)
	var rate := float(growth_breakdown(state, city)["rate"])
	if rate != 0.0:
		city["pop_exact"] = float(city["pop_exact"]) * pow(1.0 + rate, float(hours) / hpm)
		city["pop"] = int(round(float(city["pop_exact"])))
	_check_stage(state, city)


static func _check_stage(state: Dictionary, city: Dictionary) -> void:
	while int(city["stage"]) < max_stage():
		var nxt := stage_info(int(city["stage"]) + 1)
		if int(city["pop"]) < int(nxt["min_pop"]):
			return
		city["stage"] = int(nxt["stage"])
		city["housing_this_stage"] = 0
		city["wants_stale"] = true  # the simulation picks finer wants for the new stage (it holds the RNG)
		News.add(state, "%s has grown into a %s (Stage %d)! Up to %d production lines and Tier %d goods are unlocked." % [
			city["name"], String(nxt["name"]).to_lower(), int(nxt["stage"]), int(nxt["max_lines"]), int(nxt["stage"])], News.KIND_CITY)


## {stage, name, min_pop, months} for the next stage; months = -1 if not growing. Empty at the top stage.
static func next_stage_eta(state: Dictionary, city: Dictionary) -> Dictionary:
	if int(city["stage"]) >= max_stage():
		return {}
	var nxt := stage_info(int(city["stage"]) + 1)
	var rate := float(growth_breakdown(state, city)["rate"])
	var months := -1.0
	if rate > 0.0:
		months = log(float(nxt["min_pop"]) / maxf(1.0, float(city["pop_exact"]))) / log(1.0 + rate)
	return {"stage": int(nxt["stage"]), "name": nxt["name"], "min_pop": int(nxt["min_pop"]), "months": months}


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


# ------------------------------------------------------------------ net worth and forecast

## DESIGN 4A. Loans arrive in Milestone 6.
static func net_worth(state: Dictionary) -> int:
	var total := int(state["treasury"])
	for id in player_city_ids(state):
		var c: Dictionary = state["cities"][id]
		total += inventory_value(c["warehouse"]) + int(c["infra_value"])
		for line in c["lines"]:
			total += line_value(line)
	for v in state["vehicles"]:
		total += int(v["value"]) + inventory_value(v["cargo"])
	return total


## `committed` is fees already certain to be charged (vehicles part-way through a journey).
static func forecast(state: Dictionary, committed := 0) -> Dictionary:
	var c := running_costs(state)
	var per_month := float(c["upkeep"]) + float(c["tax"]) + float(c["storage"])
	var per_day := per_month / float(Data.balance()["clock"]["days_per_month"])
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
		"committed_fees": committed,
		"runway_days": runway,
		"ledger_current": state["ledger"]["current"],
		"ledger_last": state["ledger"]["last"],
	}
