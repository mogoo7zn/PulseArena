extends Node
# 设置管理器，负责读取、保存并应用音频、视频和辅助功能设置。
class_name SettingsManagerService

const SETTINGS_PATH := "user://settings.cfg"

var settings: Dictionary = {
	"video": {
		"window_mode": "windowed",
		"resolution": Vector2i(1600, 900),
		"vsync": true,
		"quality": "high",
		"particle_quality": 1.0,
		"shadows": true,
		"screen_shake": 0.45,
		"hit_flash": true,
		"damage_numbers": false,
		"reduced_motion": false,
		"frame_limit": 0,
	},
	"audio": {
		"master": 0.8,
		"sfx": 0.85,
		"music": 0.55,
	},
	"controls": {
		"mouse_sensitivity": 1.0,
		"aim_smoothing": 0.0,
		"gamepad_enabled": false,
		"gamepad_vibration": true,
	},
	"accessibility": {
		"color_blind_mode": "off",
		"high_contrast": false,
		"high_contrast_crosshair": false,
		"ui_scale": 1.0,
		"health_bar_size": 1.0,
		"reduce_flashing": false,
		"team_color_assist": false,
	},
	"debug": {
		"show_agent_diagnostics": false,
	},
}

func _ready() -> void:
	load_settings()
	apply_settings()

func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
	if not settings.has(section):
		return fallback
	var section_data: Dictionary = settings[section]
	return section_data.get(key, fallback)

func set_value(section: String, key: String, value: Variant, save_immediately: bool = true) -> void:
	if not settings.has(section):
		settings[section] = {}
	settings[section][key] = value
	apply_settings()
	if save_immediately:
		save_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for section in cfg.get_sections():
		if not settings.has(section):
			settings[section] = {}
		for key in cfg.get_section_keys(section):
			settings[section][key] = cfg.get_value(section, key)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	for section in settings.keys():
		var section_data: Dictionary = settings[section]
		for key in section_data.keys():
			cfg.set_value(section, key, section_data[key])
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		AppLog.warn("Failed to save settings", {"path": SETTINGS_PATH, "error": err})

func apply_settings() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if get_value("video", "vsync", true) else DisplayServer.VSYNC_DISABLED)
	var resolution: Vector2i = get_value("video", "resolution", Vector2i(1600, 900))
	DisplayServer.window_set_size(resolution)
	var frame_limit := int(get_value("video", "frame_limit", 0))
	Engine.max_fps = frame_limit if frame_limit > 0 else 0
	AudioManager.apply_volume_settings(settings.get("audio", {}))
