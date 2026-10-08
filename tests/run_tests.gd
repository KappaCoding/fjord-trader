## Headless engine tests. Run from the project folder:
##   godot --headless --path . -s tests/run_tests.gd
## Exits with code 0 when everything passes.
extends SceneTree

const Data := preload("res://engine/data.gd")
const Geo := preload("res://engine/geo.gd")
const Market := preload("res://engine/market.gd")
const WorldGen := preload("res://engine/world_gen.gd")
const Simulation := preload("res://engine/simulation.gd")
const SaveLoad := preload("res://engine/save_load.gd")
const Game := preload("res://engine/game.gd")
const Economy := preload("res://engine/economy.gd")
const Transport := preload("res://engine/transport.gd")

var passed := 0
var failed := 0


func _init() -> void:
	test_data()
	test_world_determinism()
	test_world_rules_across_seeds()
	test_price_math()
	test_drift_stays_in_bands()
	test_recovery_rate()
	test_want_rotation()
	test_save_load_determinism()
	test_clock()
	test_paths()
	# Milestone 2
	test_start_state()
	test_production()
	test_running_costs()
	test_storage_fee()
	test_home_sale()
	test_trip_round()
	test_trip_validation()
	test_trip_short_of_money()
	test_retooling()
	test_buy_vehicle()
	test_save_mid_trip()
	# Milestone 3
	test_food_and_growth()
	test_starvation()
	test_stage_up()
	test_infrastructure()
	test_production_access()
	test_add_line_and_inputs()
	test_tier_change()
	test_line_upgrades()
	test_priority()
	test_reserves()
	# Milestone 4
	test_multi_stop_route()
	test_repeat_and_stop()
	test_price_limits()
	test_route_validation()
	test_committed_fees()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + msg)


func new_game(seed_text := "test", n := 10) -> Game:
	var g := Game.new()
	g.new_game(seed_text, n)
	return g


# ------------------------------------------------------------------ tests

func test_data() -> void:
	check(Data.good_ids().size() == 20, "20 goods in the catalogue")
	check(Data.base_price("Tools") == 1450000, "Tools rebalanced to 1,450,000")
	check(Data.base_price("Jewelry") == 14000000, "Jewelry rebalanced to 14,000,000")
	check(Data.base_price("Medicine") == 10500000, "Medicine rebalanced to 10,500,000")
	check(Data.good("Ships")["inputs"]["Timber"] == 20, "Ships need 20 Timber")
	check(Data.is_import_only("Spices") and Data.is_import_only("Gold"), "Spices and Gold are import-only")
	check(Data.hours_per_month() == 720, "30-day months")


func test_world_determinism() -> void:
	var a := new_game("fjord", 10)
	var b := new_game("fjord", 10)
	var c := new_game("trader", 10)
	check(JSON.stringify(a.state) == JSON.stringify(b.state), "same seed gives the same world")
	check(JSON.stringify(a.state) != JSON.stringify(c.state), "different seeds give different worlds")


func test_world_rules_across_seeds() -> void:
	var fjord_homes := 0
	var coast_homes := 0
	var option_sets := {}
	var bad := 0
	for i in 200:
		var n := 6 + (i % 11)
		var g := new_game("seed-%d" % i, n)
		var problems := WorldGen.validate(g.state)
		if not problems.is_empty():
			bad += 1
			if bad <= 3:
				printerr("  seed-%d: %s" % [i, str(problems)])
		var home: Dictionary = g.state["cities"][g.state["home_id"]]
		if home["site"] == "fjord":
			fjord_homes += 1
		else:
			coast_homes += 1
		option_sets[str(home["production_options"])] = true
	check(bad == 0, "all 200 worlds satisfy the generation rules (%d failed)" % bad)
	check(fjord_homes > 40 and coast_homes > 40, "home site varies between fjord and coast (%d/%d)" % [fjord_homes, coast_homes])
	check(option_sets.size() > 5, "home production options differ between seeds (%d variants)" % option_sets.size())


func test_price_math() -> void:
	var g := new_game("prices", 10)
	var s := g.state
	check(is_equal_approx(Market.impact_step(2000), 0.03), "step 3% under 10k")
	check(is_equal_approx(Market.impact_step(10000), 0.02), "step 2% at 10k")
	check(is_equal_approx(Market.impact_step(60000), 0.015), "step 1.5% at 60k")
	check(is_equal_approx(Market.impact_step(300000), 0.01), "step 1% at 300k")

	var cid: String = s["city_order"][1]
	var city: Dictionary = s["cities"][cid]
	var good := "Salt"
	var listed := Market.listed_price(s, cid, good)
	var m: Dictionary = city["market"][good]
	var expected := int(round(Data.base_price(good) * float(m["mod"]) * float(m["impact"])))
	check(listed == expected, "listed price = base × mod × impact")

	var step := Market.impact_step(int(city["pop"]))
	var sells := Market.sell_lot_prices(s, cid, good, 3)
	check(sells[0] == int(round(listed * 0.9)), "first lot sold pays listed × 0.90")
	check(sells[2] == int(round(listed * 0.9 * pow(1.0 - step, 2))), "third lot sold pays listed × 0.90 × (1-step)^2")
	var buys := Market.buy_lot_prices(s, cid, good, 3)
	check(buys[0] == listed, "first lot bought costs listed")
	check(buys[1] == int(round(listed * (1.0 + step))), "second lot bought costs listed × (1+step)")

	Market.apply_sell(s, cid, good, 5)
	check(is_equal_approx(float(m["impact"]), pow(1.0 - step, 5)), "selling 5 lots lowers impact by (1-step)^5")

	var home_id: String = s["home_id"]
	var hm: Dictionary = s["cities"][home_id]["market"]["Fish"]
	var home_expected := int(round(Data.base_price("Fish") * float(hm["mod"]) * float(hm["impact"]) * 0.75))
	check(Market.listed_price(s, home_id, "Fish") == home_expected, "home market prices × 0.75")
	check(not Market.city_sells(s, home_id, "Fish"), "home market sells nothing yet")
	check(Market.city_sells(s, cid, city["produces"][0]), "cities sell what they produce")
	var non_produced := ""
	for id in Data.good_ids():
		if not city["produces"].has(id):
			non_produced = id
			break
	check(not Market.city_sells(s, cid, non_produced), "cities don't sell what they don't produce")


