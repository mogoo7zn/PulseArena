extends Node2D
# 轻量一次性特效节点，用于冲击波、命中闪光和场景反馈。
class_name SimpleEffect

@export var effect_color: Color = Color("#6EA8FE")
@export var lifetime: float = 0.35
@export var effect_kind: String = "ring"
var direction: Vector2 = Vector2.RIGHT
var age: float = 0.0

func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
	queue_redraw()

func _draw() -> void:
	var t := clampf(age / lifetime, 0.0, 1.0)
	var alpha := 1.0 - t
	match effect_kind:
		"muzzle":
			var dir := direction.normalized() if direction.length_squared() > 0.001 else Vector2.RIGHT
			var side := dir.orthogonal()
			draw_polygon(PackedVector2Array([
				-side * 4.0,
				dir * (18.0 + 10.0 * t),
				side * 4.0,
			]), PackedColorArray([
				Color("#F1F5FA", 0.6 * alpha),
				Color(effect_color.r, effect_color.g, effect_color.b, 0.75 * alpha),
				Color("#FFE7A3", 0.55 * alpha),
			]))
		"wall":
			for i in range(5):
				var a := TAU * float(i) / 5.0 + t * 0.7
				var dir := Vector2.RIGHT.rotated(a)
				draw_line(dir * 5.0, dir * (14.0 + 18.0 * t), Color(effect_color.r, effect_color.g, effect_color.b, 0.45 * alpha), 2.0)
			draw_arc(Vector2.ZERO, 8.0 + 24.0 * t, 0, TAU, 16, Color("#F1F5FA", 0.16 * alpha), 2.0)
		"hit":
			draw_circle(Vector2.ZERO, 7.0 + 10.0 * t, Color(effect_color.r, effect_color.g, effect_color.b, 0.22 * alpha))
			draw_arc(Vector2.ZERO, 12.0 + 22.0 * t, 0, TAU, 18, Color(effect_color.r, effect_color.g, effect_color.b, 0.72 * alpha), 2.5)
		"death":
			draw_arc(Vector2.ZERO, 14.0 + 34.0 * t, 0, TAU, 24, Color("#F07178", 0.72 * alpha), 3.0)
			draw_arc(Vector2.ZERO, 24.0 + 24.0 * t, 0.4, TAU - 0.4, 24, Color(effect_color.r, effect_color.g, effect_color.b, 0.45 * alpha), 2.0)
		"spawn":
			draw_arc(Vector2.ZERO, 22.0 + 30.0 * t, 0, TAU, 24, Color(effect_color.r, effect_color.g, effect_color.b, 0.72 * alpha), 2.5)
			draw_line(Vector2(-18.0, 0.0), Vector2(18.0, 0.0), Color("#F1F5FA", 0.18 * alpha), 1.5)
			draw_line(Vector2(0.0, -18.0), Vector2(0.0, 18.0), Color("#F1F5FA", 0.18 * alpha), 1.5)
		_:
			draw_arc(Vector2.ZERO, 10.0 + 40.0 * t, 0, TAU, 22, Color(effect_color.r, effect_color.g, effect_color.b, alpha), 3.0)
