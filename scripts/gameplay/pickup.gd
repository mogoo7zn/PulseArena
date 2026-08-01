extends Node2D
# 地面拾取物实体，绘制补给与技能图标并维护过期消失表现。
class_name ArenaPickup

const TYPE_HEALTH := "health"
const TYPE_SHIELD := "shield"
const TYPE_HASTE := "haste"
const TYPE_PULSE := "pulse"
const TYPE_OVERCHARGE := "overcharge"
const TYPE_MAGNET := "magnet"

var pickup_type: String = TYPE_HEALTH
var lifetime: float = 15.0
var max_lifetime: float = 15.0
var collect_radius: float = 42.0
var hover_phase: float = 0.0
var icon_color: Color = Color("#63D7C4")
var accent_color: Color = Color("#F1F5FA")
var visuals_enabled: bool = true

func set_visuals_enabled(enabled: bool) -> void:
	visuals_enabled = enabled
	visible = enabled

func configure(kind: String, position: Vector2, duration: float, radius: float) -> void:
	pickup_type = kind
	global_position = position
	lifetime = duration
	max_lifetime = duration
	collect_radius = radius
	_apply_palette()
	if visuals_enabled:
		queue_redraw()

func physics_step(delta: float) -> void:
	lifetime = maxf(0.0, lifetime - delta)
	if visuals_enabled:
		hover_phase = fposmod(hover_phase + delta * 4.0, TAU)
		queue_redraw()

func is_expired() -> bool:
	return lifetime <= 0.0

func get_lifetime_ratio() -> float:
	return clampf(lifetime / maxf(max_lifetime, 0.001), 0.0, 1.0)

func _apply_palette() -> void:
	match pickup_type:
		TYPE_SHIELD:
			icon_color = Color("#6EA8FE")
			accent_color = Color("#C8DCFF")
		TYPE_HASTE:
			icon_color = Color("#E6A85C")
			accent_color = Color("#FFE7A3")
		TYPE_PULSE:
			icon_color = Color("#A78BFA")
			accent_color = Color("#EBDFFF")
		TYPE_OVERCHARGE:
			icon_color = Color("#FF6B6B")
			accent_color = Color("#FFE2B8")
		TYPE_MAGNET:
			icon_color = Color("#63D7C4")
			accent_color = Color("#D6FFF7")
		_:
			icon_color = Color("#F07178")
			accent_color = Color("#FFE2E6")

func _draw() -> void:
	var ratio := get_lifetime_ratio()
	var expiry_flash := 1.0
	if lifetime <= 3.0:
		expiry_flash = 0.35 + 0.65 * absf(sin(Time.get_ticks_msec() * 0.018))
	var alpha := clampf(lerpf(0.45, 1.0, ratio) * expiry_flash, 0.0, 1.0)
	var bob := sin(hover_phase) * 3.5
	var center := Vector2(0.0, bob)
	var pulse := 1.0 + sin(hover_phase * 1.4) * 0.05
	draw_circle(Vector2(3.0, 12.0), 24.0, Color("#000000", 0.20 * alpha))
	draw_circle(center, 25.0 * pulse, Color(icon_color.r, icon_color.g, icon_color.b, 0.18 * alpha))
	draw_arc(center, 27.0 * pulse, 0, TAU, 30, Color(icon_color.r, icon_color.g, icon_color.b, 0.74 * alpha), 2.4)
	draw_circle(center, 17.5, Color("#07101D", 0.86 * alpha))
	draw_circle(center, 14.5, Color(icon_color.r, icon_color.g, icon_color.b, 0.24 * alpha))
	_draw_icon(center, alpha)
	var timer_width := 34.0 * ratio
	draw_rect(Rect2(Vector2(-17.0, 34.0), Vector2(34.0, 3.0)), Color("#07101D", 0.72 * alpha))
	draw_rect(Rect2(Vector2(-17.0, 34.0), Vector2(timer_width, 3.0)), Color(icon_color.r, icon_color.g, icon_color.b, 0.82 * alpha))

func _draw_icon(center: Vector2, alpha: float) -> void:
	match pickup_type:
		TYPE_SHIELD:
			_draw_shield_icon(center, alpha)
		TYPE_HASTE:
			_draw_haste_icon(center, alpha)
		TYPE_PULSE:
			_draw_pulse_icon(center, alpha)
		TYPE_OVERCHARGE:
			_draw_overcharge_icon(center, alpha)
		TYPE_MAGNET:
			_draw_magnet_icon(center, alpha)
		_:
			_draw_health_icon(center, alpha)

