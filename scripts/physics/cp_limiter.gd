class_name CPLimiter
extends RefCounted

# Rolling-window Critical Power limiter for virtual (keyboard) riders.
#
# A rider's CP curve is 12 points: max average power (W) they can hold for
# each duration. This class enforces every point as a rolling-window cap over
# SIM time — burn a big 15s effort and the 1–5 min windows fill up, so
# "fatigue" emerges from the curve with no extra state. Mirrors the reference
# math in the web repo's riders/cp.py (presets, ACP area, race-limit clamp);
# keep the two in sync.
#
# Bookkeeping: 1-sim-second energy buckets in a ring, one rolling sum per
# duration maintained incrementally (add the completed bucket, drop the one
# leaving the window). allowed_power_w() budgets the NEXT second and credits
# the bucket about to roll off, so riding steadily at a cap holds that cap
# instead of sawtoothing between 0 and full power.

const DURATIONS_S: Array[int] = [5, 15, 30, 60, 120, 300, 600, 900, 1200, 1800, 2700, 3600]
const RING_SIZE := 3600  # newest RING_SIZE completed 1s buckets (= longest window)

# Rider-style presets in W/kg — mirror of riders/cp.py CP_STYLE_PRESETS_WKG.
# Fallback when a rider profile predates CP curves.
const PRESETS_WKG := {
	"rouleur": [17.0, 14.0, 10.5, 7.8, 5.9, 4.6, 4.15, 4.0, 3.9, 3.75, 3.6, 3.5],
	"sprinter": [22.0, 18.0, 13.0, 9.0, 6.2, 4.4, 3.8, 3.6, 3.5, 3.3, 3.15, 3.0],
	"puncheur": [19.0, 16.0, 12.5, 9.5, 6.8, 4.9, 4.2, 4.0, 3.85, 3.65, 3.5, 3.4],
	"climber": [14.0, 11.5, 9.0, 7.0, 5.6, 4.9, 4.5, 4.35, 4.25, 4.1, 3.95, 3.85],
	"tt": [13.0, 10.5, 8.5, 6.8, 5.4, 4.8, 4.55, 4.45, 4.35, 4.25, 4.15, 4.05],
}

var curve_w: Array[float] = []  # cap in watts per duration (post race-limit clamp)

var _ring: PackedFloat64Array = PackedFloat64Array()
var _pos: int = 0            # ring slot the CURRENT bucket will land in
var _cur_energy: float = 0.0  # J accumulated into the current (partial) bucket
var _cur_fill: float = 0.0    # sim-seconds accumulated into the current bucket
var _sums: Array[float] = []  # rolling energy per duration over completed buckets (J)


func setup(curve_watts: Array) -> void:
	curve_w.clear()
	for v in curve_watts:
		curve_w.append(float(v))
	_ring = PackedFloat64Array()
	_ring.resize(RING_SIZE)
	_pos = 0
	_cur_energy = 0.0
	_cur_fill = 0.0
	_sums.clear()
	for _d in DURATIONS_S:
		_sums.append(0.0)


func is_active() -> bool:
	return curve_w.size() == DURATIONS_S.size()


func add_sample(power_w: float, sim_dt: float) -> void:
	# Accumulate energy into 1s buckets, completing as many as sim_dt spans.
	if not is_active():
		return
	var remaining := sim_dt
	while remaining > 0.0:
		var step: float = min(remaining, 1.0 - _cur_fill)
		_cur_energy += power_w * step
		_cur_fill += step
		remaining -= step
		if _cur_fill >= 0.999999:
			_complete_bucket()


func _complete_bucket() -> void:
	_ring[_pos] = _cur_energy
	for i in DURATIONS_S.size():
		# Window of size d now covers slots (_pos - d + 1) … _pos.
		var leaving := _ring[_wrap(_pos - DURATIONS_S[i])]
		_sums[i] += _cur_energy - leaving
	_pos = _wrap(_pos + 1)
	_cur_energy = 0.0
	_cur_fill = 0.0


