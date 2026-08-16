extends "res://scripts/arena/map_rules/map_rule_base.gd"
# 丛林地图规则，管理沼泽、伪装、蟒蛇生态和树丛障碍。
class_name JungleRule

const SWAMP_SPAWN_INTERVAL_MIN := 2.0
const SWAMP_SPAWN_INTERVAL_MAX := 3.8
const SWAMP_DURATION_MIN := 5.0
const SWAMP_DURATION_MAX := 10.0
const SWAMP_RADIUS_MIN := 128.0
const SWAMP_RADIUS_MAX := 210.0
const SWAMP_SPEED_MULTIPLIER := 0.5
const SWAMP_DAMAGE_PER_SECOND := 2.0
const SWAMP_DAMAGE_TICK_INTERVAL := 0.5
const MAX_ACTIVE_SWAMPS := 3
const SWAMP_LOBE_MIN := 7
const SWAMP_LOBE_MAX := 11

const CAMOUFLAGE_STILL_TIME := 3.0
const CAMOUFLAGE_MOVE_RESET_DISTANCE := 3.0
const CAMOUFLAGE_MAX_SPEED := 14.0
const CAMOUFLAGE_FADE_SPEED := 2.8

const SNAKE_INITIAL_SPAWN_MIN := 8.0
const SNAKE_INITIAL_SPAWN_MAX := 15.0
const SNAKE_SPAWN_INTERVAL_MIN := 20.0
const SNAKE_SPAWN_INTERVAL_MAX := 34.0
const SNAKE_MAX_ACTIVE := 2
const SNAKE_HEALTH := 150.0
const SNAKE_COLLISION_RADIUS := 28.0
const SNAKE_HIT_RADIUS := 30.0
const SNAKE_SAFE_SPAWN_DISTANCE := 300.0
const SNAKE_DEATH_LINGER := 2.0
const SNAKE_SEGMENTS := 10
const SNAKE_SEGMENT_SPACING := 20.0
const SNAKE_CHASE_SPEED := 118.0
const SNAKE_WANDER_SPEED := 54.0
const SNAKE_WANDER_REACHED_DISTANCE := 18.0
const SNAKE_WANDER_DISTANCE_MIN := 80.0
const SNAKE_WANDER_DISTANCE_MAX := 240.0
const SNAKE_WANDER_WAIT_MIN := 0.35
const SNAKE_WANDER_WAIT_MAX := 1.35
const SNAKE_PROXIMITY_AGGRO_RADIUS := 275.0
const SNAKE_PROJECTILE_ALERT_RADIUS := 520.0
const SNAKE_DEAGGRO_DISTANCE := 620.0
const SNAKE_NO_ATTACK_FORGET_TIME := 3.0
const SNAKE_MELEE_RANGE := 58.0
const SNAKE_BITE_DAMAGE := 22.0
const SNAKE_BITE_COOLDOWN := 1.45

var spawn_timer: float = 1.1
var swamps: Array[Dictionary] = []
var swamp_damage_timers: Dictionary = {}
var camouflage_states: Dictionary = {}
var snake_spawn_timer: float = 10.0
var snakes: Array[Dictionary] = []
var snake_counter: int = 0

func configure(map_node: Node, size: Vector2, seed_value: int) -> void:
	super.configure(map_node, size, seed_value)
	spawn_timer = rng.randf_range(0.7, 1.8)
	snake_spawn_timer = rng.randf_range(SNAKE_INITIAL_SPAWN_MIN, SNAKE_INITIAL_SPAWN_MAX)
	swamps.clear()
	swamp_damage_timers.clear()
	camouflage_states.clear()
	snakes.clear()
	snake_counter = 0

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	if not playing:
		_reset_camouflage(players)
		return
	_update_camouflage(delta, players)
	_update_swamp_damage_timers(delta)
	_update_swamps(delta, players)
	_update_snakes(delta, players, projectiles)
	spawn_timer -= delta
	if spawn_timer <= 0.0:
		spawn_timer = rng.randf_range(SWAMP_SPAWN_INTERVAL_MIN, SWAMP_SPAWN_INTERVAL_MAX)
		if swamps.size() < MAX_ACTIVE_SWAMPS:
			_spawn_swamp()
	snake_spawn_timer -= delta
	if snake_spawn_timer <= 0.0:
		snake_spawn_timer = rng.randf_range(SNAKE_SPAWN_INTERVAL_MIN, SNAKE_SPAWN_INTERVAL_MAX)
		if snakes.size() < SNAKE_MAX_ACTIVE:
			_spawn_snake(players)
	if visuals_enabled:
		queue_redraw()

