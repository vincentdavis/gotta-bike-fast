class_name TiresSpec
extends RefCounted

# Mirrors gbf.physics.equipment.TiresSpec.

var mass_kg: float = 0.5  # both tires combined
var crr: float = 0.005
var size_mm: int = 25
var tread_type: String = "slick"  # "slick" | "file" | "knobby"
var cda_m2: float = 0.01
