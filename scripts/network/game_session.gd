extends Node

# Shared state across the menu → lobby → ride flow. Set by the menu /
# lobby screens; read by ride_controller to decide whether to run the
# game (countdown + WS) or the solo (immediate ride) path.

var code: String = ""
var rider_id: String = ""
var host_rider_id: String = ""
var course: Dictionary = {}
var participants: Array = []
var state: String = ""  # mirrors backend Game.state
var race_starts_at_unix_s: float = 0.0  # Unix epoch seconds (server clock)
var scheduled_start_at_unix_s: float = 0.0  # 0 = no schedule (manual start)
var is_solo: bool = false


static func parse_iso_to_unix(iso: String) -> float:
	if iso.is_empty():
		return 0.0
	var clean := iso.split(".")[0]
	var dict := Time.get_datetime_dict_from_datetime_string(clean, true)
	if dict.is_empty():
		return 0.0
	return float(Time.get_unix_time_from_datetime_dict(dict))


func reset() -> void:
	code = ""
	rider_id = ""
	host_rider_id = ""
	course = {}
	participants = []
	state = ""
	race_starts_at_unix_s = 0.0
	scheduled_start_at_unix_s = 0.0
	is_solo = false


func is_host() -> bool:
	return rider_id != "" and rider_id == host_rider_id