func is_spawn_area_blocked(point: Vector2, radius: float) -> bool:
	if super.is_spawn_area_blocked(point, radius):
		return true
	for snake in snakes:
		if not _snake_is_alive(snake):
			continue
		var center := snake["position"] as Vector2
		var block_radius := SNAKE_COLLISION_RADIUS + radius
		if point.distance_squared_to(center) <= block_radius * block_radius:
			return true
	return false

func handle_projectile_hit(projectile) -> bool:
	if projectile == null:
		return false
	for snake in snakes:
		if not _snake_is_alive(snake):
			continue
		var center := snake["position"] as Vector2
		var hit_radius := SNAKE_HIT_RADIUS + float(projectile.radius)
		if projectile.global_position.distance_squared_to(center) <= hit_radius * hit_radius:
			_damage_snake(snake, float(projectile.damage), int(projectile.owner_id))
			return true
	return false

func apply_pulse_hit(center: Vector2, radius: float, damage: float, source_id: int) -> void:
	# 丛林蟒蛇属于地图生物，脉冲命中时按地图规则结算生命和仇恨。
	var radius_squared := radius * radius
	for snake in snakes:
		if not _snake_is_alive(snake):
			continue
		var snake_center := snake["position"] as Vector2
		if snake_center.distance_squared_to(center) <= radius_squared:
			_damage_snake(snake, damage, source_id)

func _update_camouflage(delta: float, players: Array) -> void:
	var active_ids: Dictionary = {}
	for player in players:
		if player == null:
			continue
		active_ids[player.player_id] = true
		var state: Dictionary = camouflage_states.get(player.player_id, {
			"last_position": player.global_position,
			"still": 0.0,
			"blend": 0.0,
		})
		if not player.is_alive:
			state["still"] = 0.0
			state["blend"] = move_toward(float(state.get("blend", 0.0)), 0.0, CAMOUFLAGE_FADE_SPEED * delta)
			state["last_position"] = player.global_position
			camouflage_states[player.player_id] = state
			if player.has_method("set_camouflage_intensity"):
				player.set_camouflage_intensity(float(state["blend"]))
			continue
		var last_position := state.get("last_position", player.global_position) as Vector2
		var moved: float = player.global_position.distance_to(last_position)
		var nearly_still: bool = moved <= CAMOUFLAGE_MOVE_RESET_DISTANCE and player.velocity.length() <= CAMOUFLAGE_MAX_SPEED
		state["still"] = float(state.get("still", 0.0)) + delta if nearly_still else 0.0
		var target := 1.0 if float(state["still"]) >= CAMOUFLAGE_STILL_TIME else 0.0
		state["blend"] = move_toward(float(state.get("blend", 0.0)), target, CAMOUFLAGE_FADE_SPEED * delta)
		state["last_position"] = player.global_position
		camouflage_states[player.player_id] = state
		if player.has_method("set_camouflage_intensity"):
			player.set_camouflage_intensity(float(state["blend"]))
	for key in camouflage_states.keys():
		if not active_ids.has(key):
			camouflage_states.erase(key)

func _reset_camouflage(players: Array) -> void:
	camouflage_states.clear()
	for player in players:
		if player != null and player.has_method("set_camouflage_intensity"):
			player.set_camouflage_intensity(0.0)

func _update_swamps(delta: float, players: Array) -> void:
	var remaining: Array[Dictionary] = []
	for swamp in swamps:
		swamp["age"] = float(swamp.get("age", 0.0)) + delta
		for player in players:
			if player != null and player.is_alive and _point_in_swamp(player.global_position, swamp):
				player.apply_map_speed_multiplier(SWAMP_SPEED_MULTIPLIER)
				if float(swamp_damage_timers.get(player.player_id, 0.0)) <= 0.0:
					_apply_swamp_damage(player, SWAMP_DAMAGE_PER_SECOND * SWAMP_DAMAGE_TICK_INTERVAL)
					swamp_damage_timers[player.player_id] = SWAMP_DAMAGE_TICK_INTERVAL
		if float(swamp["age"]) < float(swamp["duration"]):
			remaining.append(swamp)
	swamps = remaining

