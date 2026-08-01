extends RefCounted
# 角色绘制器，负责身体、表情、轮廓和不同状态下的视觉细节。
class_name CharacterRenderer

const SKIN := Color("#D7BFA4")
const SUIT := Color("#243047")
const SUIT_DARK := Color("#121826")
const LIMB := Color("#323D55")
const OUTLINE := Color("#06101F")

const WeaponRendererScript = preload("res://scripts/gameplay/weapon_renderer.gd")
const WorldHealthBarScript = preload("res://scripts/gameplay/world_health_bar.gd")

var weapon_renderer = WeaponRendererScript.new()
var health_bar_renderer = WorldHealthBarScript.new()

func draw_player(canvas: CanvasItem, player, anim) -> void:
	var alive_alpha := 1.0 if player.is_alive else 0.38
	var alpha := alive_alpha * anim.get_spawn_alpha()
	var team := player.body_color
	var upper := Vector2.RIGHT.rotated(anim.upper_angle)
	var lower := Vector2.RIGHT.rotated(anim.lower_angle)
	var upper_side := upper.orthogonal()
	var lower_side := lower.orthogonal()
	var bob := sin(anim.walk_cycle * 2.0) * 1.5 * clampf(anim.move_speed_ratio, 0.0, 1.0)
	var recoil := clampf(anim.recoil, 0.0, 1.0)
	var show_hit_flash := bool(SettingsManager.get_value("video", "hit_flash", true))
	var hit_boost := 1.0 if anim.hit_flash <= 0.0 or not show_hit_flash else 1.0 + anim.hit_flash * 2.0
	var body_fill := SUIT.lerp(team, 0.18)
	if anim.hit_flash > 0.0 and show_hit_flash:
		body_fill = Color.WHITE

	if bool(SettingsManager.get_value("video", "shadows", true)):
		_draw_shadow(canvas, alpha)
	_draw_team_ring(canvas, player, team, alpha)
	if player.is_dashing():
		canvas.draw_line(-lower * 42.0, -lower * 10.0, Color("#63D7C4", 0.28 * alpha), 12.0)

	var core_offset := upper * recoil * -3.5 + Vector2(0, bob)
	_draw_legs(canvas, core_offset, lower, lower_side, team, anim, alpha)
	var flash_alpha := clampf(alpha * hit_boost, 0.0, 1.0)
	_draw_torso(canvas, core_offset, upper, upper_side, body_fill, team, flash_alpha)
	_draw_arms_and_weapon(canvas, core_offset, upper, upper_side, team, anim, alpha)
	_draw_head(canvas, core_offset + upper * 15.0, upper, upper_side, team, flash_alpha)

	if player.is_shielding():
		canvas.draw_arc(Vector2.ZERO, player.balance.player_radius + 11.0, 0, TAU, 56, Color("#6EA8FE", 0.58 * alpha), 3.0)
	if player.has_respawn_protection():
		var t := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.01)
		canvas.draw_arc(Vector2.ZERO, player.balance.player_radius + 16.0, 0, TAU, 56, Color("#E6A85C", 0.48 * t * alpha), 2.0)
	if anim.get_state_name() == "spawn":
		var spawn_t := 1.0 - anim.get_spawn_alpha()
		canvas.draw_arc(Vector2.ZERO, 22.0 + spawn_t * 18.0, 0, TAU, 48, Color("#63D7C4", 0.55 * alpha), 2.0)

	var health_scale := float(SettingsManager.get_value("accessibility", "health_bar_size", 1.0))
	health_bar_renderer.draw(canvas, player, alpha, health_scale)

func _draw_shadow(canvas: CanvasItem, alpha: float) -> void:
	canvas.draw_set_transform(Vector2(0, 10), 0.0, Vector2(1.7, 0.42))
	canvas.draw_circle(Vector2.ZERO, 19.0, Color("#000000", 0.34 * alpha))
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_team_ring(canvas: CanvasItem, player, team: Color, alpha: float) -> void:
	canvas.draw_arc(Vector2.ZERO, player.balance.player_radius + 5.0, 0, TAU, 48, Color(team.r, team.g, team.b, 0.72 * alpha), 2.2)
	canvas.draw_arc(Vector2.ZERO, player.balance.player_radius + 8.0, 0, TAU, 48, Color("#F1F5FA", 0.12 * alpha), 1.0)

