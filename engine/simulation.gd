## The running simulation. Time advances in fixed 1-hour steps (DESIGN 2b-C);
## everything settles continuously, with monthly re-rolls on month boundaries.
extends RefCounted

const Data := preload("res://engine/data.gd")
const Market := preload("res://engine/market.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")
const News := preload("res://engine/news.gd")

const MONTH_NAMES := ["January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December"]


## Advances the world by `hours` one-hour steps.
static func advance(state: Dictionary, rng: RandomNumberGenerator, hours: int) -> void:
	for i in hours:
		_step_hour(state, rng)


## One hour, always in the same order (determinism): markets, production, vehicles,
## running costs, month rollover, want changes.
static func _step_hour(state: Dictionary, rng: RandomNumberGenerator) -> void:
	var t := int(state["time_hours"]) + 1
	state["time_hours"] = t
	var month_boundary := t % Data.hours_per_month() == 0
	var cities: Dictionary = state["cities"]

	for id in state["city_order"]:
		Market.step_market(cities[id], 1)
	for id in Economy.player_city_ids(state):
		Economy.step_production(state, cities[id], 1)
	Transport.step_vehicles(state)
	Economy.step_costs(state, 1)

	if month_boundary:
		Economy.roll_ledger(state)
		for id in state["city_order"]:
			Market.reroll_drift(cities[id], rng)
	for id in state["city_order"]:
		var city: Dictionary = cities[id]
		city["want_timer_hours"] = int(city["want_timer_hours"]) - 1
		if int(city["want_timer_hours"]) <= 0:
			News.add(state, Market.rotate_wants(city, rng), News.KIND_MARKET)


## Calendar date for a time in hours: {year, month, day, hour}. Year 1 starts in start_month.
@warning_ignore("integer_division")
static func date_parts(state: Dictionary, at_hours := -1) -> Dictionary:
	var h := int(state["time_hours"]) if at_hours < 0 else at_hours
	var days_per_month := int(Data.balance()["clock"]["days_per_month"])
	var day_index := h / 24
	var month_index := day_index / days_per_month
	var m0 := int(state["start_month"]) - 1 + month_index
	return {"year": 1 + m0 / 12, "month": m0 % 12 + 1, "day": day_index % days_per_month + 1, "hour": h % 24}


static func date_string(state: Dictionary, at_hours := -1) -> String:
	var d := date_parts(state, at_hours)
	return "%d %s, Year %d" % [d["day"], MONTH_NAMES[int(d["month"]) - 1], d["year"]]


static func short_date(state: Dictionary, at_hours := -1) -> String:
	var d := date_parts(state, at_hours)
	return "Y%d %s %d" % [d["year"], MONTH_NAMES[int(d["month"]) - 1].substr(0, 3), d["day"]]