func _update_swamp_damage_timers(delta: float) -> void:
	for key in swamp_damage_timers.keys():
		swamp_damage_timers[key] = maxf(0.0, float(swamp_damage_timers[key]) - delta)
		if float(swamp_damage_timers[key]) <= 0.0:
			swamp_damage_timers.erase(key)

func _apply_swamp_damage(player, amount: float) -> void:
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("apply_environment_damage"):
		root.apply_environment_damage(player, amount, "jungle_swamp")
	elif player != null and player.has_method("take_damage"):
		player.take_damage(amount, -1)

func _spawn_swamp() -> void:
	var radius := rng.randf_range(SWAMP_RADIUS_MIN, SWAMP_RADIUS_MAX)
	var center := random_clear_point(radius * 0.35, 92.0, 90)
	swamps.append({
		"position": center,
		"radius": radius,
		"duration": rng.randf_range(SWAMP_DURATION_MIN, SWAMP_DURATION_MAX),
		"age": 0.0,
		"lobes": _make_lobes(radius)
	})

func _update_snakes(delta: float, players: Array, projectiles: Array) -> void:
	var remaining: Array[Dictionary] = []
	for snake in snakes:
		snake["age"] = float(snake.get("age", 0.0)) + delta
		if not _snake_is_alive(snake):
			snake["death_age"] = float(snake.get("death_age", 0.0)) + delta
			if float(snake["death_age"]) < SNAKE_DEATH_LINGER:
				remaining.append(snake)
			continue
		snake["hit_flash"] = maxf(0.0, float(snake.get("hit_flash", 0.0)) - delta)
		snake["bite_flash"] = maxf(0.0, float(snake.get("bite_flash", 0.0)) - delta)
		snake["bite_cooldown"] = maxf(0.0, float(snake.get("bite_cooldown", 0.0)) - delta)
		_scan_snake_alerts(snake, players, projectiles)
		_update_snake_ai(snake, players, delta)
		_update_snake_segments(snake)
		remaining.append(snake)
	snakes = remaining

func _scan_snake_alerts(snake: Dictionary, players: Array, projectiles: Array) -> void:
	var center := snake["position"] as Vector2
	var best_player_id := -1
	var best_distance_sq := SNAKE_PROXIMITY_AGGRO_RADIUS * SNAKE_PROXIMITY_AGGRO_RADIUS
	for player in players:
		if player == null or not player.is_alive:
			continue
		var distance_sq: float = player.global_position.distance_squared_to(center)
		if distance_sq <= best_distance_sq:
			best_distance_sq = distance_sq
			best_player_id = player.player_id
	if best_player_id >= 0:
		_set_snake_target(snake, best_player_id, false)
	for projectile in projectiles:
		if projectile == null or int(projectile.owner_id) < 0:
			continue
		if projectile.global_position.distance_squared_to(center) <= SNAKE_PROJECTILE_ALERT_RADIUS * SNAKE_PROJECTILE_ALERT_RADIUS:
			_set_snake_target(snake, int(projectile.owner_id), true)
			return

func _update_snake_ai(snake: Dictionary, players: Array, delta: float) -> void:
	var target_id := int(snake.get("target_id", -1))
	if target_id < 0:
		_update_snake_wander(snake, delta)
		return
	var target = _player_by_id(players, target_id)
	if target == null or not target.is_alive:
		_clear_snake_target(snake)
		return
	var center := snake["position"] as Vector2
	var offset: Vector2 = target.global_position - center
	var distance := offset.length()
	var no_attack_time := float(snake.get("age", 0.0)) - float(snake.get("last_attack_age", -999.0))
	if distance > SNAKE_DEAGGRO_DISTANCE and no_attack_time >= SNAKE_NO_ATTACK_FORGET_TIME:
		_clear_snake_target(snake)
		return
	if distance > SNAKE_MELEE_RANGE * 0.82:
		_move_snake_toward(snake, offset / maxf(distance, 0.001), delta)
	else:
		_try_snake_bite(snake, target)

