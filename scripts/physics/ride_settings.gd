class_name RideSettings
extends RefCounted

# Mirrors gbf.physics.equipment.RideSettings — applies to every rider in
# the session.

var draft_strength_factor: float = 1.0
var surface_rolling_factor: float = 1.0
var air_density_kgpm3: float = 1.225
var gravity_mps2: float = 9.81
var rider_cda_factor: float = 1.0  # global multiplier on every rider's CdA
