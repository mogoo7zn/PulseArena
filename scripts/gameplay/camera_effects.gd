extends Node
# 摄像机反馈控制器，提供抖动、缩放脉冲和受击冲击感。
class_name CameraEffects

var camera: Camera2D
var trauma: float = 0.0
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.seed = 73129
	set_process(true)

func configure(target_camera: Camera2D) -> void:
	camera = target_camera

func add_shake(amount: float) -> void:
	var setting := float(SettingsManager.get_value("video", "screen_shake", 0.45))
	if setting <= 0.001 or bool(SettingsManager.get_value("video", "reduced_motion", false)):
		return
	trauma = clampf(trauma + amount * setting, 0.0, 1.0)

func _process(delta: float) -> void:
	if camera == null:
		return
	trauma = maxf(0.0, trauma - delta * 2.8)
	if trauma <= 0.001:
		camera.offset = Vector2.ZERO
		return
	var strength := trauma * trauma
	camera.offset = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * 8.0 * strength
