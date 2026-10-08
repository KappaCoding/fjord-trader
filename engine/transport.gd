## Vehicles and routes. See DESIGN.md 2D, 5B, 5C, 2c and 2c-F (multi-stop routes).
##
## A vehicle: {id, name, type, capacity, value, location, cargo, route, leg, loop, stats, stop_requested, last_route}
##   location — city id while parked, "" while travelling
##   cargo    — stock container {good: {lots, cost}}
##   route    — {} when idle, otherwise the route it runs (see below)
##   leg      — {} when parked, otherwise {from, to, path, hop_days, days, start, end, next}
##              next = index of the stop being travelled to, or -1 when heading home
##   loop     — this loop's books {n, sales, sold_cost, purchases, fees}
##   stats    — {loops, last_cash, last_profit, total_profit}
##
## A route: {load: {good: lots}, stops: [{city, sell: {good: {lots, min}}, buy: {good: {lots, max}}}], repeat}
##   sell lots -1 = everything of that good on board; min / max = price limit per lot, 0 = none.
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
		"route": {},
		"leg": {},
		"loop": {},
		"stats": {"loops": 0, "last_cash": 0, "last_profit": 0, "total_profit": 0},
		"stop_requested": false,
		"last_route": {},
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
	return v["route"].is_empty() and v["leg"].is_empty() and v["location"] == state["home_id"]


static func idle_vehicles(state: Dictionary) -> Array:
	var out: Array = []
	for v in state["vehicles"]:
		if is_idle_at_home(state, v):
			out.append(v)
	return out


# ------------------------------------------------------------------ reach and fees

## The player's speed bonus for a vehicle type (roads speed up wagons, DESIGN 3G).
static func speed_mult(state: Dictionary, vtype: String) -> float:
	return Economy.wagon_speed_mult(state) if route_of(vtype) == "land" else 1.0


## Fastest way for a vehicle type between two cities: {"days", "stops", "hop_days"}.
static func path_for(state: Dictionary, from_id: String, to_id: String, vtype: String) -> Dictionary:
	var mult := speed_mult(state, vtype)
	var p := Geo.best_path(state, from_id, to_id, route_of(vtype), vtype, mult)
	var hops: Array = []
	var stops: Array = p["stops"]
	for i in range(1, stops.size()):
		hops.append(Geo.travel_days(state, stops[i - 1], stops[i], route_of(vtype), vtype, mult))
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


## Fee for one leg (DESIGN 2c-C), less the harbor discount on water (DESIGN 3G).
static func trip_fee(state: Dictionary, vtype: String, days: int) -> int:
	var per_month := float(type_info(vtype)["fee_per_month_of_travel"])
	var fee := per_month * float(days) / float(Data.balance()["clock"]["days_per_month"])
	if route_of(vtype) != "land":
		fee *= Economy.water_fee_mult(state)
	return int(round(fee))


## Where a good sells best, best price first, with how your vehicles get there.
## [{city, price (first lot paid to you), band, reach: [{type, days}]}]
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


# ------------------------------------------------------------------ routes

## A clean copy of a route: integer quantities, zero entries dropped.
static func normalize_route(route: Dictionary) -> Dictionary:
	var to_load := {}
	for g in route.get("load", {}):
		if int(route["load"][g]) > 0:
			to_load[g] = int(route["load"][g])
	var stops: Array = []
	for st in route.get("stops", []):
		var sell := {}
		for g in st.get("sell", {}):
			var e: Dictionary = st["sell"][g]
			if int(e.get("lots", 0)) != 0:
				sell[g] = {"lots": int(e["lots"]), "min": maxi(0, int(e.get("min", 0)))}
		var buy := {}
		for g in st.get("buy", {}):
			var e: Dictionary = st["buy"][g]
			if int(e.get("lots", 0)) > 0:
				buy[g] = {"lots": int(e["lots"]), "max": maxi(0, int(e.get("max", 0)))}
		stops.append({"city": String(st.get("city", "")), "sell": sell, "buy": buy})
	return {"load": to_load, "stops": stops, "repeat": bool(route.get("repeat", false))}


static func route_names(state: Dictionary, route: Dictionary) -> String:
	var names: PackedStringArray = []
	for st in route.get("stops", []):
		if state["cities"].has(st["city"]):
			names.append(state["cities"][st["city"]]["name"])
	return " → ".join(names)


