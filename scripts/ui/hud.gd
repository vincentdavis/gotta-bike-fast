extends CanvasLayer

@onready var power_label: Label = $VBox/PowerLabel
@onready var speed_label: Label = $VBox/SpeedLabel
@onready var distance_label: Label = $VBox/DistanceLabel
@onready var grade_label: Label = $VBox/GradeLabel
@onready var time_label: Label = $VBox/TimeLabel
@onready var draft_label: Label = $VBox/DraftLabel
@onready var course_label: Label = $VBox/CourseLabel
@onready var status_label: Label = $VBox/StatusLabel
@onready var countdown_label: Label = $CountdownLabel


func set_power(w: float) -> void:
	power_label.text = "Power: %d W" % int(round(w))


func set_speed(mps: float) -> void:
	speed_label.text = "Speed: %.1f km/h" % (mps * 3.6)


func set_distance(m: float) -> void:
	if m >= 1000.0:
		distance_label.text = "Distance: %.2f km" % (m / 1000.0)
	else:
		distance_label.text = "Distance: %d m" % int(m)


func set_grade(percent: float) -> void:
	grade_label.text = "Grade: %+.1f%%" % percent


func set_elapsed(s: float) -> void:
	var total: int = int(s)
	var minutes: int = total / 60
	var seconds: int = total % 60
	time_label.text = "Time: %d:%02d" % [minutes, seconds]


func set_draft(savings_pct: int) -> void:
	draft_label.text = "Draft: %d%%" % savings_pct
	# Tint cyan when actively drafting, white otherwise.
	if savings_pct > 0:
		draft_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	else:
		draft_label.remove_theme_color_override("font_color")


func set_course(name: String, length_m: float) -> void:
	course_label.text = "%s · %.1f km" % [name, length_m / 1000.0]


func set_status(text: String) -> void:
	status_label.text = text


func show_countdown(seconds_remaining: float) -> void:
	if seconds_remaining <= 0.0:
		countdown_label.text = "GO!"
	elif seconds_remaining < 1.0:
		countdown_label.text = "GO!"
	else:
		countdown_label.text = "%d" % int(ceil(seconds_remaining))


func hide_countdown() -> void:
	countdown_label.text = ""