func _update_snake_wander(snake: Dictionary, delta: float) -> void:
	var wait := maxf(0.0, float(snake.get("wander_wait", 0.0)) - delta)
	snake["wander_wait"] = wait
	if wait > 0.0:
		return
	var center := snake["position"] as Vector2
	var target := snake.get("wander_target", center) as Vector2
	var offset: Vector2 = target - center
	var distance := offset.length()
	if distance <= SNAKE_WANDER_REACHED_DISTANCE:
		_choose_snake_wander_target(snake)
		return
	if not _move_snake_toward(snake, offset / maxf(distance, 0.001), delta, SNAKE_WANDER_SPEED):
		_choose_snake_wander_target(snake)

func _choose_snake_wander_target(snake: Dictionary) -> void:
	var center := snake["position"] as Vector2
	for _attempt in range(12):
		var angle := rng.randf_range(0.0, TAU)
		var distance := rng.randf_range(SNAKE_WANDER_DISTANCE_MIN, SNAKE_WANDER_DISTANCE_MAX)
		var candidate := center + Vector2.RIGHT.rotated(angle) * distance
		candidate.x = clampf(candidate.x, SNAKE_COLLISION_RADIUS, map_size.x - SNAKE_COLLISION_RADIUS)
		candidate.y = clampf(candidate.y, SNAKE_COLLISION_RADIUS, map_size.y - SNAKE_COLLISION_RADIUS)
		if _snake_position_clear(candidate, SNAKE_COLLISION_RADIUS, int(snake["id"])):
			snake["wander_target"] = candidate
			snake["wander_wait"] = rng.randf_range(SNAKE_WANDER_WAIT_MIN, SNAKE_WANDER_WAIT_MAX)
			return
	snake["wander_target"] = center
	snake["wander_wait"] = rng.randf_range(SNAKE_WANDER_WAIT_MIN, SNAKE_WANDER_WAIT_MAX)

func _move_snake_toward(snake: Dictionary, direction: Vector2, delta: float, speed: float = SNAKE_CHASE_SPEED) -> bool:
	if direction.length_squared() <= 0.001:
		return false
	var snake_id := int(snake["id"])
	var current := snake["position"] as Vector2
	var step := speed * delta
	var candidates: Array[Vector2] = [
		current + direction * step,
		current + direction.rotated(0.62) * step,
		current + direction.rotated(-0.62) * step,
	]
	for candidate in candidates:
		candidate.x = clampf(candidate.x, SNAKE_COLLISION_RADIUS, map_size.x - SNAKE_COLLISION_RADIUS)
		candidate.y = clampf(candidate.y, SNAKE_COLLISION_RADIUS, map_size.y - SNAKE_COLLISION_RADIUS)
		if _snake_position_clear(candidate, SNAKE_COLLISION_RADIUS, snake_id):
			snake["position"] = candidate
			var current_heading := float(snake.get("heading", direction.angle()))
			snake["heading"] = lerp_angle(current_heading, direction.angle(), 0.16)
			return true
	return false

func _try_snake_bite(snake: Dictionary, player) -> void:
	if float(snake.get("bite_cooldown", 0.0)) > 0.0:
		return
	snake["bite_cooldown"] = SNAKE_BITE_COOLDOWN
	snake["bite_flash"] = 0.18
	if player != null and player.has_method("add_movement_lock"):
		player.add_movement_lock(0.08)
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("apply_environment_damage"):
		root.apply_environment_damage(player, SNAKE_BITE_DAMAGE, "jungle_snake")
	elif player != null and player.has_method("take_damage"):
		player.take_damage(SNAKE_BITE_DAMAGE, -1)

func _spawn_snake(players: Array) -> void:
	for _attempt in range(36):
		var point := random_clear_point(SNAKE_COLLISION_RADIUS + 38.0, 120.0, 24)
		if _snake_spawn_too_close_to_player(point, players):
			continue
		snake_counter += 1
		var heading := rng.randf_range(0.0, TAU)
		var heading_dir := Vector2.RIGHT.rotated(heading)
		snakes.append({
			"id": snake_counter,
			"position": point,
			"heading": heading,
			"hp": SNAKE_HEALTH,
			"max_hp": SNAKE_HEALTH,
			"target_id": -1,
			"last_attack_age": -999.0,
			"age": 0.0,
			"death_age": 0.0,
			"hit_flash": 0.0,
			"bite_flash": 0.0,
			"bite_cooldown": rng.randf_range(0.3, 0.9),
			"phase": rng.randf_range(0.0, TAU),
			"wander_target": point,
			"wander_wait": rng.randf_range(SNAKE_WANDER_WAIT_MIN, SNAKE_WANDER_WAIT_MAX),
			"segments": _make_snake_segments(point, heading_dir),
		})
		return

