extends "res://scripts/arena/map_rules/map_rule_base.gd"
# 地牢地图规则，维护牢笼陷阱、砖石环境绘制和地形碰撞。
class_name DungeonRule

const TRAP_SPAWN_INTERVAL_MIN := 3.2
const TRAP_SPAWN_INTERVAL_MAX := 6.0
const TRAP_ARM_DELAY := 3.0
const TRAP_LIFETIME := 20.0
const TRAP_RADIUS := 48.0
const CAGE_LOCK_DURATION := 3.0
const TRAP_TRIGGER_EFFECT_DURATION := 0.45
const MAX_ACTIVE_TRAPS := 3
const TORCH_COUNT_MIN := 9
const TORCH_COUNT_MAX := 13
const TORCH_MIN_DISTANCE := 150.0

var spawn_timer: float = 1.8
var traps: Array[Dictionary] = []
var cages: Dictionary = {}
var activations: Array[Dictionary] = []
var torches: Array[Dictionary] = []

func configure(map_node: Node, size: Vector2, seed_value: int) -> void:
	super.configure(map_node, size, seed_value)
	spawn_timer = rng.randf_range(1.2, 2.4)
	traps.clear()
	cages.clear()
	activations.clear()
	torches.clear()
	_spawn_torches()

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	if not playing:
		return
	_update_cages(delta)
	_update_activations(delta)
	_update_traps(delta, players)
	spawn_timer -= delta
	if spawn_timer <= 0.0:
		spawn_timer = rng.randf_range(TRAP_SPAWN_INTERVAL_MIN, TRAP_SPAWN_INTERVAL_MAX)
		if traps.size() < MAX_ACTIVE_TRAPS:
			_spawn_trap()
	if visuals_enabled:
		queue_redraw()

func _update_cages(delta: float) -> void:
	for key in cages.keys():
		var cage: Dictionary = cages[key]
		cage["remaining"] = maxf(0.0, float(cage.get("remaining", 0.0)) - delta)
		cage["age"] = float(cage.get("age", 0.0)) + delta
		if float(cage["remaining"]) <= 0.0:
			cages.erase(key)

func _update_traps(delta: float, players: Array) -> void:
	var remaining: Array[Dictionary] = []
	for trap in traps:
		trap["age"] = float(trap.get("age", 0.0)) + delta
		var age := float(trap["age"])
		var triggered := false
		if age >= TRAP_ARM_DELAY:
			var center: Vector2 = trap["position"]
			for player in players:
				if _contains_player(center, TRAP_RADIUS, player):
					player.add_movement_lock(CAGE_LOCK_DURATION)
					cages[player.player_id] = {"remaining": CAGE_LOCK_DURATION, "duration": CAGE_LOCK_DURATION, "age": 0.0}
					_apply_trap_damage(player)
					activations.append({"position": center, "age": 0.0})
					triggered = true
					break
		if not triggered and age < TRAP_LIFETIME:
			remaining.append(trap)
	traps = remaining

func _spawn_trap() -> void:
	var point: Vector2 = random_clear_point(TRAP_RADIUS + 24.0, 84.0, 90)
	traps.append({"position": point, "age": 0.0})

func _spawn_torches() -> void:
	var target_count := rng.randi_range(TORCH_COUNT_MIN, TORCH_COUNT_MAX)
	for _i in range(target_count):
		for _attempt in range(48):
			var point: Vector2 = random_clear_point(26.0, 86.0, 40)
			if _torch_too_close(point):
				continue
			torches.append({
				"position": point,
				"radius": rng.randf_range(180.0, 250.0),
				"phase": rng.randf_range(0.0, TAU),
				"height": rng.randf_range(0.85, 1.18),
			})
			break

func _torch_too_close(point: Vector2) -> bool:
	for torch in torches:
		var other := torch["position"] as Vector2
		if point.distance_squared_to(other) <= TORCH_MIN_DISTANCE * TORCH_MIN_DISTANCE:
			return true
	return false

