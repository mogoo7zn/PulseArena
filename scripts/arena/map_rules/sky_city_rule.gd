extends "res://scripts/arena/map_rules/map_rule_base.gd"
# 天空之城地图规则，处理移动屏障、虚空陷阱和高空场景表现。
class_name SkyCityRule

const MOVE_SPEED_MIN := 46.0
const MOVE_SPEED_MAX := 98.0
const WAIT_MIN := 0.15
const WAIT_MAX := 0.85
const TARGET_REACHED_DISTANCE := 7.0
const SQUEEZE_SAMPLE_SCALE := 1.32
const VOID_SPAWN_INTERVAL_MIN := 6.0
const VOID_SPAWN_INTERVAL_MAX := 11.0
const VOID_DURATION_MIN := 5.0
const VOID_DURATION_MAX := 15.0
const VOID_OPEN_DURATION := 0.75
const VOID_CLOSE_DURATION := 0.85
const VOID_DEATH_RADIUS_MIN := 22.0
const VOID_DEATH_RADIUS_MAX := 58.0
const VOID_GRAVITY_RADIUS_MIN := 105.0
const VOID_GRAVITY_RADIUS_MAX := 270.0
const VOID_PULL_STRENGTH := 96.0
const MAX_ACTIVE_VOID_TRAPS := 2

var obstacles: Array[Dictionary] = []
var void_traps: Array[Dictionary] = []
var void_spawn_timer: float = 5.0

func configure(map_node: Node, size: Vector2, seed_value: int) -> void:
	super.configure(map_node, size, seed_value)
	void_spawn_timer = rng.randf_range(2.8, 5.4)
	_create_obstacle(Vector2(map_size.x * 0.50, map_size.y * 0.28), Vector2(282, 58), Vector2(620, 170))
	_create_obstacle(Vector2(map_size.x * 0.50, map_size.y * 0.72), Vector2(282, 58), Vector2(620, 170))
	_create_obstacle(Vector2(map_size.x * 0.30, map_size.y * 0.50), Vector2(104, 218), Vector2(360, 310))
	_create_obstacle(Vector2(map_size.x * 0.70, map_size.y * 0.50), Vector2(104, 218), Vector2(360, 310))
	_create_obstacle(Vector2(map_size.x * 0.50, map_size.y * 0.50), Vector2(188, 76), Vector2(560, 290))

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	if playing:
		for obstacle in obstacles:
			_update_obstacle(obstacle, delta)
		_apply_squeeze_death(players)
		_update_void_traps(delta, players)
	if visuals_enabled:
		queue_redraw()

func get_blocking_rects() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	for obstacle in obstacles:
		rects.append(obstacle["rect"] as Rect2)
	return rects

func is_spawn_area_blocked(point: Vector2, radius: float) -> bool:
	if super.is_spawn_area_blocked(point, radius):
		return true
	for trap in void_traps:
		var center := trap["position"] as Vector2
		var trap_radius := float(trap.get("gravity_radius", trap.get("radius", 0.0)))
		if point.distance_squared_to(center) <= (trap_radius + radius) * (trap_radius + radius):
			return true
	return false

func _create_obstacle(center: Vector2, base_size: Vector2, roam: Vector2) -> void:
	var body := StaticBody2D.new()
	body.name = "MovingCloudWall"
	var shape := RectangleShape2D.new()
	shape.size = base_size
	var collision := CollisionShape2D.new()
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	var min_center := Vector2(maxf(70.0, center.x - roam.x), maxf(70.0, center.y - roam.y))
	var max_center := Vector2(minf(map_size.x - 70.0, center.x + roam.x), minf(map_size.y - 70.0, center.y + roam.y))
	var start := _random_center(min_center, max_center)
	var obstacle := {
		"center": start,
		"target": _random_center(min_center, max_center),
		"base_size": base_size,
		"size": base_size,
		"target_size": _random_size(base_size),
		"min_center": min_center,
		"max_center": max_center,
		"speed": rng.randf_range(MOVE_SPEED_MIN, MOVE_SPEED_MAX),
		"body": body,
		"shape": shape,
		"rect": Rect2(start - base_size * 0.5, base_size),
		"wait": rng.randf_range(WAIT_MIN, WAIT_MAX)
	}
	obstacles.append(obstacle)
	_apply_obstacle_transform(obstacle)