## Checks and estimates a route without changing anything (prices as of now).
## {errors, warnings, legs: [{from, to, days, fee, stops}], stops: [{city, onboard, sells, buys}],
##  days, fees, sales, sales_profit, purchases, cash, profit, load_lots, first_arrival_t, home_t, full_path, capacity}
static func plan_route(state: Dictionary, vehicle_id: String, route_in: Dictionary) -> Dictionary:
	var route := normalize_route(route_in)
	var r := {
		"errors": [], "warnings": [], "legs": [], "stops": [], "days": 0, "fees": 0, "sales": 0,
		"sales_profit": 0, "purchases": 0, "cash": 0, "profit": 0, "load_lots": 0,
		"first_arrival_t": -1, "home_t": -1, "full_path": [], "capacity": 0,
	}
	var v := vehicle(state, vehicle_id)
	if v.is_empty():
		r["errors"].append("Choose a vehicle.")
		return r
	var cap := int(v["capacity"])
	r["capacity"] = cap
	var home_id: String = state["home_id"]
	var home: Dictionary = Economy.home(state)
	if not is_idle_at_home(state, v):
		r["errors"].append("%s is busy." % v["name"])
	var stops: Array = route["stops"]
	if stops.is_empty():
		r["errors"].append("Add at least one stop.")
		return r
	for i in stops.size():
		var c: String = stops[i]["city"]
		if not state["cities"].has(c) or c == home_id:
			r["errors"].append("Stop %d: choose a city other than home." % (i + 1))
			return r
		if i > 0 and c == stops[i - 1]["city"]:
			r["errors"].append("Stop %d is the same city as the stop before it." % (i + 1))

	# Legs: home → stops → home
	var seq: Array = [home_id]
	for st in stops:
		seq.append(st["city"])
	seq.append(home_id)
	var full: Array = [home_id]
	for i in range(1, seq.size()):
		var p := path_for(state, seq[i - 1], seq[i], v["type"])
		var days := int(p["days"])
		if days <= 0:
			r["errors"].append("%s can't travel from %s to %s: there is no %s route." % [
				v["name"], state["cities"][seq[i - 1]]["name"], state["cities"][seq[i]]["name"], ROUTE_WORDS[route_of(v["type"])]])
			continue
		var fee := trip_fee(state, v["type"], days)
		r["legs"].append({"from": seq[i - 1], "to": seq[i], "days": days, "fee": fee, "stops": p["stops"]})
		r["days"] = int(r["days"]) + days
		r["fees"] = int(r["fees"]) + fee
		var ps: Array = p["stops"]
		for k in range(1, ps.size()):
			full.append(ps[k])
	r["full_path"] = full
	var t := int(state["time_hours"])
	if not r["legs"].is_empty():
		r["first_arrival_t"] = t + int(r["legs"][0]["days"]) * 24
	r["home_t"] = t + int(r["days"]) * 24

	# Cargo simulation
	var onboard := {}  # good -> {lots, cost}
	var wh: Dictionary = home["warehouse"]
	var anything := false
	for g in Data.good_ids():
		var n := int(route["load"].get(g, 0))
		if n <= 0:
			continue
		anything = true
		var avail := Economy.available_for_load(home, g)
		if n > avail:
			var res := Economy.reserve(home, g)
			if res > 0:
				r["errors"].append("Only %d lots of %s can be loaded (you keep %d in reserve)." % [avail, g, res])
			else:
				r["errors"].append("You only have %d lots of %s." % [avail, g])
			n = avail
		Economy.add_stock(onboard, g, n, Economy.cost_of(wh, g, n))
		r["load_lots"] = int(r["load_lots"]) + n
	if int(r["load_lots"]) > cap:
		r["errors"].append("Too much to load: %d lots, but %s carries %d." % [r["load_lots"], v["name"], cap])

	var sold_cost_total := 0
	for i in stops.size():
		var st: Dictionary = stops[i]
		var c: String = st["city"]
		var cname: String = state["cities"][c]["name"]
		var est := {"city": c, "onboard": {}, "sells": [], "buys": []}
		for g in onboard:
			est["onboard"][g] = int(onboard[g]["lots"])
		for g in Data.good_ids():
			if not st["sell"].has(g):
				continue
			anything = true
			var want := int(st["sell"][g]["lots"])
			var limit := int(st["sell"][g]["min"])
			var have := Economy.stock(onboard, g)
			var n := have if want < 0 else mini(want, have)
			if n <= 0:
				r["warnings"].append("Stop %d (%s): no %s on board to sell." % [i + 1, cname, g])
				continue
			var prices := Market.sell_lot_prices(state, c, g, n)
			var k := 0
			var revenue := 0
			for price in prices:
				if limit > 0 and int(price) < limit:
					break
				revenue += int(price)
				k += 1
			if k < n:
				r["warnings"].append("Stop %d (%s): at today's prices only %d of %d %s sell above your minimum." % [i + 1, cname, k, n, g])
			var cost := Economy.remove_stock(onboard, g, k)
			sold_cost_total += cost
			est["sells"].append({"good": g, "lots": k, "revenue": revenue, "profit": revenue - cost})
			r["sales"] = int(r["sales"]) + revenue
		for g in Data.good_ids():
			if not st["buy"].has(g):
				continue
			anything = true
			if not Market.city_sells(state, c, g):
				r["errors"].append("Stop %d: %s doesn't sell %s." % [i + 1, cname, g])
				continue
			var want := int(st["buy"][g]["lots"])
			var limit := int(st["buy"][g]["max"])
			var room := cap - Economy.total_lots(onboard)
			if want > room:
				r["errors"].append("Stop %d (%s): no room for %d %s — only %d lots free." % [i + 1, cname, want, g, room])
			var n := mini(want, maxi(0, room))
			var prices := Market.buy_lot_prices(state, c, g, n)
			var k := 0
			var cost := 0
			for price in prices:
				if limit > 0 and int(price) > limit:
					break
				cost += int(price)
				k += 1
			if k < n:
				r["warnings"].append("Stop %d (%s): at today's prices only %d of %d %s cost less than your maximum." % [i + 1, cname, k, n, g])
			Economy.add_stock(onboard, g, k, cost)
			est["buys"].append({"good": g, "lots": k, "cost": cost})
			r["purchases"] = int(r["purchases"]) + cost
		r["stops"].append(est)

	if not anything:
		r["errors"].append("Give the vehicle something to do: load goods to sell, or choose goods to buy.")
	if not r["legs"].is_empty() and not Economy.can_afford(state, int(r["legs"][0]["fee"])):
		r["errors"].append("Not enough money for the first leg's fee (%s)." % Fmt.coins(r["legs"][0]["fee"]))
	if int(r["purchases"]) > int(state["treasury"]) + int(r["sales"]) - int(r["fees"]):
		r["warnings"].append("You may not be able to pay for every purchase; the vehicle buys what it can afford.")
	r["cash"] = int(r["sales"]) - int(r["purchases"]) - int(r["fees"])
	r["sales_profit"] = int(r["sales"]) - sold_cost_total
	r["profit"] = int(r["sales_profit"]) - int(r["fees"])
	return r