func _update_activations(delta: float) -> void:
	var remaining: Array[Dictionary] = []
	for activation in activations:
		activation["age"] = float(activation.get("age", 0.0)) + delta
		if float(activation["age"]) < TRAP_TRIGGER_EFFECT_DURATION:
			remaining.append(activation)
	activations = remaining

func _apply_trap_damage(player) -> void:
	var damage := 20.0
	if player != null and player.balance != null:
		damage = player.balance.projectile_damage
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("apply_environment_damage"):
		root.apply_environment_damage(player, damage, "dungeon_trap")
	elif player != null and player.has_method("take_damage"):
		player.take_damage(damage, -1)

func _draw() -> void:
	if not visuals_enabled:
		return
	_draw_dungeon_lighting()
	for trap in traps:
		_draw_trap(trap)
	for activation in activations:
		_draw_activation(activation)
	for player_id in cages.keys():
		var cage: Dictionary = cages[player_id]
		_draw_cage_for_player(int(player_id), cage)
	for torch in torches:
		_draw_torch(torch)

func _draw_dungeon_lighting() -> void:
	draw_rect(Rect2(Vector2.ZERO, map_size), Color("#02040A", 0.34))
	for torch in torches:
		var center := torch["position"] as Vector2
		var radius := float(torch["radius"])
		var phase := float(torch["phase"])
		var height := float(torch["height"])
		var flicker := 0.86 + 0.14 * sin(Time.get_ticks_msec() * 0.006 + phase)
		draw_circle(center, radius * 0.98 * height, Color("#E6A85C", 0.055 * flicker))
		draw_circle(center, radius * 0.58 * height, Color("#F2D36B", 0.075 * flicker))
		draw_circle(center, radius * 0.26 * height, Color("#FFB35D", 0.12 * flicker))

func _draw_trap(trap: Dictionary) -> void:
	var center: Vector2 = trap["position"]
	var age := float(trap.get("age", 0.0))
	var armed := age >= TRAP_ARM_DELAY
	var pulse := 0.5 + 0.5 * sin(age * 8.0)
	var color := Color("#F07178") if armed else Color("#E6A85C")
	draw_circle(center + Vector2(4, 6), TRAP_RADIUS + 4.0, Color("#000000", 0.22))
	draw_circle(center, TRAP_RADIUS, Color(color.r, color.g, color.b, 0.10 + pulse * 0.06))
	draw_arc(center, TRAP_RADIUS, 0, TAU, 48, Color(color.r, color.g, color.b, 0.42), 2.2)
	draw_arc(center, TRAP_RADIUS * 0.64, 0, TAU, 36, Color("#F1F5FA", 0.18), 1.4)
	for i in range(6):
		var a := TAU * float(i) / 6.0 + age * 0.4
		draw_line(center + Vector2.RIGHT.rotated(a) * TRAP_RADIUS * 0.30, center + Vector2.RIGHT.rotated(a) * TRAP_RADIUS * 0.82, Color(color.r, color.g, color.b, 0.50), 1.8)
	_draw_hint(center, "CAGE LIVE" if armed else "ARMING %.0f" % ceil(TRAP_ARM_DELAY - age), color)

func _draw_activation(activation: Dictionary) -> void:
	var center: Vector2 = activation["position"]
	var age := float(activation.get("age", 0.0))
	var t := clampf(age / TRAP_TRIGGER_EFFECT_DURATION, 0.0, 1.0)
	var alpha := 1.0 - t
	draw_circle(center, TRAP_RADIUS * (0.85 + t * 0.55), Color("#F07178", 0.16 * alpha))
	draw_arc(center, TRAP_RADIUS * (0.9 + t * 0.48), 0, TAU, 48, Color("#F07178", 0.75 * alpha), 3.0)
	for i in range(10):
		var a := TAU * float(i) / 10.0 + age * 4.0
		draw_line(center + Vector2.RIGHT.rotated(a) * 18.0, center + Vector2.RIGHT.rotated(a) * (TRAP_RADIUS + 24.0 * t), Color("#D7A765", 0.62 * alpha), 2.0)