func _update_obstacle(obstacle: Dictionary, delta: float) -> void:
	var center := obstacle["center"] as Vector2
	var target := obstacle["target"] as Vector2
	var size := obstacle["size"] as Vector2
	var target_size := obstacle["target_size"] as Vector2
	var speed := float(obstacle["speed"])
	var wait := float(obstacle["wait"])
	if wait > 0.0:
		wait = maxf(0.0, wait - delta)
	else:
		center = center.move_toward(target, speed * delta)
	size = size.lerp(target_size, clampf(delta * 1.6, 0.0, 1.0))
	obstacle["center"] = center
	obstacle["size"] = size
	obstacle["wait"] = wait
	if wait <= 0.0 and center.distance_to(target) <= TARGET_REACHED_DISTANCE:
		_choose_next_target(obstacle)
	_apply_obstacle_transform(obstacle)

func _choose_next_target(obstacle: Dictionary) -> void:
	var base_size := obstacle["base_size"] as Vector2
	obstacle["target"] = _random_center(obstacle["min_center"] as Vector2, obstacle["max_center"] as Vector2)
	obstacle["target_size"] = _random_size(base_size)
	obstacle["speed"] = rng.randf_range(MOVE_SPEED_MIN, MOVE_SPEED_MAX)
	obstacle["wait"] = rng.randf_range(WAIT_MIN, WAIT_MAX)

func _random_center(min_center: Vector2, max_center: Vector2) -> Vector2:
	return Vector2(
		rng.randf_range(min_center.x, max_center.x),
		rng.randf_range(min_center.y, max_center.y)
	)

func _random_size(base_size: Vector2) -> Vector2:
	return Vector2(
		maxf(54.0, base_size.x * rng.randf_range(0.78, 1.36)),
		maxf(44.0, base_size.y * rng.randf_range(0.80, 1.30))
	)

func _apply_obstacle_transform(obstacle: Dictionary) -> void:
	var center := obstacle["center"] as Vector2
	var size := obstacle["size"] as Vector2
	var rect := Rect2(center - size * 0.5, size)
	obstacle["rect"] = rect
	var body := obstacle["body"] as StaticBody2D
	var shape := obstacle["shape"] as RectangleShape2D
	if body != null:
		body.position = center
	if shape != null:
		shape.size = size

func _apply_squeeze_death(players: Array) -> void:
	for player in players:
		if player == null or not player.is_alive:
			continue
		var player_radius := float(player.balance.player_radius)
		for obstacle in obstacles:
			var rect := obstacle["rect"] as Rect2
			if not rect.grow(player_radius * 0.35).has_point(player.global_position):
				continue
			if rect.has_point(player.global_position) or _is_squeezed_by_obstacle(rect, player.global_position, player_radius):
				_kill_squeezed_player(player)
				break

func _is_squeezed_by_obstacle(rect: Rect2, point: Vector2, radius: float) -> bool:
	var blocked := 0
	var directions: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	for direction in directions:
		var probe := point + direction * radius * SQUEEZE_SAMPLE_SCALE
		if rect.has_point(probe):
			blocked += 1
		elif arena_map != null and arena_map.has_method("is_point_blocked") and arena_map.is_point_blocked(probe):
			blocked += 1
	return blocked >= 3

func _kill_squeezed_player(player) -> void:
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("kill_player_by_environment"):
		root.kill_player_by_environment(player)
	elif player.has_method("kill_by_environment"):
		player.kill_by_environment()
	elif player.has_method("take_damage"):
		player.take_damage(99999.0, -1)

func _update_void_traps(delta: float, players: Array) -> void:
	var remaining: Array[Dictionary] = []
	for trap in void_traps:
		trap["age"] = float(trap.get("age", 0.0)) + delta
		var age := float(trap["age"])
		var duration := float(trap["duration"])
		if age >= VOID_OPEN_DURATION and age <= duration:
			_apply_void_trap(trap, players, delta)
		if age < duration + VOID_CLOSE_DURATION:
			remaining.append(trap)
	void_traps = remaining
	void_spawn_timer -= delta
	if void_spawn_timer <= 0.0:
		void_spawn_timer = rng.randf_range(VOID_SPAWN_INTERVAL_MIN, VOID_SPAWN_INTERVAL_MAX)
		if void_traps.size() < MAX_ACTIVE_VOID_TRAPS:
			_spawn_void_trap()