func test_drift_stays_in_bands() -> void:
	var g := new_game("drift", 12)
	g.advance_hours(720 * 60)  # five years
	var bands: Dictionary = Data.balance()["market"]["bands"]
	var ok := true
	var moved := false
	for id in g.state["city_order"]:
		for gid in Data.good_ids():
			var m: Dictionary = g.state["cities"][id]["market"][gid]
			var r: Array = bands[m["band"]]
			if float(m["mod"]) < float(r[0]) - 1e-9 or float(m["mod"]) > float(r[1]) + 1e-9:
				ok = false
	var g2 := new_game("drift", 12)
	var before := float(g2.state["cities"]["c1"]["market"]["Grain"]["mod"])
	g2.advance_hours(720 * 3)
	moved = not is_equal_approx(before, float(g2.state["cities"]["c1"]["market"]["Grain"]["mod"]))
	check(ok, "after five years every price modifier is still inside its band")
	check(moved, "prices drift over time")


func test_recovery_rate() -> void:
	var g := new_game("recovery", 10)
	var cid: String = g.state["city_order"][2]
	var m: Dictionary = g.state["cities"][cid]["market"]["Grain"]
	m["impact"] = 0.6
	Market.step_market(g.state["cities"][cid], 720)
	check(is_equal_approx(float(m["impact"]), 1.0 - 0.4 * 0.75), "impact recovers 25% of the gap per month")


func test_want_rotation() -> void:
	var g := new_game("wants", 10)
	var city: Dictionary = g.state["cities"]["c1"]
	var timer := int(city["want_timer_hours"])
	check(timer >= 4 * 720 and timer <= 8 * 720, "wants change every 4–8 months")
	var old_wants: Array = city["wants"].duplicate()
	g.advance_hours(timer)
	check(city["wants"] != old_wants, "wants changed when the timer ran out")
	for w in city["wants"]:
		check(city["market"][w]["band"] == "want", "new want %s is in the want band" % w)
	for w in old_wants:
		if not city["wants"].has(w):
			check(city["market"][w]["band"] == "neutral", "old want %s is back to neutral" % w)
	var found := false
	for entry in g.state["news"]:
		if String(entry["text"]).begins_with(String(city["name"])):
			found = true
	check(found, "a want change is announced in the news")


func test_save_load_determinism() -> void:
	var a := new_game("saves", 10)
	a.advance_hours(720 * 7)
	var path := "user://test_save.sav"
	check(a.save_to(path) == OK, "save succeeds")
	var b := Game.new()
	check(b.load_from(path), "load succeeds")
	a.advance_hours(720 * 9)
	b.advance_hours(720 * 9)
	var sa := SaveLoad.to_json(a.state, a.rng)
	var sb := SaveLoad.to_json(b.state, b.rng)
	check(sa == sb, "a loaded game continues exactly like the original")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_paths() -> void:
	var never_slower := true
	var endpoints_ok := true
	var multi_hop_seen := false
	var land_never_overseas := true
	for i in 30:
		var g := new_game("paths-%d" % i, 12)
		var s := g.state
		var home: String = s["home_id"]
		for id in s["city_order"]:
			if id == home:
				continue
			for rt in Geo.ROUTE_TYPES:
				var direct := Geo.travel_days(s, home, id, rt)
				var path := Geo.best_path(s, home, id, rt)
				var days := int(path["days"])
				if direct > 0 and (days < 0 or days > direct):
					never_slower = false
				if days > 0:
					var stops: Array = path["stops"]
					if stops[0] != home or stops[stops.size() - 1] != id:
						endpoints_ok = false
					if stops.size() > 2:
						multi_hop_seen = true
				if rt == "land" and days > 0 and s["cities"][id]["region"] == "overseas":
					land_never_overseas = false
	check(never_slower, "the best path is never slower than the direct route")
	check(endpoints_ok, "paths start at home and end at the destination")
	check(multi_hop_seen, "some cities are reached through other cities")
	check(land_never_overseas, "no land route reaches overseas cities")


func test_clock() -> void:
	var g := new_game("clock", 10)
	check(Simulation.date_string(g.state) == "1 April, Year 1", "game starts 1 April, Year 1")
	g.advance_hours(24 * 30 * 9)
	check(Simulation.date_string(g.state) == "1 January, Year 2", "nine months later it is 1 January, Year 2")


# ------------------------------------------------------------------ Milestone 2

func home_wh(g: Game) -> Dictionary:
	return g.home()["warehouse"]


## Nobody to feed: isolates production and trade tests from food consumption.
func no_mouths(g: Game) -> void:
	g.home()["pop"] = 0
	g.home()["pop_exact"] = 0.0


func barge_destination(g: Game) -> Dictionary:
	return Transport.reachable(g.state, g.state["home_id"], "barge")[0]


