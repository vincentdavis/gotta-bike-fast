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

# Loadout — picked rider's equipped Bike / Wheels / Tires. Empty Dictionary
# means nothing equipped in that slot; ride_controller falls back to the
# PhysicsKit defaults. Keys mirror the Django API response shape:
#   bike:   {name, brand, mass_kg, cda_m2}
#   wheels: {name, brand, mass_kg, cda_m2, depth_mm}
#   tires:  {name, brand, mass_kg, cda_m2, crr, size_mm, tread_type}
var rider_bike: Dictionary = {}
var rider_wheels: Dictionary = {}
var rider_tires: Dictionary = {}

# Game — populated by create / join, read by lobby + ride_controller.
var code: String = ""
var host_rider_id: String = ""
var course: Dictionary = {}
var participants: Array = []
var state: String = ""  # mirrors backend Game.state
var race_starts_at_unix_s: float = 0.0  # Unix epoch seconds (server clock)
var scheduled_start_at_unix_s: float = 0.0  # 0 = no schedule (manual start)
var is_solo: bool = false
# Host-set race time-scale (1.0 = real time). Read from the game detail on
# create/join; applied client-side in the ride, gated to keyboard riders.
var game_speed: float = 1.0

# Dev-menu return target. Set by whatever screen opens the dev menu so
# the menu's Back button can return there. The dev menu clears this on
# exit so a stale value doesn't redirect later navigation.
# Defaults to the landing page — safest fallback if nothing set it.
var dev_menu_return_scene: String = "res://scenes/main.tscn"

# Last camera view the player selected in a ride (index into CameraRig's
# preset list). Persists across rides within a session so a player who
# prefers, say, First Person doesn't have to re-pick it every ride. Resets
# to 0 (Chase) only on app restart.
var camera_view_index: int = 0


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
	# Loadout — present as a nested object when equipped, null otherwise.
	rider_bike = _as_dict(rider.get("bike"))
	rider_wheels = _as_dict(rider.get("wheels"))
	rider_tires = _as_dict(rider.get("tires"))


static func _as_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


func clear_rider() -> void:
	rider_id = ""
	rider_display_name = ""
	rider_weight_kg = 75.0
	rider_height_m = 1.75
	rider_ftp_w = 200
	rider_cda_factor = 1.0
	rider_bike = {}
	rider_wheels = {}
	rider_tires = {}


func has_rider() -> bool:
	return not rider_id.is_empty()


func loadout_summary() -> String:
	# Short one-line view of the equipped gear; "stock" for any empty slot.
	var bike: String = "stock"
	var wheels: String = "stock"
	var tires: String = "stock"
	if not rider_bike.is_empty():
		bike = str(rider_bike.get("name", "stock"))
	if not rider_wheels.is_empty():
		wheels = str(rider_wheels.get("name", "stock"))
	if not rider_tires.is_empty():
		tires = str(rider_tires.get("name", "stock"))
	return "Bike: %s · Wheels: %s · Tires: %s" % [bike, wheels, tires]


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
	game_speed = 1.0


func is_host() -> bool:
	return rider_id != "" and rider_id == host_rider_id
