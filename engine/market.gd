## Market rules: local prices, price impact, drift, recovery and want changes.
## See DESIGN.md batch 1 (markets) for the rules implemented here.
##
## Each city keeps, per good:
##   band   — "surplus" | "neutral" | "want"
##   mod    — normal price modifier (× base), always inside the band
##   drift  — current monthly drift rate, re-rolled every month (±drift_per_month)
##   impact — temporary factor from trades; recovers toward 1.0 over time
extends RefCounted

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")


static func _mk() -> Dictionary:
	return Data.balance()["market"]


static func band_range(band: String) -> Array:
	return _mk()["bands"][band]


## Price change per lot traded, by city population (DESIGN 1B).
static func impact_step(pop: int) -> float:
	for entry in _mk()["impact_steps"]:
		var below := int(entry["below_pop"])
		if below < 0 or pop < below:
			return float(entry["step"])
	return 0.01


static func band_for(city: Dictionary, good_id: String) -> String:
	if city["produces"].has(good_id):
		return "surplus"
	if city["wants"].has(good_id):
		return "want"
	return "neutral"


## Creates the market table for a city. Call after produces and wants are set.
static func init_market(city: Dictionary, rng: RandomNumberGenerator) -> void:
	var drift_max := float(_mk()["drift_per_month"])
	var market := {}
	for id in Data.good_ids():
		var band := band_for(city, id)
		var r := band_range(band)
		market[id] = {
			"band": band,
			"mod": rng.randf_range(float(r[0]), float(r[1])),
			"drift": rng.randf_range(-drift_max, drift_max),
			"impact": 1.0,
		}
	city["market"] = market


## The price a city lists a good at right now, in whole coins.
## Players buy at this price (plus impact); cities pay players 10% below it.
static func listed_price(state: Dictionary, city_id: String, good_id: String) -> int:
	var city: Dictionary = state["cities"][city_id]
	var m: Dictionary = city["market"][good_id]
	var p := float(Data.base_price(good_id)) * float(m["mod"]) * float(m["impact"])
	if bool(city["is_home"]):
		p *= float(_mk()["home_multiplier"])
	return int(round(p))


## Foreign cities only sell what they produce (DESIGN 1A). The home market sells
## only what NPC traders have delivered into it (Milestone 5), so nothing yet.
static func city_sells(state: Dictionary, city_id: String, good_id: String) -> bool:
	var city: Dictionary = state["cities"][city_id]
	if bool(city["is_home"]):
		return false
	return city["produces"].has(good_id)


## What the city pays for each of n lots sold to it, in order. Each lot rounded to the nearest coin.
static func sell_lot_prices(state: Dictionary, city_id: String, good_id: String, n: int) -> Array:
	var listed := listed_price(state, city_id, good_id)
	var step := impact_step(int(state["cities"][city_id]["pop"]))
	var spread := float(_mk()["sell_spread"])
	var out: Array = []
	for k in n:
		out.append(int(round(listed * (1.0 - spread) * pow(1.0 - step, k))))
	return out


## What each of n lots costs to buy from the city, in order.
static func buy_lot_prices(state: Dictionary, city_id: String, good_id: String, n: int) -> Array:
	var listed := listed_price(state, city_id, good_id)
	var step := impact_step(int(state["cities"][city_id]["pop"]))
	var out: Array = []
	for k in n:
		out.append(int(round(listed * pow(1.0 + step, k))))
	return out


## Applies the price impact of n lots sold into a city (prices fall).
static func apply_sell(state: Dictionary, city_id: String, good_id: String, n: int) -> void:
	var city: Dictionary = state["cities"][city_id]
	var step := impact_step(int(city["pop"]))
	var m: Dictionary = city["market"][good_id]
	m["impact"] = float(m["impact"]) * pow(1.0 - step, n)


## Applies the price impact of n lots bought from a city (prices rise).
static func apply_buy(state: Dictionary, city_id: String, good_id: String, n: int) -> void:
	var city: Dictionary = state["cities"][city_id]
	var step := impact_step(int(city["pop"]))
	var m: Dictionary = city["market"][good_id]
	m["impact"] = float(m["impact"]) * pow(1.0 + step, n)


## Advances one city's market by `hours`: drift within the band and recovery of trade impact.
static func step_market(city: Dictionary, hours: int) -> void:
	var hpm := float(Data.hours_per_month())
	var recovery := pow(1.0 - float(_mk()["recovery_per_month"]), float(hours) / hpm)
	var bands: Dictionary = _mk()["bands"]
	var market: Dictionary = city["market"]
	for id in market:
		var m: Dictionary = market[id]
		var r: Array = bands[m["band"]]
		m["mod"] = clampf(float(m["mod"]) * pow(1.0 + float(m["drift"]), float(hours) / hpm), float(r[0]), float(r[1]))
		m["impact"] = 1.0 + (float(m["impact"]) - 1.0) * recovery


## Re-rolls every good's monthly drift rate for a city.
static func reroll_drift(city: Dictionary, rng: RandomNumberGenerator) -> void:
	var d := float(_mk()["drift_per_month"])
	var market: Dictionary = city["market"]
	for id in Data.good_ids():
		market[id]["drift"] = rng.randf_range(-d, d)


## Hours until a city's wants change: 4–8 months, spread over the month so cities
## don't all change on the 1st.
@warning_ignore("integer_division")
static func roll_want_timer(rng: RandomNumberGenerator) -> int:
	var r: Array = _mk()["want_change_months"]
	var hpm := Data.hours_per_month()
	var hours := rng.randi_range(int(r[0]), int(r[1])) * hpm + rng.randi_range(-hpm / 2, hpm / 2)
	return clampi(hours, int(r[0]) * hpm, int(r[1]) * hpm)


## Picks new wants for a city (different from the old ones), moves goods between bands,
## and returns a news line describing the change.
static func rotate_wants(city: Dictionary, rng: RandomNumberGenerator) -> String:
	var old_wants: Array = city["wants"].duplicate()
	var weights := Geo.want_weights(city)
	for id in old_wants:
		weights.erase(id)
	var count := int(_mk()["wants_per_city"])
	var new_wants := Geo.weighted_pick(rng, weights, count)
	if new_wants.size() < count:
		new_wants = old_wants
	city["wants"] = new_wants
	var market: Dictionary = city["market"]
	for id in Data.good_ids():
		var band := band_for(city, id)
		if market[id]["band"] != band:
			var r := band_range(band)
			market[id]["band"] = band
			market[id]["mod"] = rng.randf_range(float(r[0]), float(r[1]))
	city["want_timer_hours"] = roll_want_timer(rng)
	return "%s now pays a premium for %s (no longer %s)." % [
		city["name"], " and ".join(PackedStringArray(new_wants)), " and ".join(PackedStringArray(old_wants))]
