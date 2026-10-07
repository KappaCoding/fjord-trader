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
