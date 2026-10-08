## Vehicles and trips. See DESIGN.md 2D, 5B, 5C and 2c (trading in real time).
##
## A vehicle: {id, name, type, capacity, value, location, cargo, trip}
##   location — city id while parked, "" while travelling
##   cargo    — stock container {good: {lots, cost}}
##   trip     — {} when idle, otherwise:
##     {dest, path, hop_days, days, buy, phase ("out"|"back"), leg_start, leg_end, fee_back, result}
extends RefCounted

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const News := preload("res://engine/news.gd")
const Fmt := preload("res://engine/format.gd")

const ROUTE_WORDS := {"land": "road", "sheltered": "sheltered water", "ocean": "open sea"}


static func types() -> Dictionary:
	return Data.balance()["vehicles"]["types"]


static func type_order() -> Array:
	return Data.balance()["vehicles"]["order"]


static func type_info(vtype: String) -> Dictionary:
	return types()[vtype]


static func route_of(vtype: String) -> String:
	return type_info(vtype)["route"]


static func label_of(vtype: String) -> String:
	return type_info(vtype)["label"]


# ------------------------------------------------------------------ fleet

static func init_fleet(state: Dictionary) -> void:
	state["vehicles"] = []
	state["vehicle_counter"] = {}
	for vtype in Data.balance()["start"]["vehicles"]:
		state["vehicles"].append(_new_vehicle(state, vtype))


static func _new_vehicle(state: Dictionary, vtype: String) -> Dictionary:
	var counter: Dictionary = state["vehicle_counter"]
	counter[vtype] = int(counter.get(vtype, 0)) + 1
	var info := type_info(vtype)
	return {
		"id": "%s-%d" % [vtype, counter[vtype]],
		"name": "%s %d" % [info["label"], counter[vtype]],
		"type": vtype,
		"capacity": int(info["capacity"]),
		"value": int(info["price"]),
		"location": state["home_id"],
		"cargo": {},
		"trip": {},
	}


## Whether the player's home stage allows buying this vehicle type (DESIGN 5C).
static func can_buy_type(state: Dictionary, vtype: String) -> bool:
	return int(Economy.home(state)["stage"]) >= int(type_info(vtype)["min_stage"])


## Returns "" on success or an error message.
static func buy_vehicle(state: Dictionary, vtype: String) -> String:
	if not types().has(vtype):
		return "Unknown vehicle type."
	var info := type_info(vtype)
	if not can_buy_type(state, vtype):
		return "%ss become available at Stage %d." % [info["label"], int(info["min_stage"])]
	var price := int(info["price"])
	if not Economy.can_afford(state, price):
		return "Not enough money: a %s costs %s." % [String(info["label"]).to_lower(), Fmt.coins(price)]
	Economy.spend(state, "vehicles", price)
	var v := _new_vehicle(state, vtype)
	state["vehicles"].append(v)
	News.add(state, "Bought %s for %s." % [v["name"], Fmt.coins(price)], News.KIND_TRADE)
	return ""


static func vehicle(state: Dictionary, id: String) -> Dictionary:
	for v in state["vehicles"]:
		if v["id"] == id:
			return v
	return {}


static func is_idle_at_home(state: Dictionary, v: Dictionary) -> bool:
	return v["trip"].is_empty() and v["location"] == state["home_id"]


static func idle_vehicles(state: Dictionary) -> Array:
	var out: Array = []
	for v in state["vehicles"]:
		if is_idle_at_home(state, v):
			out.append(v)
	return out


# ------------------------------------------------------------------ reach

## Fastest way for a vehicle type from one city to another: {"days", "stops", "hop_days"}.
static func path_for(state: Dictionary, from_id: String, to_id: String, vtype: String) -> Dictionary:
	var p := Geo.best_path(state, from_id, to_id, route_of(vtype), vtype)
	var hops: Array = []
	var stops: Array = p["stops"]
	for i in range(1, stops.size()):
		hops.append(Geo.travel_days(state, stops[i - 1], stops[i], route_of(vtype), vtype))
	p["hop_days"] = hops
	return p


