class_name RideAudio
extends Node

# Procedural ride audio — the game's sound, no asset files anywhere.
# Everything is synthesized at _ready():
#   - a seamless looping wind/road noise bed whose volume + pitch follow the
#     rider's speed (silent at a standstill)
#   - freewheel pawl clicks while coasting, rate rising with speed
#   - a crowd murmur that swells as the road passes through a village,
#     and a cheering swell at a race finish
#   - countdown ticks, the GO beep, and a three-note finish stinger
# GraphicsSettings.sound_enabled (persisted; M toggles it in a ride) gates
# every voice, so muting needs no node teardown.

const MIX_RATE := 22050
const SILENT_DB := -80.0

var _wind: AudioStreamPlayer = null
var _freewheel: AudioStreamPlayer = null
var _crowd: AudioStreamPlayer = null
var _beep: AudioStreamPlayer = null
var _cheer_player: AudioStreamPlayer = null
var _tick_stream: AudioStreamWAV
var _go_stream: AudioStreamWAV
var _finish_stream: AudioStreamWAV
var _cheer_stream: AudioStreamWAV


func _ready() -> void:
	_wind = _looping_player(_noise_loop(2.0))
	_freewheel = _looping_player(_click_loop())
	_crowd = _looping_player(_murmur_loop())
	_beep = AudioStreamPlayer.new()
	_beep.volume_db = -8.0
	add_child(_beep)
	_cheer_player = AudioStreamPlayer.new()
	_cheer_player.volume_db = -10.0
	add_child(_cheer_player)
	_tick_stream = _tone([[880.0, 0.12]])
	_go_stream = _tone([[1318.5, 0.35]])
	_finish_stream = _tone([[659.3, 0.15], [880.0, 0.15], [1108.7, 0.3]])
	_cheer_stream = _cheer_swell()


func _looping_player(stream: AudioStreamWAV) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = SILENT_DB
	add_child(p)
	p.play()
	return p


func update(speed_mps: float, power_w: float, town_proximity: float) -> void:
	# Per-tick mix. town_proximity: 0 = open country, 1 = village centre.
	if not GraphicsSettings.sound_enabled:
		_wind.volume_db = SILENT_DB
		_freewheel.volume_db = SILENT_DB
		_crowd.volume_db = SILENT_DB
		return
	# Wind bed: fades in from ~2 m/s, full by ~16 m/s, pitch rising with it.
	var t := clampf((speed_mps - 2.0) / 14.0, 0.0, 1.0)
	_wind.volume_db = lerpf(-46.0, -16.0, sqrt(t)) if t > 0.0 else SILENT_DB
	_wind.pitch_scale = lerpf(0.85, 1.35, t)
	# Freewheel: only rolling without pedaling; click rate follows speed.
	if power_w < 5.0 and speed_mps > 1.5:
		_freewheel.volume_db = -15.0
		_freewheel.pitch_scale = clampf(speed_mps / 8.0, 0.6, 2.2)
	else:
		_freewheel.volume_db = SILENT_DB
	# Village crowd murmur.
	if town_proximity > 0.05:
		_crowd.volume_db = lerpf(-38.0, -13.0, town_proximity)
	else:
		_crowd.volume_db = SILENT_DB


func countdown_tick() -> void:
	_play(_tick_stream)


func go() -> void:
	_play(_go_stream)


func finish() -> void:
	_play(_finish_stream)


func cheer() -> void:
	# Race finishes get the crowd on top of the stinger (separate player so
	# they overlap).
	if not GraphicsSettings.sound_enabled:
		return
	_cheer_player.stream = _cheer_stream
	_cheer_player.play()


func _play(stream: AudioStreamWAV) -> void:
	if not GraphicsSettings.sound_enabled:
		return
	_beep.stream = stream
	_beep.play()


static func _loop_wav(samples: PackedFloat32Array, fade_s: float) -> AudioStreamWAV:
	# Seamless loop: crossfade the head with the tail, drop the tail, so the
	# loop region ends exactly where the blended head began — click-free.
	var n := samples.size()
	var fade := int(MIX_RATE * fade_s)
	var m := n - fade
	for i in fade:
		var t := float(i) / float(fade)
		samples[i] = samples[i] * t + samples[m + i] * (1.0 - t)
	var wav := _wav_from(samples, m)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = m
	return wav


static func _wav_from(samples: PackedFloat32Array, count: int = -1) -> AudioStreamWAV:
	var m := samples.size() if count < 0 else count
	var data := PackedByteArray()
	data.resize(m * 2)
	for i in m:
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav


static func _noise_loop(seconds: float) -> AudioStreamWAV:
	# White noise through a one-pole lowpass → wind-ish rumble.
	var n := int(MIX_RATE * seconds)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xA0D10
	var lp := 0.0
	for i in n:
		lp += 0.08 * (rng.randf_range(-1.0, 1.0) - lp)
		samples[i] = clampf(lp * 3.0, -1.0, 1.0)
	return _loop_wav(samples, 0.08)


static func _click_loop() -> AudioStreamWAV:
	# Freewheel pawls: 12 clicks/s at pitch 1.0 (each a ~4 ms noise burst);
	# pitch_scale sweeps the click rate with speed.
	var n := MIX_RATE
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC11C5
	for c in 12:
		var start := int(float(c) * float(n) / 12.0)
		for i in 90:
			samples[start + i] += rng.randf_range(-1.0, 1.0) * exp(-float(i) / 18.0) * 0.8
	var wav := _wav_from(samples)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = n
	return wav


static func _murmur_loop() -> AudioStreamWAV:
	# Village crowd: two noise layers under slow amplitude waves (integer
	# cycle counts, so the AM is continuous across the loop seam).
	var n := MIX_RATE * 2
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC20D
	var deep := 0.0
	var mid := 0.0
	for i in n:
		deep += 0.03 * (rng.randf_range(-1.0, 1.0) - deep)
		mid += 0.15 * (rng.randf_range(-1.0, 1.0) - mid)
		var t := float(i) / float(n)
		var am := 0.65 + 0.25 * sin(TAU * 3.0 * t) + 0.10 * sin(TAU * 7.0 * t)
		samples[i] = clampf((deep * 5.0 + mid * 0.6) * am, -1.0, 1.0)
	return _loop_wav(samples, 0.08)


static func _cheer_swell() -> AudioStreamWAV:
	# Finish-line cheer: shaped noise, quick rise then a long decay.
	var n := int(MIX_RATE * 1.4)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC4EE2
	var lp := 0.0
	for i in n:
		var t := float(i) / float(n)
		var env := clampf(t / 0.25 if t < 0.25 else 1.0 - (t - 0.25) / 0.75, 0.0, 1.0)
		lp += 0.12 * (rng.randf_range(-1.0, 1.0) - lp)
		samples[i] = clampf(lp * 4.0, -1.0, 1.0) * env
	return _wav_from(samples)


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