func _wrap(i: int) -> int:
	return ((i % RING_SIZE) + RING_SIZE) % RING_SIZE


func allowed_power_w() -> float:
	# Max power spendable over roughly the next second without busting any
	# window: remaining budget + the bucket that rolls off next. Instantaneous
	# power is additionally capped at the 5s point (your true sprint max).
	if not is_active():
		return INF
	var allowed := curve_w[0]
	for i in DURATIONS_S.size():
		var budget := curve_w[i] * float(DURATIONS_S[i])
		var used := _sums[i] + _cur_energy
		var refill := _ring[_wrap(_pos - DURATIONS_S[i])]
		allowed = min(allowed, budget - used + refill)
	return maxf(allowed, 0.0)


func rolling_avg_w(i: int) -> float:
	# Current rolling average over duration i — the HUD's live dots.
	if not is_active():
		return 0.0
	return (_sums[i] + _cur_energy) / float(DURATIONS_S[i])


func depletion(i: int) -> float:
	# 0 = fresh, 1 = that window is riding its cap.
	if not is_active() or curve_w[i] <= 0.0:
		return 0.0
	return clampf((_sums[i] + _cur_energy) / (curve_w[i] * float(DURATIONS_S[i])), 0.0, 1.0)


func headroom() -> float:
	# The "battery": 1 − the most-depleted window. Hits 0 when any cap binds.
	var worst := 0.0
	for i in DURATIONS_S.size():
		worst = maxf(worst, depletion(i))
	return 1.0 - worst


static func preset_wkg(style: String) -> Array:
	return PRESETS_WKG.get(style, PRESETS_WKG["rouleur"])


static func curve_from_wkg(wkg: Array, weight_kg: float) -> Array[float]:
	var out: Array[float] = []
	for v in wkg:
		out.append(float(v) * weight_kg)
	return out


static func acp_kj(curve: Array) -> float:
	# Area under a CP curve (trapezoids; 0→5s flat) — riders/cp.py acp_kj.
	if curve.size() != DURATIONS_S.size():
		return 0.0
	var area := float(curve[0]) * float(DURATIONS_S[0])
	for i in DURATIONS_S.size() - 1:
		var dt := float(DURATIONS_S[i + 1] - DURATIONS_S[i])
		area += (float(curve[i]) + float(curve[i + 1])) / 2.0 * dt
	return area / 1000.0


static func clamp_curve_to_limits(
	curve: Array, weight_kg: float, limits: Dictionary
) -> Array[float]:
	# Fit a curve (W) inside a race's limits — riders/cp.py clamp_to_limits.
	# Per-point caps first (running min keeps the curve non-increasing), then
	# a proportional scale down to the tighter ACP budget.
	var out: Array[float] = []
	for v in curve:
		out.append(float(v))
	if limits.is_empty():
		return out
	var cap_w: Dictionary = limits.get("max_cp_w") if limits.get("max_cp_w") is Dictionary else {}
	var cap_wkg: Dictionary = (
		limits.get("max_cp_wkg") if limits.get("max_cp_wkg") is Dictionary else {}
	)
	for i in DURATIONS_S.size():
		var key := str(DURATIONS_S[i])
		var v := out[i]
		if cap_w.has(key):
			v = minf(v, float(cap_w[key]))
		if cap_wkg.has(key):
			v = minf(v, float(cap_wkg[key]) * weight_kg)
		if i > 0 and v > out[i - 1]:
			v = out[i - 1]
		out[i] = v

	var allowed := INF
	if limits.get("max_acp_kj") != null:
		allowed = minf(allowed, float(limits["max_acp_kj"]))
	if limits.get("max_acp_kj_per_kg") != null:
		allowed = minf(allowed, float(limits["max_acp_kj_per_kg"]) * weight_kg)
	var area := acp_kj(out)
	if area > allowed and area > 0.0:
		var factor := allowed / area
		for i in out.size():
			out[i] *= factor
	return out