func _snake_spawn_too_close_to_player(point: Vector2, players: Array) -> bool:
	for player in players:
		if player != null and player.is_alive and player.global_position.distance_squared_to(point) <= SNAKE_SAFE_SPAWN_DISTANCE * SNAKE_SAFE_SPAWN_DISTANCE:
			return true
	return false

func _make_snake_segments(position: Vector2, heading_dir: Vector2) -> Array:
	var segments: Array = []
	for i in range(SNAKE_SEGMENTS):
		segments.append(position - heading_dir * SNAKE_SEGMENT_SPACING * float(i))
	return segments

func _update_snake_segments(snake: Dictionary) -> void:
	var segments: Array = snake["segments"]
	if segments.is_empty():
		segments = _make_snake_segments(snake["position"] as Vector2, Vector2.RIGHT.rotated(float(snake.get("heading", 0.0))))
	segments[0] = snake["position"] as Vector2
	for i in range(1, segments.size()):
		var previous := segments[i - 1] as Vector2
		var current := segments[i] as Vector2
		var offset := current - previous
		var distance := offset.length()
		if distance > SNAKE_SEGMENT_SPACING:
			segments[i] = previous + offset / distance * SNAKE_SEGMENT_SPACING
	snake["segments"] = segments

func _damage_snake(snake: Dictionary, amount: float, attacker_id: int) -> void:
	if not _snake_is_alive(snake):
		return
	snake["hp"] = maxf(0.0, float(snake.get("hp", SNAKE_HEALTH)) - maxf(0.0, amount))
	snake["hit_flash"] = 0.16
	_set_snake_target(snake, attacker_id, true)
	if float(snake["hp"]) <= 0.0:
		snake["target_id"] = -1
		snake["death_age"] = 0.0

func _set_snake_target(snake: Dictionary, player_id: int, count_as_attack: bool) -> void:
	if player_id < 0:
		return
	snake["target_id"] = player_id
	if count_as_attack:
		snake["last_attack_age"] = float(snake.get("age", 0.0))

func _clear_snake_target(snake: Dictionary) -> void:
	snake["target_id"] = -1

func _player_by_id(players: Array, player_id: int):
	for player in players:
		if player != null and player.player_id == player_id:
			return player
	return null

func _snake_is_alive(snake: Dictionary) -> bool:
	return float(snake.get("hp", 0.0)) > 0.0

func _snake_position_clear(point: Vector2, radius: float, self_id: int) -> bool:
	if point.x < radius or point.y < radius or point.x > map_size.x - radius or point.y > map_size.y - radius:
		return false
	if arena_map != null and arena_map.has_method("get_wall_rects"):
		for rect in arena_map.get_wall_rects():
			if (rect as Rect2).grow(radius).has_point(point):
				return false
	for snake in snakes:
		if int(snake.get("id", -1)) == self_id or not _snake_is_alive(snake):
			continue
		var center := snake["position"] as Vector2
		var block_radius := radius + SNAKE_COLLISION_RADIUS
		if point.distance_squared_to(center) <= block_radius * block_radius:
			return false
	return true

func _make_lobes(radius: float) -> Array[Dictionary]:
	var lobes: Array[Dictionary] = [{
		"offset": Vector2.ZERO,
		"radius": radius * rng.randf_range(0.58, 0.78)
	}]
	var count := rng.randi_range(SWAMP_LOBE_MIN, SWAMP_LOBE_MAX)
	for i in range(count):
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.55, 0.55)
		var distance := rng.randf_range(radius * 0.16, radius * 0.68)
		lobes.append({
			"offset": Vector2.RIGHT.rotated(angle) * distance,
			"radius": radius * rng.randf_range(0.30, 0.58)
		})
	return lobes

func _point_in_swamp(point: Vector2, swamp: Dictionary) -> bool:
	var center := swamp["position"] as Vector2
	var lobes := swamp["lobes"] as Array
	for lobe in lobes:
		var offset := lobe["offset"] as Vector2
		var radius := float(lobe["radius"])
		if point.distance_squared_to(center + offset) <= radius * radius:
			return true
	return false