## Every city a vehicle type can reach from `from_id`, nearest first: [{city, days, stops}].
static func reachable(state: Dictionary, from_id: String, vtype: String) -> Array:
	var out: Array = []
	for id in state["city_order"]:
		if id == from_id:
			continue
		var p := path_for(state, from_id, id, vtype)
		if int(p["days"]) > 0:
			out.append({"city": id, "days": int(p["days"]), "stops": p["stops"]})
	out.sort_custom(func(a, b): return a["days"] < b["days"] or (a["days"] == b["days"] and a["city"] < b["city"]))
	return out


static func trip_fee(vtype: String, days: int) -> int:
	var per_month := float(type_info(vtype)["fee_per_month_of_travel"])
	return int(round(per_month * float(days) / float(Data.balance()["clock"]["days_per_month"])))


## Where each city's goods can be sold, best price first, with how your vehicles get there.
## [{city, price (first lot paid to you), band, reach: [{type, days}]}] — reach is empty if no vehicle you
## own can get there.
static func sell_options(state: Dictionary, good: String) -> Array:
	var home_id: String = state["home_id"]
	var owned := {}
	for v in state["vehicles"]:
		owned[v["type"]] = true
	var out: Array = []
	for id in state["city_order"]:
		if id == home_id:
			continue
		var reach: Array = []
		for vtype in type_order():
			if owned.has(vtype):
				var p := path_for(state, home_id, id, vtype)
				if int(p["days"]) > 0:
					reach.append({"type": vtype, "days": int(p["days"])})
		out.append({
			"city": id,
			"price": int(Market.sell_lot_prices(state, id, good, 1)[0]),
			"band": state["cities"][id]["market"][good]["band"],
			"reach": reach,
		})
	out.sort_custom(func(a, b): return a["price"] > b["price"])
	return out


# ------------------------------------------------------------------ trips

## Checks and estimates a trip without changing anything. `sell` and `buy` map good -> lots.
## Returns {errors, warnings, days, stops, fee_out, fee_back, arrive_t, home_t, sell_lines, buy_lines,
## sell_total, sell_profit, buy_total, cargo_out, cargo_back, capacity, net}.
static func plan(state: Dictionary, vehicle_id: String, dest: String, sell: Dictionary, buy: Dictionary) -> Dictionary:
	var r := {
		"errors": [], "warnings": [], "days": -1, "stops": [], "fee_out": 0, "fee_back": 0,
		"arrive_t": -1, "home_t": -1, "sell_lines": [], "buy_lines": [], "sell_total": 0,
		"sell_profit": 0, "buy_total": 0, "cargo_out": 0, "cargo_back": 0, "capacity": 0, "net": 0,
	}
	var v := vehicle(state, vehicle_id)
	if v.is_empty():
		r["errors"].append("Choose a vehicle.")
		return r
	r["capacity"] = int(v["capacity"])
	var home_id: String = state["home_id"]
	if not is_idle_at_home(state, v):
		r["errors"].append("%s is away on a trip." % v["name"])
	if not state["cities"].has(dest) or dest == home_id:
		r["errors"].append("Choose a destination.")
		return r
	var dest_name: String = state["cities"][dest]["name"]
	var path := path_for(state, home_id, dest, v["type"])
	var days := int(path["days"])
	if days <= 0:
		r["errors"].append("%s can't reach %s: there is no %s route." % [v["name"], dest_name, ROUTE_WORDS[route_of(v["type"])]])
		return r
	var t := int(state["time_hours"])
	r["days"] = days
	r["stops"] = path["stops"]
	r["fee_out"] = trip_fee(v["type"], days)
	r["fee_back"] = trip_fee(v["type"], days)
	r["arrive_t"] = t + days * 24
	r["home_t"] = t + 2 * days * 24

	var wh: Dictionary = Economy.home(state)["warehouse"]
	for good in Data.good_ids():
		var n := int(sell.get(good, 0))
		if n <= 0:
			continue
		var have := Economy.stock(wh, good)
		if n > have:
			r["errors"].append("You only have %d lots of %s." % [have, good])
			n = have
		var revenue := Economy.sum(Market.sell_lot_prices(state, dest, good, n))
		var cost := Economy.cost_of(wh, good, n)
		r["sell_lines"].append({"good": good, "lots": n, "revenue": revenue, "cost": cost, "profit": revenue - cost})
		r["sell_total"] = int(r["sell_total"]) + revenue
		r["sell_profit"] = int(r["sell_profit"]) + revenue - cost
		r["cargo_out"] = int(r["cargo_out"]) + n
	for good in Data.good_ids():
		var n := int(buy.get(good, 0))
		if n <= 0:
			continue
		if not Market.city_sells(state, dest, good):
			r["errors"].append("%s doesn't sell %s." % [dest_name, good])
			continue
		var cost := Economy.sum(Market.buy_lot_prices(state, dest, good, n))
		r["buy_lines"].append({"good": good, "lots": n, "cost": cost})
		r["buy_total"] = int(r["buy_total"]) + cost
		r["cargo_back"] = int(r["cargo_back"]) + n

	if int(r["cargo_out"]) > int(v["capacity"]):
		r["errors"].append("Too much cargo: %d lots, but %s carries %d." % [r["cargo_out"], v["name"], v["capacity"]])
	if int(r["cargo_back"]) > int(v["capacity"]):
		r["errors"].append("Too much to buy: %d lots, but %s carries %d." % [r["cargo_back"], v["name"], v["capacity"]])
	if int(r["cargo_out"]) == 0 and int(r["cargo_back"]) == 0:
		r["errors"].append("Load something to sell or choose something to buy.")
	if not Economy.can_afford(state, int(r["fee_out"])):
		r["errors"].append("Not enough money for the trip fee (%s)." % Fmt.coins(r["fee_out"]))
	var cash_on_arrival := int(state["treasury"]) - int(r["fee_out"]) + int(r["sell_total"])
	if int(r["buy_total"]) > cash_on_arrival:
		r["warnings"].append("You may not be able to pay for everything; on arrival the vehicle buys what it can afford.")
	r["net"] = int(r["sell_total"]) - int(r["buy_total"]) - int(r["fee_out"]) - int(r["fee_back"])
	return r


