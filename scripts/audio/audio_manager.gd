extends Node
# 统一音频服务，集中管理音量总线和程序化音效播放。
class_name AudioManagerService

const BUS_PARENT: Dictionary = {
	"Music": "Master",
	"SFX": "Master",
	"UI": "Master",
	"Ambience": "Master",
}

const EVENT_PROFILES: Dictionary = {
	"shoot": {"freq": 560.0, "end_freq": 310.0, "duration": 0.075, "volume": 0.20, "bus": "SFX", "noise": 0.12},
	"empty": {"freq": 210.0, "end_freq": 180.0, "duration": 0.060, "volume": 0.12, "bus": "SFX", "noise": 0.05},
	"impact": {"freq": 140.0, "end_freq": 90.0, "duration": 0.095, "volume": 0.16, "bus": "SFX", "noise": 0.28},
	"hit": {"freq": 320.0, "end_freq": 190.0, "duration": 0.105, "volume": 0.18, "bus": "SFX", "noise": 0.18},
	"death": {"freq": 180.0, "end_freq": 70.0, "duration": 0.180, "volume": 0.19, "bus": "SFX", "noise": 0.20},
	"respawn": {"freq": 410.0, "end_freq": 760.0, "duration": 0.170, "volume": 0.14, "bus": "SFX", "noise": 0.04},
	"dash": {"freq": 260.0, "end_freq": 520.0, "duration": 0.085, "volume": 0.12, "bus": "SFX", "noise": 0.16},
	"shield": {"freq": 360.0, "end_freq": 260.0, "duration": 0.120, "volume": 0.13, "bus": "SFX", "noise": 0.03},
	"pickup": {"freq": 580.0, "end_freq": 860.0, "duration": 0.110, "volume": 0.12, "bus": "SFX", "noise": 0.02},
	"pulse": {"freq": 180.0, "end_freq": 520.0, "duration": 0.150, "volume": 0.16, "bus": "SFX", "noise": 0.16},
	"ui_click": {"freq": 520.0, "end_freq": 650.0, "duration": 0.045, "volume": 0.10, "bus": "UI", "noise": 0.00},
	"ui_hover": {"freq": 360.0, "end_freq": 390.0, "duration": 0.030, "volume": 0.055, "bus": "UI", "noise": 0.00},
}

var tone_rng := RandomNumberGenerator.new()
var runtime_audio_enabled: bool = true

func _ready() -> void:
	tone_rng.seed = 9917
	ensure_bus_layout()

func ensure_bus_layout() -> void:
	for bus_name in BUS_PARENT.keys():
		_ensure_bus(bus_name, BUS_PARENT[bus_name])

func apply_volume_settings(audio_settings: Dictionary) -> void:
	_set_bus_volume("Master", float(audio_settings.get("master", 0.8)))
	_set_bus_volume("SFX", float(audio_settings.get("sfx", 0.85)))
	_set_bus_volume("Music", float(audio_settings.get("music", 0.55)))

func set_runtime_audio_enabled(enabled: bool) -> void:
	runtime_audio_enabled = enabled

func play_event(event_name: String, position: Vector2 = Vector2.ZERO) -> void:
	if not is_inside_tree():
		return
	if not runtime_audio_enabled:
		return
	if DisplayServer.get_name().to_lower() == "headless":
		return
	var profile: Dictionary = EVENT_PROFILES.get(event_name, EVENT_PROFILES.get("impact", {}))
	if profile.is_empty():
		return
	_play_generated_tone(profile)
	AppLog.debug("Audio event", {"event": event_name, "position": position})

func _ensure_bus(bus_name: String, parent_bus: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, parent_bus)

func _set_bus_volume(bus_name: String, linear_value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	var clamped := clampf(linear_value, 0.0, 1.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(clamped) if clamped > 0.001 else -80.0)

func _play_generated_tone(profile: Dictionary) -> void:
	var duration := float(profile.get("duration", 0.08))
	var mix_rate := 22050.0
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = mix_rate
	stream.buffer_length = duration + 0.04
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = str(profile.get("bus", "SFX"))
	add_child(player)
	player.play()
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		player.queue_free()
		return
	var frames := int(duration * mix_rate)
	var start_freq := float(profile.get("freq", 440.0))
	var end_freq := float(profile.get("end_freq", start_freq))
	var volume := float(profile.get("volume", 0.12))
	var noise := float(profile.get("noise", 0.0))
	var phase := 0.0
	for i in range(frames):
		var t := float(i) / float(maxi(frames - 1, 1))
		var freq := lerpf(start_freq, end_freq, t)
		phase += TAU * freq / mix_rate
		var envelope := pow(1.0 - t, 1.8)
		var sample := sin(phase) * volume * envelope
		if noise > 0.0:
			sample += tone_rng.randf_range(-noise, noise) * volume * envelope
		playback.push_frame(Vector2(sample, sample))
	get_tree().create_timer(duration + 0.08, true).timeout.connect(player.queue_free)