func one_stop(dest: String, sell: Dictionary, buy: Dictionary) -> Dictionary:
	var stop := {"city": dest, "sell": {}, "buy": {}}
	for good in sell:
		stop["sell"][good] = {"lots": -1}
	for good in buy:
		stop["buy"][good] = {"lots": int(buy[good])}
	return {"load": sell, "stops": [stop], "repeat": false}


func news_contains(g: Game, needle: String) -> bool:
	for entry in g.state["news"]:
		if String(entry["text"]).contains(needle):
			return true
	return false


func first_produced_except(city: Dictionary, avoid: String) -> String:
	for good in city["produces"]:
		if good != avoid:
			return good
	return ""


func test_start_state() -> void:
	var g := new_game("start", 10)
	var s := g.state
	check(int(s["treasury"]) == 3000000, "start with 3,000,000")
	check(s["vehicles"].size() == 2, "start with two vehicles")
	check(s["vehicles"][0]["type"] == "wagon" and s["vehicles"][1]["type"] == "barge", "a wagon and a barge")
	for v in s["vehicles"]:
		check(Transport.is_idle_at_home(s, v), "%s starts idle at home" % v["name"])
	check(g.home()["lines"].size() == 2, "Stage 1 home has two lines")
	check(int(g.home()["pop"]) == 2000 and int(g.home()["stage"]) == 1, "home starts at Stage 1 with 2,000 people")
	check(g.needs_line_choice(), "lines start unassigned")
	check(g.net_worth() == 3000000 + 1700000 + 1000000, "start net worth = treasury + vehicles + lines")


func test_production() -> void:
	var g := new_game("production", 10)
	no_mouths(g)
	var opts: Array = g.home()["production_options"]
	var a: String = opts[0]
	var b: String = opts[1]
	var before := int(g.state["treasury"])
	check(g.choose_line(0, a) == "", "first choice for line 1 succeeds")
	check(g.choose_line(1, b) == "", "first choice for line 2 succeeds")
	check(int(g.state["treasury"]) == before, "the first choice is free")
	check(not g.needs_line_choice(), "no lines left to choose")
	g.advance_hours(71)
	check(Economy.stock(home_wh(g), a) == 0, "no lot before 3 days")
	g.advance_hours(1)
	check(Economy.stock(home_wh(g), a) == 1, "one lot after exactly 3 days")
	g.advance_hours(720 - 72)
	check(Economy.stock(home_wh(g), a) == 10 and Economy.stock(home_wh(g), b) == 10, "10 lots per line per month")
	check(int(home_wh(g)[a]["cost"]) == 10 * Economy.produced_lot_value(a), "produced lots count at 0.75 × base")
	check(Economy.produced_lot_value("Salt") == 67500, "0.75 × 90,000 = 67,500")


func test_running_costs() -> void:
	var g := new_game("costs", 10)
	var start := int(g.state["treasury"])
	g.advance_hours(720)
	var last: Dictionary = g.state["ledger"]["last"]
	check(int(last["upkeep"]) >= 33999 and int(last["upkeep"]) <= 34000, "upkeep is 2%% of 1,700,000 per month (%d)" % int(last["upkeep"]))
	check(int(last["tax"]) > 29000 and int(last["tax"]) <= 30000, "tax is about 1%% of the treasury per month (%d)" % int(last["tax"]))
	check(int(g.state["treasury"]) == start - int(last["upkeep"]) - int(last["tax"]) - int(last["storage"]), "every coin of running cost is in the ledger")
	var f := g.forecast()
	check(int(f["upkeep"]) == 34000, "forecast shows upkeep per month")
	check(int(f["per_month"]) == int(f["upkeep"]) + int(f["tax"]) + int(f["storage"]), "forecast total adds up")
	check(int(f["runway_days"]) > 0, "forecast shows a runway")
	g.state["treasury"] = 1000000
	check(int(g.forecast()["tax"]) == 25000, "tax never below the Stage 1 minimum of 25,000")


func test_storage_fee() -> void:
	var g := new_game("storage", 10)
	Economy.add_stock(home_wh(g), "Salt", 10, 1000000)
	check(int(g.forecast()["storage"]) == 5000, "storage fee is 0.5%% of stock value per month")
	g.advance_hours(720)
	var stored := int(g.state["ledger"]["last"]["storage"])
	check(stored >= 4999 and stored <= 5000, "a month of storage costs 5,000 (%d)" % stored)


func test_home_sale() -> void:
	var g := new_game("homesale", 10)
	var s := g.state
	var home_id: String = s["home_id"]
	Economy.add_stock(home_wh(g), "Grain", 10, 300000)
	var expected := Economy.sum(Market.sell_lot_prices(s, home_id, "Grain", 4))
	var before := int(s["treasury"])
	var worth_before := g.net_worth()
	var r := g.sell_at_home("Grain", 4)
	check(r["error"] == "", "home sale succeeds")
	check(int(r["revenue"]) == expected, "home sale pays the lot-by-lot price")
	check(int(s["treasury"]) == before + expected, "revenue goes to the treasury")
	check(Economy.stock(home_wh(g), "Grain") == 6, "4 lots leave the warehouse")
	check(int(home_wh(g)["Grain"]["cost"]) == 180000, "cost basis leaves at average cost")
	check(g.net_worth() == worth_before + expected - 120000, "net worth changes by revenue minus cost basis")
	check(float(s["cities"][home_id]["market"]["Grain"]["impact"]) < 1.0, "selling lowers the home price")
	check(g.sell_at_home("Grain", 7)["error"] != "", "can't sell more than you have")


