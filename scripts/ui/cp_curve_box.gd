class_name CPCurveBox
extends Control

# The HUD's live Critical Power display. Draws the rider's CP curve for this
# race (log-time x-axis, watts y-axis), a live dot per duration showing the
# current rolling average — green when fresh, red as that window fills — and
# a headroom "battery" strip along the bottom (1 − the most-depleted window).
# Self-refreshes from the CPLimiter reference; nobody pushes per-tick data.

const REDRAW_INTERVAL_S := 0.25
const BATTERY_H := 8.0
const PAD := 8.0

const CURVE_COLOR := Color(0.95, 0.78, 0.38)
const GRID_COLOR := Color(1, 1, 1, 0.18)
const TEXT_COLOR := Color(1, 1, 1, 0.7)
const FRESH_COLOR := Color(0.35, 0.9, 0.45)
const SPENT_COLOR := Color(0.95, 0.3, 0.25)

var _limiter: CPLimiter = null
var _accum := 0.0


func set_limiter(limiter: CPLimiter) -> void:
	_limiter = limiter
	queue_redraw()


func _process(delta: float) -> void:
	if _limiter == null or not is_visible_in_tree():
		return
	_accum += delta
	if _accum >= REDRAW_INTERVAL_S:
		_accum = 0.0
		queue_redraw()


func _x_at(i: int, w: float) -> float:
	# Log-time axis: 5s at the left edge, 60m at the right.
	var d := float(CPLimiter.DURATIONS_S[i])
	var t0 := log(float(CPLimiter.DURATIONS_S[0]))
	var t1 := log(float(CPLimiter.DURATIONS_S[CPLimiter.DURATIONS_S.size() - 1]))
	return PAD + (log(d) - t0) / (t1 - t0) * (w - PAD * 2.0)


func _draw() -> void:
	if _limiter == null or not _limiter.is_active():
		return
	var w := size.x
	var plot_h := size.y - BATTERY_H - 4.0 - PAD
	var vmax := 0.0
	for v in _limiter.curve_w:
		vmax = maxf(vmax, v)
	if vmax <= 0.0:
		return
	vmax *= 1.12

	var font := ThemeDB.fallback_font
	# Reference gridlines at the minute marks players actually pace by.
	for i in [3, 5, 8]:  # 1m, 5m, 20m
		var gx := _x_at(i, w)
		draw_line(Vector2(gx, PAD), Vector2(gx, PAD + plot_h), GRID_COLOR, 1.0)

	# The curve itself — this rider's ceiling for this race.
	var pts := PackedVector2Array()
	for i in CPLimiter.DURATIONS_S.size():
		var x := _x_at(i, w)
		var y := PAD + plot_h - (_limiter.curve_w[i] / vmax) * plot_h
		pts.append(Vector2(x, y))
	draw_polyline(pts, CURVE_COLOR, 2.0, true)

	# Live rolling averages: one dot per window, coloured by depletion.
	for i in CPLimiter.DURATIONS_S.size():
		var avg := _limiter.rolling_avg_w(i)
		var x := _x_at(i, w)
		var y := PAD + plot_h - (clampf(avg, 0.0, vmax) / vmax) * plot_h
		var col := FRESH_COLOR.lerp(SPENT_COLOR, _limiter.depletion(i))
		draw_circle(Vector2(x, y), 3.5, col)

	# Axis labels: ceiling watts and the ends of the time axis.
	draw_string(
		font, Vector2(PAD + 2.0, PAD + 12.0), "%d W" % int(vmax / 1.12),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_COLOR
	)
	draw_string(
		font, Vector2(PAD, PAD + plot_h - 3.0), "5s",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_COLOR
	)
	draw_string(
		font, Vector2(w - PAD - 26.0, PAD + plot_h - 3.0), "60m",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_COLOR
	)

	# Headroom battery: how much of the tightest window is left.
	var head := _limiter.headroom()
	var bar_y := size.y - BATTERY_H
	var bar_w := w - PAD * 2.0
	draw_rect(Rect2(PAD, bar_y, bar_w, BATTERY_H), Color(1, 1, 1, 0.12))
	var fill_col := SPENT_COLOR.lerp(FRESH_COLOR, head)
	draw_rect(Rect2(PAD, bar_y, bar_w * head, BATTERY_H), fill_col)