func _draw_legs(canvas: CanvasItem, origin: Vector2, dir: Vector2, side: Vector2, team: Color, anim, alpha: float) -> void:
	var stride := sin(anim.walk_cycle) * 7.5 * clampf(anim.move_speed_ratio, 0.0, 1.0)
	var lift := cos(anim.walk_cycle) * 2.5 * clampf(anim.move_speed_ratio, 0.0, 1.0)
	for i in range(2):
		var sign := -1.0 if i == 0 else 1.0
		var hip := origin - dir * 5.0 + side * sign * 7.0
		var foot := hip - dir * (16.0 + stride * sign) + side * sign * (2.0 + lift * sign)
		_draw_capsule(canvas, hip, foot, 6.5, LIMB.lerp(team, 0.12), Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, 0.75 * alpha), alpha)
		canvas.draw_circle(foot, 4.4, Color("#111827", 0.95 * alpha))

func _draw_torso(canvas: CanvasItem, origin: Vector2, dir: Vector2, side: Vector2, fill: Color, team: Color, alpha: float) -> void:
	var back := origin - dir * 8.0
	var front := origin + dir * 11.0
	_draw_capsule(canvas, back, front, 18.0, fill, Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, 0.86 * alpha), alpha)
	canvas.draw_line(origin - side * 8.5, origin + side * 8.5, Color(team.r, team.g, team.b, 0.82 * alpha), 3.0)
	canvas.draw_line(back + side * 7.0, front + side * 5.0, Color("#F1F5FA", 0.08 * alpha), 2.0)

func _draw_arms_and_weapon(canvas: CanvasItem, origin: Vector2, dir: Vector2, side: Vector2, team: Color, anim, alpha: float) -> void:
	var recoil := clampf(anim.recoil, 0.0, 1.0)
	var right_shoulder := origin + dir * 4.0 + side * 10.0
	var left_shoulder := origin + dir * 3.0 - side * 10.0
	var weapon_hand := origin + dir * (17.0 - recoil * 5.0) + side * 5.5
	var support_hand := origin + dir * (15.0 - recoil * 4.0) - side * 6.5
	_draw_capsule(canvas, right_shoulder, weapon_hand, 5.5, LIMB.lerp(team, 0.18), Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, 0.72 * alpha), alpha)
	_draw_capsule(canvas, left_shoulder, support_hand, 5.0, LIMB.lerp(team, 0.10), Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, 0.65 * alpha), alpha)
	canvas.draw_circle(weapon_hand, 3.5, Color(SKIN.r, SKIN.g, SKIN.b, alpha))
	canvas.draw_circle(support_hand, 3.2, Color(SKIN.r, SKIN.g, SKIN.b, alpha))
	weapon_renderer.draw_weapon(canvas, weapon_hand, dir, team, anim.recoil, anim.muzzle_flash, anim.empty_flash, alpha)

func _draw_head(canvas: CanvasItem, center: Vector2, dir: Vector2, side: Vector2, team: Color, alpha: float) -> void:
	canvas.draw_circle(center, 9.0, Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, 0.85 * alpha))
	canvas.draw_circle(center, 7.4, Color(SKIN.r, SKIN.g, SKIN.b, alpha))
	canvas.draw_line(center + side * -4.5 + dir * 3.0, center + side * 4.5 + dir * 3.0, Color("#0B1020", 0.9 * alpha), 2.5)
	canvas.draw_circle(center - side * 4.8 - dir * 2.0, 2.2, Color(team.r, team.g, team.b, 0.9 * alpha))

func _draw_capsule(canvas: CanvasItem, a: Vector2, b: Vector2, width: float, fill: Color, outline: Color, alpha: float) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	if outline.a > 0.0:
		canvas.draw_line(a, b, outline, width + 2.0)
		canvas.draw_circle(a, width * 0.5 + 1.0, outline)
		canvas.draw_circle(b, width * 0.5 + 1.0, outline)
	var c := Color(fill.r, fill.g, fill.b, fill.a * alpha)
	canvas.draw_line(a, b, c, width)
	canvas.draw_circle(a, width * 0.5, c)
	canvas.draw_circle(b, width * 0.5, c)