func test_trip_round() -> void:
	var g := new_game("trip", 10)
	no_mouths(g)
	var s := g.state
	var dest_info := barge_destination(g)
	var dest: String = dest_info["city"]
	var days: int = dest_info["days"]
	var buy_good := first_produced_except(s["cities"][dest], "Stone")
	Economy.add_stock(home_wh(g), "Stone", 15, 15 * 37500)
	var route := one_stop(dest, {"Stone": 15}, {buy_good: 5})
	var p := g.plan_route("barge-1", route)
	check(p["errors"].is_empty(), "a valid trip plans without errors %s" % str(p["errors"]))
	check(int(p["legs"][0]["fee"]) == int(round(40000.0 * days / 30.0)), "barge fee is 40,000 ÷ 30 per day of travel")
	check(int(p["load_lots"]) == 15, "loads 15 lots")
	var before := int(s["treasury"])
	var r := g.send_route("barge-1", route)
	check(r["errors"].is_empty(), "the trip is sent")
	check(int(s["treasury"]) == before - int(p["legs"][0]["fee"]), "the outbound fee is paid on departure")
	check(Economy.stock(home_wh(g), "Stone") == 0, "cargo leaves the warehouse")
	var barge := Transport.vehicle(s, "barge-1")
	check(barge["location"] == "" and Economy.stock(barge["cargo"], "Stone") == 15, "the barge carries the cargo")

	g.advance_hours(days * 24 - 1)
	var copy: Dictionary = s.duplicate(true)
	Market.step_market(copy["cities"][dest], 1)
	var expected_sales := Economy.sum(Market.sell_lot_prices(copy, dest, "Stone", 15))
	var expected_cost := Economy.sum(Market.buy_lot_prices(copy, dest, buy_good, 5))
	check(Economy.stock(barge["cargo"], "Stone") == 15, "still travelling one hour before arrival")
	g.advance_hours(1)
	check(int(barge["loop"]["sales"]) == expected_sales, "cargo sells at the arrival price, lot by lot")
	check(int(barge["loop"]["purchases"]) == expected_cost, "goods are bought at the arrival price")
	check(Economy.stock(barge["cargo"], buy_good) == 5, "bought goods are on board")
	check(int(barge["leg"]["next"]) == -1, "the barge heads home")
	check(news_contains(g, "in %s: sold 15 Stone" % s["cities"][dest]["name"]), "the trade is reported in the news")
	g.advance_hours(days * 24)
	check(Transport.is_idle_at_home(s, barge), "the barge is home and idle")
	check(Economy.stock(home_wh(g), buy_good) == 5, "bought goods are unloaded into the warehouse")
	check(int(home_wh(g)[buy_good]["cost"]) == expected_cost, "unloaded goods keep their purchase cost")
	var fees := 2 * int(p["legs"][0]["fee"])
	check(int(barge["stats"]["last_cash"]) == expected_sales - expected_cost - fees, "the loop's cash result is reported")
	check(int(barge["stats"]["last_profit"]) == expected_sales - 15 * 37500 - fees, "profit counts the sold goods at cost")
	check(not barge["last_route"].is_empty(), "the finished route is remembered for reuse")


func test_trip_validation() -> void:
	var g := new_game("validate", 10)
	var s := g.state
	var dest: String = barge_destination(g)["city"]
	Economy.add_stock(home_wh(g), "Stone", 30, 30 * 37500)
	var overseas := ""
	for id in s["city_order"]:
		if s["cities"][id]["region"] == "overseas":
			overseas = id
			break
	var not_sold := ""
	for id in Data.good_ids():
		if not s["cities"][dest]["produces"].has(id):
			not_sold = id
			break
	check(String(g.plan_route("wagon-1", one_stop(overseas, {"Stone": 1}, {}))["errors"][0]).contains("no road"), "a wagon can't reach overseas")
	check(not g.plan_route("barge-1", one_stop(dest, {"Stone": 25}, {}))["errors"].is_empty(), "can't overload the barge")
	check(not g.plan_route("barge-1", one_stop(dest, {}, {not_sold: 1}))["errors"].is_empty(), "can't buy what the city doesn't sell")
	check(not g.plan_route("barge-1", one_stop(dest, {"Salt": 1}, {}))["errors"].is_empty(), "can't load what you don't have")
	check(not g.plan_route("barge-1", one_stop(dest, {}, {}))["errors"].is_empty(), "an empty trip is refused")
	check(not g.plan_route("barge-1", one_stop(s["home_id"], {"Stone": 1}, {}))["errors"].is_empty(), "home isn't a stop")
	g.send_route("barge-1", one_stop(dest, {"Stone": 5}, {}))
	check(not g.plan_route("barge-1", one_stop(dest, {"Stone": 5}, {}))["errors"].is_empty(), "a busy vehicle can't be sent again")
	s["treasury"] = 0
	var wagon_reach := Transport.reachable(s, s["home_id"], "wagon")
	check(not g.plan_route("wagon-1", one_stop(wagon_reach[0]["city"], {"Stone": 5}, {}))["errors"].is_empty(), "no trip without money for the fee")


