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


## A city the barge can reach, and the path there.
func barge_destination(g: Game) -> Dictionary:
	return Transport.reachable(g.state, g.state["home_id"], "barge")[0]


func news_contains(g: Game, needle: String) -> bool:
	for entry in g.state["news"]:
		if String(entry["text"]).contains(needle):
			return true
	return false


func test_start_state() -> void:
	var g := new_game("start", 10)
	var s := g.state
	check(int(s["treasury"]) == 3000000, "start with 3,000,000")
	check(s["vehicles"].size() == 2, "start with two vehicles")
	check(s["vehicles"][0]["type"] == "wagon" and s["vehicles"][1]["type"] == "barge", "a wagon and a barge")
	for v in s["vehicles"]:
		check(Transport.is_idle_at_home(s, v), "%s starts idle at home" % v["name"])
	check(g.home()["lines"].size() == 2, "Stage 1 home has two lines")
	check(g.needs_line_choice(), "lines start unassigned")
	check(g.net_worth() == 3000000 + 1700000 + 1000000, "start net worth = treasury + vehicles + lines")


func test_production() -> void:
	var g := new_game("production", 10)
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
	# Tax minimum
	g.state["treasury"] = 1000000
	check(int(g.forecast()["tax"]) == 25000, "tax never below the Stage 1 minimum of 25,000")


func test_storage_fee() -> void:
	var g := new_game("storage", 10)
	Economy.add_stock(home_wh(g), "Salt", 10, 1000000)
	check(int(g.forecast()["storage"]) == 5000, "storage fee is 0.5% of stock value per month")
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
	var s := g.state
	var dest_info := barge_destination(g)
	var dest: String = dest_info["city"]
	var days: int = dest_info["days"]
	var buy_good: String = s["cities"][dest]["produces"][0]
	Economy.add_stock(home_wh(g), "Stone", 15, 15 * 37500)
	var p := g.plan_trip("barge-1", dest, {"Stone": 15}, {buy_good: 5})
	check(p["errors"].is_empty(), "a valid trip plans without errors %s" % str(p["errors"]))
	check(int(p["fee_out"]) == int(round(40000.0 * days / 30.0)), "barge fee is 40,000 ÷ 30 per day of travel")
	check(int(p["cargo_out"]) == 15 and int(p["cargo_back"]) == 5, "cargo counts")
	var before := int(s["treasury"])
	var r := g.send_trip("barge-1", dest, {"Stone": 15}, {buy_good: 5})
	check(r["errors"].is_empty(), "the trip is sent")
	check(int(s["treasury"]) == before - int(p["fee_out"]), "the outbound fee is paid on departure")
	check(Economy.stock(home_wh(g), "Stone") == 0, "cargo leaves the warehouse")
	var barge := Transport.vehicle(s, "barge-1")
	check(barge["location"] == "" and Economy.stock(barge["cargo"], "Stone") == 15, "the barge carries the cargo")

	# Predict the trade exactly: on the arrival hour, markets step first, then the vehicle trades.
	g.advance_hours(days * 24 - 1)
	var copy: Dictionary = s.duplicate(true)
	Market.step_market(copy["cities"][dest], 1)
	var expected_sales := Economy.sum(Market.sell_lot_prices(copy, dest, "Stone", 15))
	var expected_cost := Economy.sum(Market.buy_lot_prices(copy, dest, buy_good, 5))
	check(Economy.stock(barge["cargo"], "Stone") == 15, "still travelling one hour before arrival")
	g.advance_hours(1)
	check(int(barge["trip"]["result"]["sales"]) == expected_sales, "cargo sells at the arrival price, lot by lot")
	check(int(barge["trip"]["result"]["purchases"]) == expected_cost, "goods are bought at the arrival price")
	check(Economy.stock(barge["cargo"], buy_good) == 5, "bought goods are on board")
	check(barge["trip"]["phase"] == "back", "the barge heads home")
	check(news_contains(g, "in %s: sold 15 Stone" % s["cities"][dest]["name"]), "the trade is reported in the news")
	g.advance_hours(days * 24)
	check(Transport.is_idle_at_home(s, barge), "the barge is home and idle")
	check(Economy.stock(home_wh(g), buy_good) == 5, "bought goods are unloaded into the warehouse")
	check(int(home_wh(g)[buy_good]["cost"]) == expected_cost, "unloaded goods keep their purchase cost")


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
	check(String(g.plan_trip("wagon-1", overseas, {"Stone": 1}, {})["errors"][0]).contains("can't reach"), "a wagon can't reach overseas")
	check(not g.plan_trip("barge-1", dest, {"Stone": 25}, {})["errors"].is_empty(), "can't overload the barge")
	check(not g.plan_trip("barge-1", dest, {}, {not_sold: 1})["errors"].is_empty(), "can't buy what the city doesn't sell")
	check(not g.plan_trip("barge-1", dest, {"Salt": 1}, {})["errors"].is_empty(), "can't sell what you don't have")
	check(not g.plan_trip("barge-1", dest, {}, {})["errors"].is_empty(), "an empty trip is refused")
	check(not g.plan_trip("barge-1", s["home_id"], {"Stone": 1}, {})["errors"].is_empty(), "home isn't a destination")
	g.send_trip("barge-1", dest, {"Stone": 5}, {})
	check(not g.plan_trip("barge-1", dest, {"Stone": 5}, {})["errors"].is_empty(), "a vehicle away can't be sent again")
	s["treasury"] = 0
	check(not g.plan_trip("wagon-1", dest, {"Stone": 5}, {})["errors"].is_empty() or Transport.path_for(s, s["home_id"], dest, "wagon")["days"] < 0, "no trip without money for the fee")