## Sends a vehicle on a route. Returns the plan; check plan["errors"].
static func send_route(state: Dictionary, vehicle_id: String, route_in: Dictionary) -> Dictionary:
	var p := plan_route(state, vehicle_id, route_in)
	if not p["errors"].is_empty():
		return p
	var v := vehicle(state, vehicle_id)
	v["route"] = normalize_route(route_in)
	v["stop_requested"] = false
	_start_loop(state, v)
	return p


## Asks a vehicle on a repeating route to stop after the current loop (or cancels that request).
static func set_stop_requested(state: Dictionary, vehicle_id: String, on: bool) -> void:
	var v := vehicle(state, vehicle_id)
	if not v.is_empty() and not v["route"].is_empty():
		v["stop_requested"] = on


static func _start_loop(state: Dictionary, v: Dictionary) -> void:
	var route: Dictionary = v["route"]
	var home: Dictionary = Economy.home(state)
	var wh: Dictionary = home["warehouse"]
	v["loop"] = {"n": int(v["stats"]["loops"]) + 1, "sales": 0, "sold_cost": 0, "purchases": 0, "fees": 0}
	var loaded: Array = []
	var short: PackedStringArray = []
	for g in Data.good_ids():
		var want := int(route["load"].get(g, 0))
		if want <= 0:
			continue
		var room := int(v["capacity"]) - Economy.total_lots(v["cargo"])
		var n := mini(want, mini(Economy.available_for_load(home, g), room))
		if n > 0:
			var cost := Economy.remove_stock(wh, g, n)
			Economy.add_stock(v["cargo"], g, n, cost)
			loaded.append([g, n])
		if n < want:
			short.append("%d of %d %s" % [n, want, g])
	var text := "%s sets out%s: %s → %s → %s, carrying %s." % [
		v["name"], " (loop %d)" % v["loop"]["n"] if route["repeat"] else "",
		home["name"], route_names(state, route), home["name"],
		Fmt.lots_list(loaded) if not loaded.is_empty() else "nothing yet"]
	if not short.is_empty():
		text += " Only loaded %s." % ", ".join(short)
	News.add(state, text, News.KIND_TRADE)
	_depart(state, v, state["home_id"], route["stops"][0]["city"], 0)