func _draw_cage_for_player(player_id: int, cage: Dictionary) -> void:
	var player = _find_player(player_id)
	if player == null:
		return
	var center: Vector2 = player.global_position
	var remaining := float(cage.get("remaining", 0.0))
	var age := float(cage.get("age", 0.0))
	var drop := clampf(age / 0.28, 0.0, 1.0)
	var fade := clampf(remaining / 0.45, 0.0, 1.0)
	var top_y := lerpf(-62.0, -30.0, drop)
	var bottom_y := 24.0
	var radius_x := 35.0
	var radius_y := 10.0
	_draw_flat_ellipse(center + Vector2(4, 28), Vector2(radius_x + 6.0, 8.0), Color("#000000", 0.24 * fade))
	_draw_flat_ellipse(center + Vector2(0, top_y), Vector2(radius_x, radius_y), Color("#120D08", 0.40 * fade))
	_draw_flat_ellipse(center + Vector2(0, bottom_y), Vector2(radius_x + 4.0, radius_y + 2.0), Color("#120D08", 0.26 * fade))
	draw_arc(center + Vector2(0, top_y), radius_x, 0, TAU, 48, Color("#D7A765", 0.78 * fade), 2.4)
	draw_arc(center + Vector2(0, bottom_y), radius_x + 4.0, 0, TAU, 48, Color("#D7A765", 0.56 * fade), 2.0)
	for i in range(10):
		var a := TAU * float(i) / 10.0
		var x := cos(a) * radius_x
		var front := sin(a) > -0.12
		var width := 2.4 if front else 1.4
		var alpha := (0.82 if front else 0.34) * fade
		var top := center + Vector2(x, top_y + sin(a) * radius_y)
		var bottom := center + Vector2(x * 1.05, bottom_y + sin(a) * (radius_y + 2.0))
		draw_line(top, bottom, Color("#D7A765", alpha), width)
		if front:
			draw_circle(bottom, 2.6, Color("#F1F5FA", 0.18 * fade))
	draw_rect(Rect2(center + Vector2(-8, -4), Vector2(16, 18)), Color("#2A211B", 0.78 * fade))
	draw_rect(Rect2(center + Vector2(-8, -4), Vector2(16, 18)), Color("#F1F5FA", 0.16 * fade), false, 1.2)
	_draw_hint(center + Vector2(0, -58), "LOCK %.0f" % ceil(remaining), Color("#F1F5FA", fade))

func _find_player(player_id: int):
	for node in get_tree().get_nodes_in_group("players"):
		if node != null and node.player_id == player_id:
			return node
	return null

func _draw_flat_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(maxf(radii.x, 1.0), maxf(radii.y, 1.0)))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_torch(torch: Dictionary) -> void:
	var center := torch["position"] as Vector2
	var phase := float(torch["phase"])
	var flicker := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.010 + phase)
	_draw_flat_ellipse(center + Vector2(3, 10), Vector2(18, 6), Color("#000000", 0.28))
	draw_rect(Rect2(center + Vector2(-4, -4), Vector2(8, 24)), Color("#2A180E", 0.92))
	draw_rect(Rect2(center + Vector2(-6, -8), Vector2(12, 9)), Color("#6E3D1A", 0.88))
	draw_circle(center + Vector2(0, -14), 14.0 + flicker * 4.0, Color("#F2D36B", 0.18))
	draw_circle(center + Vector2(0, -16), 8.0 + flicker * 3.0, Color("#FF9D48", 0.72))
	draw_circle(center + Vector2(0, -19), 4.5 + flicker * 2.0, Color("#FFF0A6", 0.92))
	draw_line(center + Vector2(-6, -2), center + Vector2(6, -2), Color("#F1F5FA", 0.14), 1.2)

func _draw_hint(center: Vector2, text: String, color: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	draw_string(font, center + Vector2(-42, -46), text, HORIZONTAL_ALIGNMENT_LEFT, 84.0, 12, Color("#050812", 0.85))
	draw_string(font, center + Vector2(-43, -47), text, HORIZONTAL_ALIGNMENT_LEFT, 86.0, 12, color)