## Sends a vehicle on a trip. Returns the plan; check plan["errors"].
static func send(state: Dictionary, vehicle_id: String, dest: String, sell: Dictionary, buy: Dictionary) -> Dictionary:
	var p := plan(state, vehicle_id, dest, sell, buy)
	if not p["errors"].is_empty():
		return p
	var v := vehicle(state, vehicle_id)
	var wh: Dictionary = Economy.home(state)["warehouse"]
	var loaded: Array = []
	for line in p["sell_lines"]:
		var cost := Economy.remove_stock(wh, line["good"], line["lots"])
		Economy.add_stock(v["cargo"], line["good"], line["lots"], cost)
		loaded.append([line["good"], line["lots"]])
	var to_buy := {}
	for line in p["buy_lines"]:
		to_buy[line["good"]] = int(line["lots"])
	Economy.spend(state, "trip_fees", int(p["fee_out"]))
	var t := int(state["time_hours"])
	var path := path_for(state, state["home_id"], dest, v["type"])
	v["location"] = ""
	v["trip"] = {
		"dest": dest,
		"path": path["stops"],
		"hop_days": path["hop_days"],
		"days": int(p["days"]),
		"buy": to_buy,
		"phase": "out",
		"leg_start": t,
		"leg_end": t + int(p["days"]) * 24,
		"fee_back": int(p["fee_back"]),
		"result": {},
	}
	var cargo_text := Fmt.lots_list(loaded) if not loaded.is_empty() else "no cargo"
	News.add(state, "%s left for %s (%d days) with %s." % [
		v["name"], state["cities"][dest]["name"], p["days"], cargo_text], News.KIND_TRADE)
	return p


static func step_vehicles(state: Dictionary) -> void:
	var t := int(state["time_hours"])
	for v in state["vehicles"]:
		var trip: Dictionary = v["trip"]
		if trip.is_empty() or t < int(trip["leg_end"]):
			continue
		if trip["phase"] == "out":
			_arrive_abroad(state, v)
		else:
			_arrive_home(state, v)