static func _depart(state: Dictionary, v: Dictionary, from_id: String, to_id: String, next_index: int) -> void:
	var p := path_for(state, from_id, to_id, v["type"])
	var days := maxi(1, int(p["days"]))
	var fee := trip_fee(state, v["type"], days)
	Economy.spend(state, "trip_fees", fee)
	v["loop"]["fees"] = int(v["loop"]["fees"]) + fee
	var t := int(state["time_hours"])
	v["location"] = ""
	v["leg"] = {
		"from": from_id, "to": to_id, "path": p["stops"], "hop_days": p["hop_days"], "days": days,
		"start": t, "end": t + days * 24, "next": next_index,
	}


static func step_vehicles(state: Dictionary) -> void:
	var t := int(state["time_hours"])
	for v in state["vehicles"]:
		var leg: Dictionary = v["leg"]
		if leg.is_empty() or t < int(leg["end"]):
			continue
		var next := int(leg["next"])
		var to: String = leg["to"]
		v["location"] = to
		v["leg"] = {}
		if next < 0:
			_arrive_home(state, v)
			continue
		_trade_at_stop(state, v, next)
		var stops: Array = v["route"]["stops"]
		if next + 1 < stops.size():
			_depart(state, v, to, stops[next + 1]["city"], next + 1)
		else:
			_depart(state, v, to, state["home_id"], -1)


static func _trade_at_stop(state: Dictionary, v: Dictionary, index: int) -> void:
	var st: Dictionary = v["route"]["stops"][index]
	var c: String = st["city"]
	var cname: String = state["cities"][c]["name"]
	var loop: Dictionary = v["loop"]
	var sold: Array = []
	var sales := 0
	var sold_cost := 0
	var notes: PackedStringArray = []
	for g in Data.good_ids():
		if not st["sell"].has(g):
			continue
		var want := int(st["sell"][g]["lots"])
		var limit := int(st["sell"][g]["min"])
		var have := Economy.stock(v["cargo"], g)
		var n := have if want < 0 else mini(want, have)
		if n <= 0:
			continue
		var prices := Market.sell_lot_prices(state, c, g, n)
		var k := 0
		var revenue := 0
		for price in prices:
			if limit > 0 and int(price) < limit:
				break
			revenue += int(price)
			k += 1
		if k > 0:
			var cost := Economy.remove_stock(v["cargo"], g, k)
			Market.apply_sell(state, c, g, k)
			Economy.earn(state, "sales", revenue)
			sales += revenue
			sold_cost += cost
			sold.append([g, k])
		if k < n:
			notes.append("kept %d %s (price below your minimum of %s)" % [n - k, g, Fmt.coins(limit)])
	loop["sales"] = int(loop["sales"]) + sales
	loop["sold_cost"] = int(loop["sold_cost"]) + sold_cost

	var bought: Array = []
	var purchases := 0
	for g in Data.good_ids():
		if not st["buy"].has(g) or not Market.city_sells(state, c, g):
			continue
		var want := int(st["buy"][g]["lots"])
		var limit := int(st["buy"][g]["max"])
		var room := int(v["capacity"]) - Economy.total_lots(v["cargo"])
		var n := mini(want, maxi(0, room))
		var prices := Market.buy_lot_prices(state, c, g, n)
		var cash := int(state["treasury"])
		var k := 0
		var paid := 0
		var reason := ""
		for price in prices:
			if limit > 0 and int(price) > limit:
				reason = "price above your maximum of %s" % Fmt.coins(limit)
				break
			if cash < int(price):
				reason = "not enough money"
				break
			cash -= int(price)
			paid += int(price)
			k += 1
		if n < want and reason == "":
			reason = "no room on board"
		if k > 0:
			Economy.spend(state, "purchases", paid)
			Market.apply_buy(state, c, g, k)
			Economy.add_stock(v["cargo"], g, k, paid)
			purchases += paid
			bought.append([g, k])
		if k < want:
			notes.append("got %d of %d %s (%s)" % [k, want, g, reason])
	loop["purchases"] = int(loop["purchases"]) + purchases

	var parts: PackedStringArray = []
	if not sold.is_empty():
		parts.append("sold %s for %s (%s against cost)" % [Fmt.lots_list(sold), Fmt.coins(sales), Fmt.signed(sales - sold_cost)])
	if not bought.is_empty():
		parts.append("bought %s for %s" % [Fmt.lots_list(bought), Fmt.coins(purchases)])
	if parts.is_empty():
		parts.append("traded nothing")
	var text := "%s in %s: %s." % [v["name"], cname, " and ".join(parts)]
	if not notes.is_empty():
		text += " Note: %s." % "; ".join(notes)
	News.add(state, text, News.KIND_TRADE)


