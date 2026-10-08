## The news feed: market changes, trade results and (later) events.
extends RefCounted

const KIND_MARKET := "market"
const KIND_TRADE := "trade"
const KIND_CITY := "city"


static func add(state: Dictionary, text: String, kind := KIND_MARKET) -> void:
	state["news"].append({"t": int(state["time_hours"]), "text": text, "kind": kind})