func _draw_health_icon(center: Vector2, alpha: float) -> void:
	var c := Color(accent_color.r, accent_color.g, accent_color.b, 0.95 * alpha)
	draw_rect(Rect2(center + Vector2(-3.0, -11.0), Vector2(6.0, 22.0)), c)
	draw_rect(Rect2(center + Vector2(-11.0, -3.0), Vector2(22.0, 6.0)), c)

func _draw_shield_icon(center: Vector2, alpha: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, -13.0),
		center + Vector2(11.0, -8.0),
		center + Vector2(8.0, 7.0),
		center + Vector2(0.0, 14.0),
		center + Vector2(-8.0, 7.0),
		center + Vector2(-11.0, -8.0),
	])
	draw_polygon(points, PackedColorArray([
		Color(accent_color.r, accent_color.g, accent_color.b, 0.94 * alpha),
		Color(accent_color.r, accent_color.g, accent_color.b, 0.94 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.86 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.86 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.86 * alpha),
		Color(accent_color.r, accent_color.g, accent_color.b, 0.94 * alpha),
	]))
	draw_line(center + Vector2(0, -9), center + Vector2(0, 9), Color("#07101D", 0.38 * alpha), 1.6)

func _draw_haste_icon(center: Vector2, alpha: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(2.0, -14.0),
		center + Vector2(-9.0, 2.0),
		center + Vector2(-1.0, 2.0),
		center + Vector2(-4.0, 14.0),
		center + Vector2(10.0, -4.0),
		center + Vector2(2.0, -4.0),
	])
	draw_polygon(points, PackedColorArray([
		Color(accent_color.r, accent_color.g, accent_color.b, 0.96 * alpha),
		Color(accent_color.r, accent_color.g, accent_color.b, 0.96 * alpha),
		Color(accent_color.r, accent_color.g, accent_color.b, 0.96 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha),
		Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha),
	]))

func _draw_pulse_icon(center: Vector2, alpha: float) -> void:
	draw_circle(center, 4.0, Color(accent_color.r, accent_color.g, accent_color.b, 0.95 * alpha))
	draw_arc(center, 10.0, 0, TAU, 20, Color(accent_color.r, accent_color.g, accent_color.b, 0.74 * alpha), 2.0)
	draw_arc(center, 15.0, 0.35, TAU - 0.35, 24, Color(icon_color.r, icon_color.g, icon_color.b, 0.92 * alpha), 2.2)

func _draw_overcharge_icon(center: Vector2, alpha: float) -> void:
	draw_arc(center, 13.5, 0, TAU, 24, Color(accent_color.r, accent_color.g, accent_color.b, 0.90 * alpha), 1.8)
	draw_line(center + Vector2(-13.0, 0.0), center + Vector2(-5.0, 0.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 2.2)
	draw_line(center + Vector2(5.0, 0.0), center + Vector2(13.0, 0.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 2.2)
	draw_line(center + Vector2(0.0, -13.0), center + Vector2(0.0, -5.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 2.2)
	draw_line(center + Vector2(0.0, 5.0), center + Vector2(0.0, 13.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 2.2)
	draw_circle(center, 4.0, Color(accent_color.r, accent_color.g, accent_color.b, 0.94 * alpha))

func _draw_magnet_icon(center: Vector2, alpha: float) -> void:
	var left := center + Vector2(-8.0, -3.0)
	var right := center + Vector2(8.0, -3.0)
	draw_arc(center + Vector2(0.0, -1.0), 11.0, 0.08 * PI, 0.92 * PI, 20, Color(accent_color.r, accent_color.g, accent_color.b, 0.95 * alpha), 4.2)
	draw_line(left, left + Vector2(0.0, 9.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 4.2)
	draw_line(right, right + Vector2(0.0, 9.0), Color(icon_color.r, icon_color.g, icon_color.b, 0.94 * alpha), 4.2)
	draw_line(left + Vector2(-4.0, 9.0), left + Vector2(4.0, 9.0), Color("#FFFFFF", 0.84 * alpha), 2.0)
	draw_line(right + Vector2(-4.0, 9.0), right + Vector2(4.0, 9.0), Color("#FFFFFF", 0.84 * alpha), 2.0)