func _spawn_void_trap() -> void:
	var death_radius := rng.randf_range(VOID_DEATH_RADIUS_MIN, VOID_DEATH_RADIUS_MAX)
	var gravity_radius := maxf(death_radius + 78.0, rng.randf_range(VOID_GRAVITY_RADIUS_MIN, VOID_GRAVITY_RADIUS_MAX))
	var point := random_clear_point(death_radius + 34.0, 102.0, 90)
	void_traps.append({
		"position": point,
		"radius": death_radius,
		"gravity_radius": gravity_radius,
		"duration": rng.randf_range(VOID_DURATION_MIN, VOID_DURATION_MAX),
		"age": 0.0,
		"phase": rng.randf_range(0.0, TAU),
		"fallen": [],
	})

func _apply_void_trap(trap: Dictionary, players: Array, delta: float) -> void:
	var center := trap["position"] as Vector2
	var death_radius := float(trap["radius"])
	var gravity_radius := float(trap["gravity_radius"])
	var fallen: Array = trap["fallen"]
	for player in players:
		if player == null or not player.is_alive or fallen.has(player.player_id):
			continue
		var offset: Vector2 = center - player.global_position
		var distance: float = offset.length()
		if distance <= death_radius:
			fallen.append(player.player_id)
			_kill_void_player(player)
			continue
		if distance <= gravity_radius and distance > 0.001:
			var proximity := clampf(1.0 - (distance - death_radius) / maxf(gravity_radius - death_radius, 1.0), 0.0, 1.0)
			var pull := VOID_PULL_STRENGTH * (0.04 + proximity * proximity * 0.58)
			player.global_position += offset / distance * pull * delta
			player.global_position.x = clampf(player.global_position.x, 28.0, map_size.x - 28.0)
			player.global_position.y = clampf(player.global_position.y, 28.0, map_size.y - 28.0)

func _kill_void_player(player) -> void:
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("kill_player_by_void"):
		root.kill_player_by_void(player)
	elif player != null and player.has_method("kill_by_void"):
		player.kill_by_void()
	elif player != null and player.has_method("kill_by_environment"):
		player.kill_by_environment()

func _draw() -> void:
	if not visuals_enabled:
		return
	for trap in void_traps:
		_draw_void_trap(trap)
	for obstacle in obstacles:
		_draw_cloud_wall(obstacle["rect"] as Rect2)

func _draw_void_trap(trap: Dictionary) -> void:
	var center := trap["position"] as Vector2
	var death_radius := float(trap["radius"])
	var gravity_radius := float(trap["gravity_radius"])
	var age := float(trap["age"])
	var duration := float(trap["duration"])
	var phase := float(trap["phase"])
	var open_t := clampf(age / VOID_OPEN_DURATION, 0.0, 1.0)
	var close_t := clampf((duration + VOID_CLOSE_DURATION - age) / VOID_CLOSE_DURATION, 0.0, 1.0)
	var t := smoothstep(0.0, 1.0, minf(open_t, close_t))
	var outer_radius := gravity_radius * lerpf(0.18, 1.0, t)
	var hole_radius := death_radius * lerpf(0.2, 1.0, t)
	var alpha := t
	_draw_flat_ellipse(center + Vector2(10, 20), Vector2(outer_radius * 0.84, outer_radius * 0.30), Color("#000000", 0.18 * alpha))
	for i in range(7):
		var ring_t := float(i) / 6.0
		var ring_radius := lerpf(outer_radius, hole_radius * 0.85, ring_t)
		var color := Color("#8DD7FF").lerp(Color("#020713"), ring_t)
		var opacity := lerpf(0.07, 0.88, ring_t) * alpha
		_draw_flat_ellipse(center, Vector2(ring_radius, ring_radius * 0.48), Color(color.r, color.g, color.b, opacity))
	_draw_conic_gravity_curves(center, outer_radius, hole_radius, phase, age, alpha)
	_draw_flat_ellipse(center, Vector2(hole_radius, hole_radius * 0.46), Color("#000000", 0.96 * alpha))
	_draw_flat_ellipse(center + Vector2(0, -2), Vector2(hole_radius * 0.58, hole_radius * 0.24), Color("#01030A", alpha))
	_draw_flat_ellipse_arc(center, Vector2(outer_radius, outer_radius * 0.48), 0, TAU, Color("#8DD7FF", 0.28 * alpha), 2.2)
	_draw_flat_ellipse_arc(center, Vector2(hole_radius * 1.35, hole_radius * 0.62), phase + age * 1.4, phase + age * 1.4 + TAU, Color("#F2D36B", 0.32 * alpha), 1.8)
	if age > duration:
		var closing := clampf((age - duration) / VOID_CLOSE_DURATION, 0.0, 1.0)
		_draw_flat_ellipse_arc(center, Vector2(outer_radius * (1.0 + closing * 0.18), outer_radius * 0.48 * (1.0 + closing * 0.18)), 0, TAU, Color("#FFFFFF", 0.20 * (1.0 - closing)), 3.0)

