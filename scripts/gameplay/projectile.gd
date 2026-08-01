extends Node2D
# 子弹实体，负责飞行、碰撞命中、生命期和弹道视觉。
class_name ArenaProjectile

var projectile_id: int = 0
var owner_id: int = -1
var owner_team_id: int = -1
var velocity: Vector2 = Vector2.ZERO
var damage: float = 20.0
var radius: float = 7.0
var lifetime: float = 1.4
var max_lifetime: float = 1.4
var color: Color = Color("#63D7C4")
var trail: Array[Vector2] = []
var visuals_enabled: bool = true

func set_visuals_enabled(enabled: bool) -> void:
	visuals_enabled = enabled
	visible = enabled

func configure(id: int, owner: ArenaPlayer, origin: Vector2, direction: Vector2, balance: GameBalance) -> void:
	projectile_id = id
	owner_id = owner.player_id
	owner_team_id = owner.team_id
	global_position = origin
	var speed_multiplier := owner.get_projectile_speed_multiplier() if owner.has_method("get_projectile_speed_multiplier") else 1.0
	var damage_multiplier := owner.get_projectile_damage_multiplier() if owner.has_method("get_projectile_damage_multiplier") else 1.0
	velocity = direction.normalized() * balance.projectile_speed * speed_multiplier
	damage = balance.projectile_damage * damage_multiplier
	radius = balance.projectile_radius
	lifetime = balance.projectile_lifetime
	max_lifetime = balance.projectile_lifetime
	color = owner.body_color.lightened(0.25)
	if damage_multiplier > 1.01:
		color = Color("#FF6B6B").lerp(owner.body_color.lightened(0.35), 0.25)
	trail.clear()
	GameEvents.emit_projectile_fired({"projectile_id": projectile_id, "owner_id": owner_id, "position": global_position, "velocity": velocity})

func physics_step(delta: float) -> void:
	if visuals_enabled:
		trail.append(global_position)
		while trail.size() > 5:
			trail.pop_front()
	global_position += velocity * delta
	lifetime = maxf(0.0, lifetime - delta)
	if visuals_enabled:
		queue_redraw()

func is_expired() -> bool:
	return lifetime <= 0.0

func get_lifetime_ratio() -> float:
	return clampf(lifetime / max_lifetime, 0.0, 1.0)

func _draw() -> void:
	var dir := velocity.normalized() if velocity.length_squared() > 0.001 else Vector2.RIGHT
	var side := dir.orthogonal()
	for i in range(trail.size()):
		var p := to_local(trail[i])
		var a := float(i + 1) / float(maxi(trail.size(), 1))
		var w := radius * lerpf(0.28, 0.92, a)
		draw_circle(p, w, Color(color.r, color.g, color.b, 0.04 + 0.18 * a))
		if i > 0:
			var prev := to_local(trail[i - 1])
			draw_line(prev, p, Color(color.r, color.g, color.b, 0.15 * a), maxf(1.0, w * 0.74))
	draw_circle(Vector2.ZERO + Vector2(2, 3), radius + 2.0, Color("#000000", 0.20))
	draw_circle(Vector2.ZERO, radius + 3.0, Color(color.r, color.g, color.b, 0.22))
	draw_circle(Vector2.ZERO, radius, color.darkened(0.05))
	draw_circle(-dir * 2.0 - side * 2.0, radius * 0.45, color.lightened(0.55))
	draw_line(-dir * radius * 0.35 - side * radius * 0.65, dir * radius * 0.48 + side * radius * 0.2, Color("#F1F5FA", 0.54), 1.2)
	draw_arc(Vector2.ZERO, radius + 4.0, 0, TAU, 14, Color("#F1F5FA", 0.18), 1.0)
