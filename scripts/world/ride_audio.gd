class_name RideAudio
extends Node

# Procedural ride audio — the game's first sound, no asset files anywhere.
# Everything is synthesized at _ready():
#   - a seamless looping wind/road noise bed whose volume + pitch follow the
#     rider's speed (silent at a standstill)
#   - countdown ticks and the GO beep
#   - a three-note finish stinger
# GraphicsSettings.sound_enabled (persisted; M toggles it in a ride) gates
# every voice, so muting needs no node teardown.

const MIX_RATE := 22050
const WIND_SILENT_DB := -80.0

var _wind: AudioStreamPlayer = null
var _beep: AudioStreamPlayer = null
var _tick_stream: AudioStreamWAV
var _go_stream: AudioStreamWAV
var _finish_stream: AudioStreamWAV


func _ready() -> void:
	_wind = AudioStreamPlayer.new()
	_wind.stream = _noise_loop(2.0)
	_wind.volume_db = WIND_SILENT_DB
	add_child(_wind)
	_wind.play()
	_beep = AudioStreamPlayer.new()
	_beep.volume_db = -8.0
	add_child(_beep)
	_tick_stream = _tone([[880.0, 0.12]])
	_go_stream = _tone([[1318.5, 0.35]])
	_finish_stream = _tone([[659.3, 0.15], [880.0, 0.15], [1108.7, 0.3]])


func set_speed(speed_mps: float) -> void:
	# Wind bed: fades in from ~2 m/s, full by ~16 m/s, pitch rising with it.
	if not GraphicsSettings.sound_enabled:
		_wind.volume_db = WIND_SILENT_DB
		return
	var t := clampf((speed_mps - 2.0) / 14.0, 0.0, 1.0)
	_wind.volume_db = lerpf(-46.0, -16.0, sqrt(t)) if t > 0.0 else WIND_SILENT_DB
	_wind.pitch_scale = lerpf(0.85, 1.35, t)


func countdown_tick() -> void:
	_play(_tick_stream)


func go() -> void:
	_play(_go_stream)


func finish() -> void:
	_play(_finish_stream)


func _play(stream: AudioStreamWAV) -> void:
	if not GraphicsSettings.sound_enabled:
		return
	_beep.stream = stream
	_beep.play()


static func _noise_loop(seconds: float) -> AudioStreamWAV:
	# White noise through a one-pole lowpass → wind-ish rumble, then the head
	# is crossfaded with the tail and the tail dropped so the loop is
	# click-free (the loop region ends exactly where the blended head began).
	var n := int(MIX_RATE * seconds)
	var fade := int(MIX_RATE * 0.08)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xA0D10
	var lp := 0.0
	for i in n:
		lp += 0.08 * (rng.randf_range(-1.0, 1.0) - lp)
		samples[i] = clampf(lp * 3.0, -1.0, 1.0)
	var m := n - fade
	for i in fade:
		var t := float(i) / float(fade)
		samples[i] = samples[i] * t + samples[m + i] * (1.0 - t)
	var data := PackedByteArray()
	data.resize(m * 2)
	for i in m:
		data.encode_s16(i * 2, int(samples[i] * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = m
	return wav


static func _tone(notes: Array) -> AudioStreamWAV:
	# notes: [[freq_hz, seconds], ...] — sine with a 10 ms attack and a
	# linear decay per note, concatenated.
	var total := 0
	for note in notes:
		total += int(MIX_RATE * float(note[1]))
	var data := PackedByteArray()
	data.resize(total * 2)
	var pos := 0
	for note in notes:
		var freq: float = note[0]
		var n := int(MIX_RATE * float(note[1]))
		for i in n:
			var env := minf(1.0, float(i) / (float(MIX_RATE) * 0.01))
			env *= 1.0 - float(i) / float(n)
			var v := sin(TAU * freq * float(i) / float(MIX_RATE)) * env
			data.encode_s16((pos + i) * 2, int(v * 24000.0))
		pos += n
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