func _draw_flat_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(maxf(radii.x, 1.0), maxf(radii.y, 1.0)))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_flat_ellipse_arc(center: Vector2, radii: Vector2, start_angle: float, end_angle: float, color: Color, width: float) -> void:
	var points := PackedVector2Array()
	var steps := 48
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var a := lerpf(start_angle, end_angle, t)
		points.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], color, width)

func _draw_conic_gravity_curves(center: Vector2, outer_radius: float, hole_radius: float, phase: float, age: float, alpha: float) -> void:
	for curve in range(5):
		var points := PackedVector2Array()
		var start := phase + TAU * float(curve) / 5.0 + age * 0.22
		for i in range(24):
			var t := float(i) / 23.0
			var a := start + t * PI * 1.35
			var r := lerpf(outer_radius * 0.88, hole_radius * 1.16, pow(t, 1.12))
			points.append(center + Vector2(cos(a) * r, sin(a) * r * 0.48))
		for i in range(points.size() - 1):
			var line_t := float(i) / float(maxi(points.size() - 2, 1))
			draw_line(points[i], points[i + 1], Color("#D7F1FF", (0.20 + 0.22 * line_t) * alpha), lerpf(1.2, 2.4, line_t))

func _draw_cloud_wall(rect: Rect2) -> void:
	_draw_flat_ellipse(rect.position + rect.size * Vector2(0.5, 1.12), Vector2(rect.size.x * 0.56, 18.0), Color("#000000", 0.15))
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y * 0.72), Vector2(rect.size.x, rect.size.y * 0.42)), Color("#86B6D3", 0.56))
	var segments := maxi(3, int(rect.size.x / 48.0))
	for i in range(segments):
		var t := float(i) / float(maxi(segments - 1, 1))
		var x := lerpf(rect.position.x + 18.0, rect.end.x - 18.0, t)
		var h := 0.55 + 0.28 * fposmod(sin(x * 0.09), 1.0)
		_draw_flat_ellipse(Vector2(x, rect.position.y + rect.size.y * 0.42), Vector2(42.0, 21.0) * h, Color("#FFFFFF", 0.84))
		_draw_flat_ellipse(Vector2(x + 11.0, rect.position.y + rect.size.y * 0.55), Vector2(45.0, 17.0) * h, Color("#DDF4FF", 0.64))
	draw_rect(rect, Color("#F7FCFF", 0.35))
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 4.0)), Color("#FFFFFF", 0.55))
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y - 5.0), Vector2(rect.size.x, 5.0)), Color("#7FB9DB", 0.26))
	draw_rect(rect, Color("#F2D36B", 0.24), false, 1.8)
	for x in range(int(rect.position.x) + 16, int(rect.end.x), 44):
		draw_circle(Vector2(x, rect.position.y + rect.size.y * 0.5), 5.5, Color("#8DD7FF", 0.16))
		draw_line(Vector2(x - 8, rect.position.y + 8), Vector2(x + 18, rect.end.y - 8), Color("#5AA9D8", 0.10), 1.1)