func _draw() -> void:
	if not visuals_enabled:
		return
	for swamp in swamps:
		_draw_swamp(swamp)
	for snake in snakes:
		_draw_snake(snake)

func _draw_swamp(swamp: Dictionary) -> void:
	var center := swamp["position"] as Vector2
	var radius := float(swamp["radius"])
	var age := float(swamp["age"])
	var fade := clampf(1.0 - age / float(swamp["duration"]), 0.0, 1.0)
	var pulse := 0.5 + 0.5 * sin(age * 3.4)
	var lobes := swamp["lobes"] as Array
	var boundary := _shape_boundary_points(center, lobes, 52, age * 0.035)
	var inner := PackedVector2Array()
	for point in boundary:
		inner.append(center + (point - center) * 0.72)
	draw_polygon(boundary, _solid_colors(boundary.size(), Color("#0B2010", 0.34 * fade)))
	draw_polygon(inner, _solid_colors(inner.size(), Color("#234A24", 0.18 * fade)))
	for lobe in lobes:
		var offset := lobe["offset"] as Vector2
		var lobe_radius := float(lobe["radius"])
		draw_circle(center + offset + Vector2(6, 8), lobe_radius * 0.28, Color("#020A06", 0.16 * fade))
		draw_circle(center + offset - Vector2(4, 3), lobe_radius * 0.18, Color("#8DFF7A", 0.055 * fade))
	_draw_closed_polyline(boundary, Color("#8DFF7A", (0.26 + pulse * 0.10) * fade), 2.4)
	_draw_closed_polyline(boundary, Color("#F07178", 0.08 * fade), 5.0)
	_draw_closed_polyline(inner, Color("#C7E36F", 0.10 * fade), 1.2)
	for i in range(7):
		var y := center.y - radius * 0.43 + float(i) * radius * 0.14
		var wave := sin(age * 0.8 + float(i)) * 16.0
		draw_line(Vector2(center.x - radius * 0.42, y), Vector2(center.x + radius * 0.42, y + wave), Color("#B7A15C", 0.10 * fade), 2.0)
	for i in range(10):
		var a := TAU * float(i) / 10.0 + age * 0.18
		var p := center + Vector2.RIGHT.rotated(a) * radius * (0.20 + 0.34 * fposmod(sin(float(i) * 7.17), 1.0))
		draw_circle(p, 2.0 + 2.4 * fposmod(sin(float(i) * 5.33), 1.0), Color("#D8B56E", 0.10 * fade))
		draw_circle(p + Vector2(1, -1), 1.2, Color("#F1F5FA", 0.08 * fade))