func test_trip_short_of_money() -> void:
	var g := new_game("short", 10)
	no_mouths(g)
	var s := g.state
	var dest_info := barge_destination(g)
	var dest: String = dest_info["city"]
	var good: String = s["cities"][dest]["produces"][0]
	var fee := Transport.trip_fee(s, "barge", dest_info["days"])
	var price := Market.listed_price(s, dest, good)
	s["treasury"] = fee + int(price * 2.5) + 60000
	g.send_route("barge-1", one_stop(dest, {}, {good: 10}))
	g.advance_hours(int(dest_info["days"]) * 24)
	var got := Economy.stock(Transport.vehicle(s, "barge-1")["cargo"], good)
	check(got >= 1 and got < 10, "buys only what it can afford (%d of 10)" % got)
	check(news_contains(g, "not enough money"), "the shortfall is reported")


func test_retooling() -> void:
	var g := new_game("retool", 10)
	no_mouths(g)
	var opts: Array = g.home()["production_options"]
	var a: String = opts[0]
	var b: String = opts[1]
	g.choose_line(0, a)
	g.advance_hours(720)
	var a_before := Economy.stock(home_wh(g), a)
	var before := int(g.state["treasury"])
	var worth_before := g.net_worth()
	check(g.choose_line(0, a) != "", "retooling to the same good is refused")
	check(g.choose_line(0, "Gold") != "", "can't produce an import-only good")
	check(g.choose_line(0, b) == "", "retooling starts")
	check(int(g.state["treasury"]) == before - 125000, "retooling costs 25% of 500,000")
	check(g.net_worth() == worth_before - 125000, "retooling is a cost, not an asset")
	check(g.choose_line(0, a) != "", "can't retool a line that is already switching")
	g.advance_hours(14 * 24 - 1)
	check(Economy.stock(home_wh(g), a) == a_before, "no production during the 14-day downtime")
	check(g.home()["lines"][0]["good"] == a, "still the old good until the downtime ends")
	g.advance_hours(1)
	check(g.home()["lines"][0]["good"] == b, "the line switches after 14 days")
	g.advance_hours(720)
	check(Economy.stock(home_wh(g), b) == 10, "the retooled line produces 10 lots a month")


func test_buy_vehicle() -> void:
	var g := new_game("fleet", 10)
	var before := int(g.state["treasury"])
	var worth := g.net_worth()
	check(g.buy_vehicle("wagon") == "", "buying a wagon succeeds")
	check(int(g.state["treasury"]) == before - 200000, "a wagon costs 200,000")
	check(g.net_worth() == worth, "buying a vehicle doesn't change net worth")
	check(g.state["vehicles"][2]["name"] == "Wagon 2", "the new wagon is named Wagon 2")
	check(g.buy_vehicle("coastal").contains("Stage 2"), "coastal vessels need Stage 2")
	check(g.buy_vehicle("ocean").contains("Stage 3"), "ocean ships need Stage 3")
	g.state["treasury"] = 100
	check(g.buy_vehicle("barge") != "", "can't buy without money")


func test_save_mid_trip() -> void:
	var a := new_game("midtrip", 10)
	var opts: Array = a.home()["production_options"]
	a.choose_line(0, opts[0])
	a.choose_line(1, opts[1])
	a.advance_hours(24 * 20)
	var dest: String = barge_destination(a)["city"]
	a.send_route("barge-1", one_stop(dest, {opts[1]: 5}, {}))
	a.advance_hours(24 * 3)
	var path := "user://test_midtrip.sav"
	a.save_to(path)
	var b := Game.new()
	check(b.load_from(path), "a game saved mid-trip loads")
	a.advance_hours(24 * 60)
	b.advance_hours(24 * 60)
	check(SaveLoad.to_json(a.state, a.rng) == SaveLoad.to_json(b.state, b.rng), "a loaded mid-trip game continues identically")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ------------------------------------------------------------------ Milestone 3

func set_pop(g: Game, pop: int) -> void:
	g.home()["pop"] = pop
	g.home()["pop_exact"] = float(pop)


func test_food_and_growth() -> void:
	var g := new_game("growth", 10)
	var h := g.home()
	g.advance_hours(240)
	check(int(h["pop"]) == 2000, "no food in stock: the population doesn't grow")
	check(float(Economy.growth_breakdown(g.state, h)["rate"]) == 0.0, "growth rate is 0 without food")
	Economy.add_stock(h["warehouse"], "Grain", 10, 300000)
	var b := Economy.growth_breakdown(g.state, h)
	check(is_equal_approx(float(b["rate"]), 0.04), "fed + 3 months stored + healthy treasury = 4%% (%.3f)" % float(b["rate"]))
	var start_pop := float(h["pop_exact"])
	var grain_before := Economy.stock(h["warehouse"], "Grain")
	g.advance_hours(720)
	var expected := start_pop * 1.04
	check(absf(float(h["pop_exact"]) - expected) < 1.0, "a month at 4%% growth: %.1f vs %.1f" % [float(h["pop_exact"]), expected])
	check(Economy.stock(h["warehouse"], "Grain") == grain_before - 1, "2,000 people eat one lot a month")
	Economy.add_stock(h["warehouse"], "Fish", 2, 82500)
	check(is_equal_approx(float(Economy.growth_breakdown(g.state, h)["rate"]), 0.045), "both Grain and Fish adds 0.5%")
	h["infrastructure"]["housing"] = 1
	h["infrastructure"]["harbor"] = 1
	h["infrastructure"]["roads"] = 1
	var capped := Economy.growth_breakdown(g.state, h)
	check(is_equal_approx(float(capped["rate"]), 0.05) and bool(capped["capped"]), "growth is capped at 5%")
	check(Economy.food_need_per_month(h) == 1, "up to 2,500 people need 1 lot a month")
	set_pop(g, 2501)
	check(Economy.food_need_per_month(h) == 2, "2,501 people need 2 lots a month")
	var eta := Economy.next_stage_eta(g.state, h)
	check(int(eta["stage"]) == 2 and float(eta["months"]) > 0.0, "the next stage has a time estimate")


