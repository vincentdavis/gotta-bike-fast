extends Node

# Shared state across the menu → lobby → ride flow. Set by the riders /
# menu / lobby screens; read by ride_controller to decide whether to run
# the game (countdown + WS) or the solo (immediate ride) path.

# Rider — populated by the rider picker. Carries through to game create /
# join and into the physics kit at ride start.
var rider_id: String = ""
var rider_display_name: String = ""
var rider_weight_kg: float = 75.0
var rider_height_m: float = 1.75
var rider_ftp_w: int = 200
var rider_cda_factor: float = 1.0

# Game — populated by create / join, read by lobby + ride_controller.
var code: String = ""
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


func set_rider(rider: Dictionary) -> void:
	rider_id = str(rider.get("id", ""))
	rider_display_name = str(rider.get("display_name", ""))
	rider_weight_kg = float(rider.get("weight_kg", 75.0))
	rider_height_m = float(rider.get("height_m", 1.75))
	rider_ftp_w = int(rider.get("ftp_w", 200))
	rider_cda_factor = float(rider.get("cda_factor", 1.0))


func clear_rider() -> void:
	rider_id = ""
	rider_display_name = ""
	rider_weight_kg = 75.0
	rider_height_m = 1.75
	rider_ftp_w = 200
	rider_cda_factor = 1.0


func has_rider() -> bool:
	return not rider_id.is_empty()


func reset() -> void:
	# Wipes game state only — the picked rider survives a return-to-menu.
	code = ""
	host_rider_id = ""
	course = {}
	participants = []
	state = ""
	race_starts_at_unix_s = 0.0
	scheduled_start_at_unix_s = 0.0
	is_solo = false


func is_host() -> bool:
	return rider_id != "" and rider_id == host_rider_id