static func _arrive_home(state: Dictionary, v: Dictionary) -> void:
	var home: Dictionary = Economy.home(state)
	var unloaded: Array = []
	for g in Data.good_ids():
		var n := Economy.stock(v["cargo"], g)
		if n <= 0:
			continue
		var cost := Economy.remove_stock(v["cargo"], g, n)
		Economy.add_stock(home["warehouse"], g, n, cost)
		unloaded.append([g, n])
	var loop: Dictionary = v["loop"]
	var cash := int(loop["sales"]) - int(loop["purchases"]) - int(loop["fees"])
	var profit := int(loop["sales"]) - int(loop["sold_cost"]) - int(loop["fees"])
	var stats: Dictionary = v["stats"]
	stats["loops"] = int(stats["loops"]) + 1
	stats["last_cash"] = cash
	stats["last_profit"] = profit
	stats["total_profit"] = int(stats["total_profit"]) + profit
	var text := "%s is back in %s: cash %s, profit against cost %s." % [v["name"], home["name"], Fmt.signed(cash), Fmt.signed(profit)]
	if not unloaded.is_empty():
		text += " Unloaded %s." % Fmt.lots_list(unloaded)
	News.add(state, text, News.KIND_TRADE)
	v["location"] = state["home_id"]
	if bool(v["route"]["repeat"]) and not bool(v["stop_requested"]):
		_start_loop(state, v)
		return
	v["last_route"] = v["route"]
	v["route"] = {}
	v["loop"] = {}
	v["stop_requested"] = false


## Fees for legs that are certain to be charged in the vehicles' current loops (for the forecast).
static func committed_fees(state: Dictionary) -> int:
	var total := 0
	for v in state["vehicles"]:
		var leg: Dictionary = v["leg"]
		if leg.is_empty() or int(leg["next"]) < 0:
			continue
		var stops: Array = v["route"]["stops"]
		var prev: String = stops[int(leg["next"])]["city"]
		for i in range(int(leg["next"]) + 1, stops.size()):
			total += trip_fee(state, v["type"], int(path_for(state, prev, stops[i]["city"], v["type"])["days"]))
			prev = stops[i]["city"]
		total += trip_fee(state, v["type"], int(path_for(state, prev, state["home_id"], v["type"])["days"]))
	return total


## Where a travelling vehicle is: {"stops": [city ids of this leg], "hop_days": [...], "elapsed_days": float}.
static func trip_progress(state: Dictionary, v: Dictionary) -> Dictionary:
	var leg: Dictionary = v["leg"]
	if leg.is_empty():
		return {}
	var elapsed := float(int(state["time_hours"]) - int(leg["start"])) / 24.0
	return {"stops": leg["path"], "hop_days": leg["hop_days"], "elapsed_days": clampf(elapsed, 0.0, float(leg["days"]))}