func test_starvation() -> void:
	var g := new_game("starve", 10)
	var h := g.home()
	g.advance_hours(24 * 89)
	check(int(h["pop"]) == 2000, "no decline before 90 days without food")
	g.advance_hours(24 * 31)
	check(int(h["pop"]) < 2000, "after 90 days without food the population declines (%d)" % int(h["pop"]))
	check(bool(Economy.growth_breakdown(g.state, h)["starving"]), "starvation is shown")


func test_stage_up() -> void:
	var g := new_game("stage", 10)
	var h := g.home()
	set_pop(g, 9995)
	Economy.add_stock(h["warehouse"], "Grain", 50, 1500000)
	check(not Economy.can_add_line(h), "Stage 1 allows no third line")
	g.advance_hours(72)
	check(int(h["stage"]) == 2, "the settlement becomes a Town at 10,000 people")
	check(news_contains(g, "has grown into a town"), "the new stage is announced")
	check(Economy.can_add_line(h), "Stage 2 allows more lines")
	check(int(g.forecast()["tax"]) >= 250000, "the Stage 2 tax minimum applies")
	set_pop(g, 100)
	g.advance_hours(24)
	check(int(h["stage"]) == 2, "stages never regress")


func test_infrastructure() -> void:
	var g := new_game("infra", 10)
	var s := g.state
	var h := g.home()
	var far := Transport.reachable(s, s["home_id"], "wagon")
	var far_city: String = far[far.size() - 1]["city"]
	var wagon_days := int(Transport.path_for(s, s["home_id"], far_city, "wagon")["days"])
	var barge_fee := Transport.trip_fee(s, "barge", 10)
	var worth := g.net_worth()
	check(g.build("housing") == "", "build housing")
	check(int(s["treasury"]) == 3000000 - 1000000, "Stage 1 infrastructure costs 1,000,000")
	check(int(h["pop"]) == 2300, "housing adds 15%% population at once (%d)" % int(h["pop"]))
	check(g.net_worth() == worth, "infrastructure counts toward net worth at cost")
	check(g.build("housing") != "", "only one housing per stage")
	check(g.build("retooling").contains("Stage 2"), "the retooling works need Stage 2")
	check(g.build("roads") == "", "build roads")
	check(int(Transport.path_for(s, s["home_id"], far_city, "wagon")["days"]) < wagon_days, "roads make wagons faster (%d → %d days)" % [wagon_days, int(Transport.path_for(s, s["home_id"], far_city, "wagon")["days"])])
	check(g.build("harbor") == "", "build harbor")
	check(Transport.trip_fee(s, "barge", 10) == int(round(barge_fee * 0.9)), "a harbor cuts water fees by 10%")
	check(Transport.trip_fee(s, "wagon", 10) == 5000, "the harbor doesn't change road fees")
	check(g.build("roads") != "", "not enough money or already built shows an error")
	h["stage"] = 2
	s["treasury"] = 100000000
	check(g.build("retooling") == "" and Economy.retool_days(h) == 12, "the retooling works cut downtime to 12 days")
	check(int(s["ledger"]["current"]["infrastructure"]) > 0, "infrastructure spending is in the books")


func test_production_access() -> void:
	var g := new_game("access", 10)
	var h := g.home()
	check(Economy.cannot_produce_reason(h, "Spices").contains("Import only"), "Spices are import-only")
	check(Economy.cannot_produce_reason(h, "Cloth").contains("Stage 2"), "Cloth unlocks at Stage 2")
	check(Economy.cannot_produce_reason(h, "Steel").contains("Stage 3"), "Steel unlocks at Stage 3")
	check(Economy.cannot_produce_reason(h, "Fish") == "", "a coastal home can always fish")
	h["features"] = []
	check(Economy.cannot_produce_reason(h, "Timber").contains("forest"), "no forest, no Timber")
	check(Economy.cannot_produce_reason(h, "Iron Ore").contains("mountains"), "no mountains, no Iron Ore")
	h["stage"] = 3
	check(Economy.cannot_produce_reason(h, "Steel") == "", "processed goods can be made anywhere once unlocked")
	check(Economy.cannot_produce_reason(h, "Wine").contains("warm"), "a northern home can't make Wine")
	var opts := Economy.producible_goods(h)
	check(opts.has("Steel") and not opts.has("Gold"), "the producible list follows the rules")


func test_add_line_and_inputs() -> void:
	var g := new_game("inputs", 10)
	no_mouths(g)
	var h := g.home()
	check(g.add_line("Grain").contains("Stage 2"), "no free slot at Stage 1")
	h["stage"] = 2
	var before := int(g.state["treasury"])
	check(g.add_line("Cloth") == "", "add a Cloth line at Stage 2")
	check(int(g.state["treasury"]) == before - 3000000, "a Tier 2 line costs 3,000,000")
	check(h["lines"].size() == 3 and int(h["lines"][2]["tier"]) == 2, "the new line is Tier 2")
	g.advance_hours(72)
	check(String(h["lines"][2]["waiting"]).contains("Wool"), "without Wool the Cloth line waits")
	check(news_contains(g, "waiting for inputs"), "the stall is reported")
	Economy.add_stock(h["warehouse"], "Wool", 5, 5 * 52500)
	g.advance_hours(1)
	check(Economy.stock(h["warehouse"], "Cloth") == 1, "Cloth is made once Wool arrives")
	check(Economy.stock(h["warehouse"], "Wool") == 3, "one lot of Cloth uses 2 Wool")
	check(String(h["lines"][2]["waiting"]) == "", "the line runs again")


