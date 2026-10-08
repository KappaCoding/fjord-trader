## Shared colours and small widget helpers for the dashboard.
extends RefCounted

const WANT := Color("73d973")
const SURPLUS := Color("f2ad52")
const NEUTRAL := Color("d9d9d9")
const MUTED := Color("9a9a9a")
const BAD := Color("ff7a7a")
const WARN := Color("ffc861")
const GOOD := Color("73d973")
const HOME := Color("ffd166")
const TRADE_NEWS := Color("9fd3ff")
const CITY_NEWS := Color("ffd98a")

const ROUTE_COLORS := {"land": Color("d2ae6d"), "sheltered": Color("6cc8f0"), "ocean": Color("5b93f0")}
const VEHICLE_COLORS := {"wagon": Color("e8b75c"), "barge": Color("7fd8ff"), "coastal": Color("a8e6ff"), "ocean": Color("8fb2ff")}
const ROUTE_NAMES := {"land": "Road", "sheltered": "Sheltered water", "ocean": "Open sea"}


static func band_color(band: String) -> Color:
	match band:
		"want":
			return WANT
		"surplus":
			return SURPLUS
	return NEUTRAL


static func band_label(band: String) -> String:
	match band:
		"want":
			return "Wants"
		"surplus":
			return "Produces"
	return "Normal"


static func hex(c: Color) -> String:
	return c.to_html(false)


static func label(text: String, color := Color(0, 0, 0, 0), font_size := 0) -> Label:
	var l := Label.new()
	l.text = text
	if color.a > 0.0:
		l.add_theme_color_override("font_color", color)
	if font_size > 0:
		l.add_theme_font_size_override("font_size", font_size)
	return l


static func heading(text: String) -> Label:
	var l := label(text, Color("e8e8e8"), 17)
	return l


static func rich(fit := true) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = fit
	r.scroll_active = false
	r.selection_enabled = false
	return r


static func right(l: Label) -> Label:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


## "12 days" / "1 day"
static func days(n: int) -> String:
	return "%d day%s" % [n, "" if n == 1 else "s"]
