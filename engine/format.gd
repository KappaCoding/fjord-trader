## Number formatting shared by the engine (news text) and the UI.
extends RefCounted


## 1234567 -> "1,234,567"
static func coins(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


## 1234567 -> "+1,234,567"; -5 -> "-5"
static func signed(n: int) -> String:
	return ("+" if n > 0 else "") + coins(n)


## {"Salt": 10, "Fish": 2} -> "10 Salt, 2 Fish" (catalogue order is the caller's job)
static func lots_list(pairs: Array) -> String:
	var parts: PackedStringArray = []
	for p in pairs:
		parts.append("%d %s" % [int(p[1]), p[0]])
	return ", ".join(parts)
