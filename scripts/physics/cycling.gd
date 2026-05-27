class_name CyclingPhysics
extends RefCounted

# Port of src/gbf/physics/cycling.py — both implementations must produce
# the same outputs for the same inputs. See the Python module for the
# force model derivation. PhysicsKit aggregates rider/bike/wheels/tires/
# settings into the inputs used here.

const STANDSTILL_V_MPS := 0.5


static func step_velocity(
	power_w: float,
	velocity_mps: float,
	gradient: float,
	kit: PhysicsKit,
	dt_s: float,
	draft_multiplier: float = 1.0,
) -> float:
	if dt_s <= 0.0:
		return velocity_mps

	var m: float = kit.total_mass_kg()
	var cda: float = kit.total_cda_m2() * draft_multiplier
	var crr: float = kit.effective_crr()
	var g: float = kit.settings.gravity_mps2
	var rho: float = kit.settings.air_density_kgpm3

	var v_for_drive: float = max(velocity_mps, STANDSTILL_V_MPS)
	var f_drive: float = power_w / v_for_drive

	var f_gravity: float = m * g * gradient
	var f_rolling: float = m * g * crr
	var f_aero: float = 0.5 * rho * cda * velocity_mps * velocity_mps

	var f_net: float = f_drive - f_gravity - f_rolling - f_aero
	var new_v: float = velocity_mps + (f_net / m) * dt_s
	return max(new_v, 0.0)