func _draw_snake(snake: Dictionary) -> void:
	var segments: Array = snake["segments"]
	if segments.is_empty():
		return
	var alive := _snake_is_alive(snake)
	var age := float(snake.get("age", 0.0))
	var phase := float(snake.get("phase", 0.0))
	var hit_flash := clampf(float(snake.get("hit_flash", 0.0)) / 0.16, 0.0, 1.0)
	var bite_flash := clampf(float(snake.get("bite_flash", 0.0)) / 0.18, 0.0, 1.0)
	var death_fade := 1.0
	if not alive:
		death_fade = 1.0 - clampf(float(snake.get("death_age", 0.0)) / SNAKE_DEATH_LINGER, 0.0, 1.0)
	var alpha := 1.0 if alive else 0.46 * death_fade
	var head := snake["position"] as Vector2
	var heading := Vector2.RIGHT.rotated(float(snake.get("heading", 0.0)))
	var body_points: Array[Vector2] = []
	for i in range(segments.size()):
		var point := segments[i] as Vector2
		var bend_dir := heading.orthogonal()
		if i > 0:
			var previous := segments[maxi(i - 1, 0)] as Vector2
			var next := segments[maxi(i - 1, 0)] as Vector2
			if i + 1 < segments.size():
				next = segments[i + 1] as Vector2
			var tangent := (previous - next).normalized()
			if tangent.length_squared() > 0.001:
				bend_dir = tangent.orthogonal()
		var side_wave := sin(age * 4.0 + phase + float(i) * 0.58) * 4.4 * (1.0 - float(i) / float(segments.size()))
		body_points.append(point + bend_dir * side_wave)
	for i in range(body_points.size() - 1, -1, -1):
		var p := body_points[i]
		var t := 1.0 - float(i) / float(maxi(body_points.size() - 1, 1))
		var width := lerpf(9.0, 21.0, t)
		var base := Color("#244820").lerp(Color("#5F7C2E"), t * 0.55)
		if not alive:
			base = Color("#1B2418").lerp(Color("#3A4324"), t)
		if hit_flash > 0.0:
			base = base.lerp(Color("#F1F5FA"), hit_flash * 0.75)
		draw_circle(p + Vector2(2, 5), width + 1.8, Color("#000000", 0.24 * alpha))
		draw_circle(p, width, Color(base.r, base.g, base.b, 0.92 * alpha))
		draw_circle(p - Vector2(0, width * 0.22), width * 0.36, Color("#C7E36F", 0.14 * alpha))
		if i % 2 == 0:
			draw_circle(p + heading.orthogonal() * width * 0.28, width * 0.20, Color("#0B2010", 0.28 * alpha))
			draw_circle(p - heading.orthogonal() * width * 0.28, width * 0.20, Color("#0B2010", 0.28 * alpha))
	for i in range(body_points.size() - 1):
		draw_line(body_points[i], body_points[i + 1], Color("#0B2010", 0.42 * alpha), 5.0)
	var head_color := Color("#3D6728") if alive else Color("#26301E")
	if hit_flash > 0.0:
		head_color = head_color.lerp(Color("#F1F5FA"), hit_flash * 0.85)
	_draw_oriented_ellipse(head + Vector2(3, 6), heading.angle(), Vector2(26, 17), Color("#000000", 0.25 * alpha))
	_draw_oriented_ellipse(head, heading.angle(), Vector2(24, 17), Color(head_color.r, head_color.g, head_color.b, 0.98 * alpha))
	draw_arc(head, 25.0, heading.angle() + PI * 0.70, heading.angle() + PI * 1.30, 22, Color("#07100B", 0.62 * alpha), 2.2)
	var side := heading.orthogonal()
	draw_circle(head + heading * 10.0 + side * 6.0, 2.3, Color("#F1F5FA", 0.82 * alpha))
	draw_circle(head + heading * 10.0 - side * 6.0, 2.3, Color("#F1F5FA", 0.82 * alpha))
	draw_circle(head + heading * 10.8 + side * 6.0, 1.1, Color("#07100B", 0.95 * alpha))
	draw_circle(head + heading * 10.8 - side * 6.0, 1.1, Color("#07100B", 0.95 * alpha))
	if alive:
		var tongue_alpha := maxf(0.25, bite_flash)
		var tongue_base := head + heading * 21.0
		var tongue_tip := tongue_base + heading * (10.0 + bite_flash * 10.0)
		draw_line(tongue_base, tongue_tip, Color("#F07178", 0.65 * tongue_alpha), 1.8)
		draw_line(tongue_tip, tongue_tip + (heading + side * 0.55).normalized() * 7.0, Color("#F07178", 0.52 * tongue_alpha), 1.3)
		draw_line(tongue_tip, tongue_tip + (heading - side * 0.55).normalized() * 7.0, Color("#F07178", 0.52 * tongue_alpha), 1.3)
		_draw_snake_health_bar(snake, head)

func _draw_snake_health_bar(snake: Dictionary, head: Vector2) -> void:
	var ratio := clampf(float(snake.get("hp", 0.0)) / maxf(float(snake.get("max_hp", SNAKE_HEALTH)), 1.0), 0.0, 1.0)
	var width := 62.0
	var rect := Rect2(head + Vector2(-width * 0.5, -42.0), Vector2(width, 5.0))
	draw_rect(rect.grow(1.0), Color("#030712", 0.48))
	draw_rect(rect, Color("#243047", 0.82))
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * ratio, rect.size.y)), Color("#8DFF7A", 0.88))
	draw_rect(rect, Color("#F1F5FA", 0.16), false, 1.0)

func _draw_oriented_ellipse(center: Vector2, rotation: float, radii: Vector2, color: Color) -> void:
	draw_set_transform(center, rotation, Vector2(maxf(radii.x, 1.0), maxf(radii.y, 1.0)))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