func test_trip_short_of_money() -> void:
	var g := new_game("short", 10)
	var s := g.state
	var dest_info := barge_destination(g)
	var dest: String = dest_info["city"]
	var good: String = s["cities"][dest]["produces"][0]
	var fee := Transport.trip_fee("barge", dest_info["days"])
	var price := Market.listed_price(s, dest, good)
	s["treasury"] = fee + int(price * 2.5) + 60000  # running costs eat a little on the way
	g.send_trip("barge-1", dest, {}, {good: 10})
	g.advance_hours(int(dest_info["days"]) * 24)
	var got := Economy.stock(Transport.vehicle(s, "barge-1")["cargo"], good)
	check(got >= 1 and got < 10, "buys only what it can afford (%d of 10)" % got)
	check(news_contains(g, "Couldn't afford everything"), "the shortfall is reported")


func test_retooling() -> void:
	var g := new_game("retool", 10)
	var opts: Array = g.home()["production_options"]
	var a: String = opts[0]
	var b: String = opts[1]
	g.choose_line(0, a)
	g.advance_hours(720)
	var a_before := Economy.stock(home_wh(g), a)
	var before := int(g.state["treasury"])
	var worth_before := g.net_worth()
	check(g.choose_line(0, a) != "", "retooling to the same good is refused")
	check(g.choose_line(0, "Gold") != "", "can't produce what home can't make")
	check(g.choose_line(0, b) == "", "retooling starts")
	check(int(g.state["treasury"]) == before - 125000, "retooling costs 25% of 500,000")
	check(g.net_worth() == worth_before - 125000, "retooling is a cost, not an asset")
	check(g.choose_line(0, a) != "", "can't retool a line that is already retooling")
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
	a.send_trip("barge-1", dest, {opts[0]: 5}, {})
	a.advance_hours(24 * 3)
	var path := "user://test_midtrip.sav"
	a.save_to(path)
	var b := Game.new()
	check(b.load_from(path), "a game saved mid-trip loads")
	a.advance_hours(24 * 60)
	b.advance_hours(24 * 60)
	check(SaveLoad.to_json(a.state, a.rng) == SaveLoad.to_json(b.state, b.rng), "a loaded mid-trip game continues identically")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
