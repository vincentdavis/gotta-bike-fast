class_name PhysicsKit
extends RefCounted

# Bundle of all five physics config groups plus aggregation helpers.
# Mirrors gbf.physics.equipment.PhysicsKit.

const RIDER_CDA_BASE := 0.30
const RIDER_CDA_MASS_REF_KG := 75.0
const RIDER_CDA_HEIGHT_REF_M := 1.75
const RIDER_CDA_MASS_EXP := 0.425
const RIDER_CDA_HEIGHT_EXP := 0.725

var rider: RiderProfile = RiderProfile.new()
var bike: BikeSpec = BikeSpec.new()
var wheels: WheelsSpec = WheelsSpec.new()
var tires: TiresSpec = TiresSpec.new()
var settings: RideSettings = RideSettings.new()


func total_mass_kg() -> float:
	return rider.mass_kg + bike.mass_kg + wheels.mass_kg + tires.mass_kg


func rider_cda() -> float:
	var mass_term: float = pow(rider.mass_kg / RIDER_CDA_MASS_REF_KG, RIDER_CDA_MASS_EXP)
	var height_term: float = pow(rider.height_m / RIDER_CDA_HEIGHT_REF_M, RIDER_CDA_HEIGHT_EXP)
	return RIDER_CDA_BASE * mass_term * height_term * rider.cda_factor


func total_cda_m2() -> float:
	return (
		rider_cda() * settings.rider_cda_factor
		+ bike.cda_m2
		+ wheels.cda_m2
		+ tires.cda_m2
	)


func effective_crr() -> float:
	return tires.crr * settings.surface_rolling_factor