static func _arrive_abroad(state: Dictionary, v: Dictionary) -> void:
	var trip: Dictionary = v["trip"]
	var dest: String = trip["dest"]
	var dest_name: String = state["cities"][dest]["name"]
	var sold: Array = []
	var sales := 0
	var sold_cost := 0
	for good in Data.good_ids():
		var n := Economy.stock(v["cargo"], good)
		if n <= 0:
			continue
		var revenue := Economy.sum(Market.sell_lot_prices(state, dest, good, n))
		sold_cost += Economy.remove_stock(v["cargo"], good, n)
		Market.apply_sell(state, dest, good, n)
		Economy.earn(state, "sales", revenue)
		sales += revenue
		sold.append([good, n])

	var bought: Array = []
	var short: Array = []
	var purchases := 0
	for good in Data.good_ids():
		var wanted := int(trip["buy"].get(good, 0))
		if wanted <= 0:
			continue
		var prices := Market.buy_lot_prices(state, dest, good, wanted)
		var cash := int(state["treasury"])
		var k := 0
		var paid := 0
		for price in prices:
			if cash < int(price):
				break
			cash -= int(price)
			paid += int(price)
			k += 1
		if k > 0:
			Economy.spend(state, "purchases", paid)
			Market.apply_buy(state, dest, good, k)
			Economy.add_stock(v["cargo"], good, k, paid)
			purchases += paid
			bought.append([good, k])
		if k < wanted:
			short.append("%d of %d %s" % [k, wanted, good])

	var parts: PackedStringArray = []
	if not sold.is_empty():
		parts.append("sold %s for %s (%s against cost)" % [Fmt.lots_list(sold), Fmt.coins(sales), Fmt.signed(sales - sold_cost)])
	if not bought.is_empty():
		parts.append("bought %s for %s" % [Fmt.lots_list(bought), Fmt.coins(purchases)])
	if parts.is_empty():
		parts.append("traded nothing")
	var text := "%s in %s: %s." % [v["name"], dest_name, " and ".join(parts)]
	if not short.is_empty():
		text += " Couldn't afford everything: got %s." % ", ".join(PackedStringArray(short))
	News.add(state, text, News.KIND_TRADE)

	trip["result"] = {"sales": sales, "sales_profit": sales - sold_cost, "purchases": purchases}
	Economy.spend(state, "trip_fees", int(trip["fee_back"]))
	var t := int(state["time_hours"])
	trip["phase"] = "back"
	trip["leg_start"] = t
	trip["leg_end"] = t + int(trip["days"]) * 24


static func _arrive_home(state: Dictionary, v: Dictionary) -> void:
	var wh: Dictionary = Economy.home(state)["warehouse"]
	var unloaded: Array = []
	for good in Data.good_ids():
		var n := Economy.stock(v["cargo"], good)
		if n <= 0:
			continue
		var cost := Economy.remove_stock(v["cargo"], good, n)
		Economy.add_stock(wh, good, n, cost)
		unloaded.append([good, n])
	var home_name: String = Economy.home(state)["name"]
	if unloaded.is_empty():
		News.add(state, "%s is back in %s." % [v["name"], home_name], News.KIND_TRADE)
	else:
		News.add(state, "%s is back in %s with %s." % [v["name"], home_name, Fmt.lots_list(unloaded)], News.KIND_TRADE)
	v["trip"] = {}
	v["location"] = state["home_id"]


## Where a travelling vehicle is: {"stops": [city ids in travel order], "hop_days": [...], "elapsed_days": float}.
## Empty when the vehicle is parked.
static func trip_progress(state: Dictionary, v: Dictionary) -> Dictionary:
	var trip: Dictionary = v["trip"]
	if trip.is_empty():
		return {}
	var stops: Array = trip["path"].duplicate()
	var hops: Array = trip["hop_days"].duplicate()
	if trip["phase"] == "back":
		stops.reverse()
		hops.reverse()
	var elapsed := float(int(state["time_hours"]) - int(trip["leg_start"])) / 24.0
	return {"stops": stops, "hop_days": hops, "elapsed_days": clampf(elapsed, 0.0, float(trip["days"]))}
