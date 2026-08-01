extends Node2D
# 战斗反馈控制器，集中生成伤害数字、命中提示和击杀反馈。
class_name CombatFeedbackController

const SimpleEffectScript = preload("res://scripts/gameplay/simple_effect.gd")

func spawn_muzzle(position: Vector2, direction: Vector2, color: Color) -> void:
	_spawn_effect("muzzle", position, direction, color.lightened(0.25), 0.16)

func spawn_wall_impact(position: Vector2, color: Color) -> void:
	_spawn_effect("wall", position, Vector2.ZERO, color, 0.30)

func spawn_player_hit(position: Vector2, color: Color, killed: bool = false) -> void:
	_spawn_effect("death" if killed else "hit", position, Vector2.ZERO, color, 0.46 if killed else 0.28)

func spawn_respawn(position: Vector2, color: Color) -> void:
	_spawn_effect("spawn", position, Vector2.ZERO, color, 0.42)

func _spawn_effect(kind: String, position: Vector2, direction: Vector2, color: Color, lifetime: float) -> void:
	if float(SettingsManager.get_value("video", "particle_quality", 1.0)) <= 0.05:
		return
	var effect := SimpleEffectScript.new()
	effect.effect_kind = kind
	effect.effect_color = color
	effect.direction = direction
	effect.lifetime = lifetime
	effect.global_position = position
	add_child(effect)