func test_tier_change() -> void:
	var g := new_game("tierup", 10)
	no_mouths(g)
	var h := g.home()
	var opts: Array = h["production_options"]
	g.choose_line(0, opts[0])
	h["stage"] = 2
	var before := int(g.state["treasury"])
	var worth := g.net_worth()
	check(g.choose_line(0, "Cloth") == "", "a Tier 1 line can switch to a Tier 2 good")
	check(int(g.state["treasury"]) == before - 2500000 - 125000, "it costs the tier difference plus retooling")
	check(g.net_worth() == worth - 125000, "the tier difference becomes part of the line's value")
	check(int(h["lines"][0]["tier"]) == 2 and int(h["lines"][0]["base_value"]) == 3000000, "the line is now Tier 2")
	g.advance_hours(14 * 24)
	check(h["lines"][0]["good"] == "Cloth", "after the downtime it makes Cloth")
	g.state["treasury"] = 10000000
	var free_before := int(g.state["treasury"])
	h["lines"][1]["good"] = ""
	check(g.choose_line(1, "Cloth") == "", "an unassigned line can start above its tier")
	check(int(g.state["treasury"]) == free_before - 2500000, "but pays the tier difference")


func test_line_upgrades() -> void:
	var g := new_game("upgrade", 10)
	no_mouths(g)
	var h := g.home()
	g.choose_line(0, h["production_options"][0])
	var worth := g.net_worth()
	var before := int(g.state["treasury"])
	check(g.upgrade_line(0) == "" and Economy.line_output(h["lines"][0]) == 15, "the first upgrade gives 15 lots a month")
	check(int(g.state["treasury"]) == before - 1000000, "the first upgrade costs 2 × 500,000")
	check(g.upgrade_line(0) == "" and Economy.line_output(h["lines"][0]) == 20, "the second gives 20 lots a month")
	check(int(g.state["treasury"]) == before - 3000000, "the second costs 4 × 500,000")
	check(g.upgrade_line(0) != "", "no third upgrade")
	check(g.net_worth() == worth, "upgrades count toward net worth at cost")
	h["lines"][0]["progress"] = 0
	var good: String = h["lines"][0]["good"]
	var start := Economy.stock(h["warehouse"], good)
	g.advance_hours(720)
	check(Economy.stock(h["warehouse"], good) - start == 20, "an upgraded line makes 20 lots a month")


func test_priority() -> void:
	var g := new_game("priority", 10)
	no_mouths(g)
	var h := g.home()
	h["stage"] = 2
	h["lines"][0]["good"] = "Cloth"
	h["lines"][1]["good"] = "Cloth"
	h["lines"][1]["progress"] = 10
	Economy.add_stock(h["warehouse"], "Wool", 2, 105000)
	g.advance_hours(72)
	check(Economy.stock(h["warehouse"], "Cloth") == 1, "only one lot of Cloth from 2 Wool")
	check(String(h["lines"][0]["waiting"]) != "" and String(h["lines"][1]["waiting"]) == "", "the line that finished first used the Wool; the other waits")
	h["lines"][0]["progress"] = 720
	h["lines"][1]["progress"] = 720
	h["lines"][0]["waiting"] = ""
	h["lines"][1]["waiting"] = ""
	Economy.add_stock(h["warehouse"], "Wool", 2, 105000)
	g.state["cities"][g.state["home_id"]]["lines"][0]["good"] = "Cloth"
	var first: Dictionary = h["lines"][0]
	g.advance_hours(1)
	check(String(first["waiting"]) == "", "when both are ready, the first line in the list goes first")
	g.move_line(0, 1)
	check(h["lines"][1] == first, "lines can be reordered")


func test_reserves() -> void:
	var g := new_game("reserves", 10)
	no_mouths(g)
	var h := g.home()
	var dest: String = barge_destination(g)["city"]
	Economy.add_stock(h["warehouse"], "Stone", 8, 8 * 37500)
	g.set_reserve("Stone", 5)
	check(Economy.available_for_load(h, "Stone") == 3, "a reserve of 5 leaves 3 to load")
	check(String(g.plan_route("barge-1", one_stop(dest, {"Stone": 4}, {}))["errors"][0]).contains("reserve"), "routes can't take the reserve")
	check(g.plan_route("barge-1", one_stop(dest, {"Stone": 3}, {}))["errors"].is_empty(), "routes can take what's above it")
	g.set_reserve("Stone", 0)
	check(Economy.available_for_load(h, "Stone") == 8, "clearing the reserve frees everything")


# ------------------------------------------------------------------ Milestone 4

## Two different wagon destinations, the first selling something.
func two_wagon_stops(g: Game) -> Array:
	var r := Transport.reachable(g.state, g.state["home_id"], "wagon")
	return [r[0]["city"], r[1]["city"]]


func test_multi_stop_route() -> void:
	var g := new_game("multistop", 10)
	no_mouths(g)
	var s := g.state
	var ab := two_wagon_stops(g)
	var a: String = ab[0]
	var b: String = ab[1]
	var y: String = s["cities"][a]["produces"][0]
	Economy.add_stock(home_wh(g), "Salt", 4, 4 * 67500)
	var route := {
		"load": {"Salt": 4},
		"stops": [
			{"city": a, "sell": {"Salt": {"lots": -1}}, "buy": {y: {"lots": 6}}},
			{"city": b, "sell": {y: {"lots": -1}}, "buy": {}},
		],
		"repeat": false,
	}
	var p := g.plan_route("wagon-1", route)
	check(p["errors"].is_empty(), "a two-stop route plans %s" % str(p["errors"]))
	check(p["legs"].size() == 3, "home → A → B → home is three legs")
	check(p["stops"][1]["onboard"].get(y, 0) == 6, "the estimate carries goods bought at A to B")
	var fees_planned := int(p["fees"])
	var fees_before := int(s["ledger"]["current"]["trip_fees"])
	check(g.send_route("wagon-1", route)["errors"].is_empty(), "the route starts")
	var w := Transport.vehicle(s, "wagon-1")
	g.advance_hours(int(p["days"]) * 24)
	check(Transport.is_idle_at_home(s, w), "the wagon finishes the route and parks at home")
	check(int(w["stats"]["loops"]) == 1, "one loop completed")
	check(Economy.stock(home_wh(g), y) == 0 and w["cargo"].is_empty(), "everything bought at A was sold at B")
	check(news_contains(g, "in %s: sold 6 %s" % [s["cities"][b]["name"], y]), "the sale at B is reported")
	var ledger_fees := int(s["ledger"]["current"]["trip_fees"]) + int(s["ledger"]["last"]["trip_fees"]) - fees_before
	check(ledger_fees == fees_planned, "each leg's fee is charged once (%d vs %d)" % [ledger_fees, fees_planned])


func test_repeat_and_stop() -> void:
	var g := new_game("repeat", 10)
	no_mouths(g)
	var s := g.state
	var ab := two_wagon_stops(g)
	var y: String = s["cities"][ab[0]]["produces"][0]
	var route := {
		"load": {},
		"stops": [
			{"city": ab[0], "sell": {}, "buy": {y: {"lots": 2}}},
			{"city": ab[1], "sell": {y: {"lots": -1}}, "buy": {}},
		],
		"repeat": true,
	}
	var p := g.send_route("wagon-1", route)
	var w := Transport.vehicle(s, "wagon-1")
	g.advance_hours(int(p["days"]) * 24 * 2 + 1)
	check(int(w["stats"]["loops"]) >= 2, "a repeating route keeps going (%d loops)" % int(w["stats"]["loops"]))
	check(not w["route"].is_empty(), "it is still on its route")
	g.stop_route("wagon-1")
	g.advance_hours(int(p["days"]) * 24 + 1)
	check(Transport.is_idle_at_home(s, w), "after a stop request it finishes the loop and parks")
	check(not bool(w["stop_requested"]), "the stop request is cleared")


func test_price_limits() -> void:
	var g := new_game("limits", 10)
	no_mouths(g)
	var s := g.state
	var dest_info := barge_destination(g)
	var dest: String = dest_info["city"]
	var y: String = first_produced_except(s["cities"][dest], "Stone")
	Economy.add_stock(home_wh(g), "Stone", 5, 5 * 37500)
	var route := {
		"load": {"Stone": 5},
		"stops": [{"city": dest, "sell": {"Stone": {"lots": -1, "min": 10000000}}, "buy": {y: {"lots": 3, "max": 1}}}],
		"repeat": false,
	}
	var p := g.plan_route("barge-1", route)
	check(not p["warnings"].is_empty(), "the planner warns that limits block the trade")
	g.send_route("barge-1", route)
	g.advance_hours(int(dest_info["days"]) * 24 * 2)
	check(Economy.stock(home_wh(g), "Stone") == 5, "goods that didn't reach the minimum come home")
	check(Economy.stock(home_wh(g), y) == 0, "nothing is bought above the maximum")
	check(news_contains(g, "below your minimum") and news_contains(g, "above your maximum"), "skipped trades are logged")


func test_route_validation() -> void:
	var g := new_game("routecheck", 10)
	var s := g.state
	var ab := two_wagon_stops(g)
	var y: String = s["cities"][ab[0]]["produces"][0]
	var same := {"load": {}, "stops": [{"city": ab[0], "buy": {y: {"lots": 1}}}, {"city": ab[0], "sell": {y: {"lots": -1}}}]}
	check(not g.plan_route("wagon-1", same)["errors"].is_empty(), "the same city twice in a row is refused")
	var overflow := {"load": {}, "stops": [{"city": ab[0], "buy": {y: {"lots": 11}}}]}
	check(not g.plan_route("wagon-1", overflow)["errors"].is_empty(), "buying more than fits is refused")
	check(not g.plan_route("wagon-1", {"load": {}, "stops": []})["errors"].is_empty(), "a route needs a stop")
	var sell_nothing := {"load": {}, "stops": [{"city": ab[0], "sell": {"Salt": {"lots": -1}}}]}
	check(not g.plan_route("wagon-1", sell_nothing)["warnings"].is_empty(), "selling something not on board is warned about")


func test_committed_fees() -> void:
	var g := new_game("committed", 10)
	no_mouths(g)
	var s := g.state
	var ab := two_wagon_stops(g)
	var y: String = s["cities"][ab[0]]["produces"][0]
	var route := {"load": {}, "stops": [{"city": ab[0], "buy": {y: {"lots": 1}}}, {"city": ab[1], "sell": {y: {"lots": -1}}}]}
	var p := g.send_route("wagon-1", route)
	var expected := int(p["legs"][1]["fee"]) + int(p["legs"][2]["fee"])
	check(int(g.forecast()["committed_fees"]) == expected, "fees for the remaining legs are shown as committed")
