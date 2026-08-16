extends RefCounted
# Analytic projectile intercept and deterministic aim validation.
class_name BallisticAimSolver

const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")

const EPS := 0.00001

static func solve_intercept(shooter_position: Vector2, target_position: Vector2, target_velocity: Vector2, projectile_speed: float, max_prediction_time: float = 1.4) -> Dictionary:
	if not _valid_vector(shooter_position) or not _valid_vector(target_position) or not _valid_vector(target_velocity):
		return _invalid_solution(shooter_position, target_position, "non_finite_input")
	if not is_finite(projectile_speed) or projectile_speed <= EPS:
		return _invalid_solution(shooter_position, target_position, "invalid_projectile_speed")
	var max_time := maxf(0.0, max_prediction_time)
	var relative := target_position - shooter_position
	var distance := relative.length()
	if distance <= EPS:
		return {
			"valid": true,
			"has_solution": true,
			"intercept_time": 0.0,
			"aim_point": target_position,
			"aim_direction": Vector2.RIGHT,
			"reason": "overlap",
		}
	if target_velocity.length_squared() <= EPS * EPS:
		var static_time := distance / projectile_speed
		if static_time > max_time:
			return _invalid_solution(shooter_position, target_position, "static_target_out_of_lifetime", static_time)
		return _valid_solution(shooter_position, target_position, static_time, "static_target")

	var a := target_velocity.dot(target_velocity) - projectile_speed * projectile_speed
	var b := 2.0 * relative.dot(target_velocity)
	var c := relative.dot(relative)
	var roots: Array[float] = []
	if absf(a) <= EPS:
		if absf(b) <= EPS:
			return _invalid_solution(shooter_position, target_position, "degenerate_no_linear_root")
		roots.append(-c / b)
	else:
		var discriminant := b * b - 4.0 * a * c
		if not is_finite(discriminant):
			return _invalid_solution(shooter_position, target_position, "non_finite_discriminant")
		if discriminant < -EPS:
			return _invalid_solution(shooter_position, target_position, "no_real_root")
		discriminant = maxf(0.0, discriminant)
		var sqrt_d := sqrt(discriminant)
		roots.append((-b - sqrt_d) / (2.0 * a))
		roots.append((-b + sqrt_d) / (2.0 * a))
	var best_t := INF
	for t in roots:
		if not is_finite(t):
			continue
		if t > EPS and t < best_t:
			best_t = t
	if best_t == INF:
		return _invalid_solution(shooter_position, target_position, "no_positive_root")
	if best_t > max_time:
		return _invalid_solution(shooter_position, target_position, "intercept_after_lifetime", best_t)
	var aim_point := target_position + target_velocity * best_t
	if not _valid_vector(aim_point):
		return _invalid_solution(shooter_position, target_position, "non_finite_aim_point")
	return _valid_solution(shooter_position, aim_point, best_t, "analytic")

static func solve_from_observation(obs: AgentObservation, target: Dictionary, balance: GameBalance, arena_map: Node, current_aim: Vector2, config: HybridAgentConfig, teammates: Array = []) -> Dictionary:
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var projectile_speed := balance.projectile_speed if balance != null else 850.0
	var projectile_lifetime := balance.projectile_lifetime if balance != null else 1.4
	var max_prediction_time := minf(config.max_prediction_time if config != null else projectile_lifetime, projectile_lifetime)
	var result := _empty_aim_result(obs.aim_direction if obs != null else Vector2.RIGHT)
	if obs == null or target.is_empty() or not bool(target.get("valid", false)):
		result["block_reason"] = "no_target"
		return result
	var shooter_position := obs.position
	var target_position := obs.position + AgentObservation.dict_to_vec(target.get("relative_position", {})) * map_size
	var target_velocity := AgentObservation.dict_to_vec(target.get("relative_velocity", {})) * projectile_speed
	var solution := solve_intercept(shooter_position, target_position, target_velocity, projectile_speed, max_prediction_time)
	result.merge(solution, true)
	var aim_point: Vector2 = solution.get("aim_point", target_position)
	var aim_direction := (aim_point - shooter_position).normalized() if shooter_position.distance_squared_to(aim_point) > EPS else obs.aim_direction
	if aim_direction.length_squared() <= EPS:
		aim_direction = Vector2.RIGHT
	result["aim_direction"] = aim_direction
	result["target_position"] = target_position
	result["target_velocity"] = target_velocity
	var direct_distance := shooter_position.distance_to(aim_point)
	var max_range := projectile_speed * projectile_lifetime
	result["within_lifetime"] = direct_distance <= max_range + 8.0
	result["line_of_sight"] = not _line_blocked(arena_map, shooter_position, aim_point)
	result["wall_blocked"] = _wall_blocks_bullet(arena_map, shooter_position, aim_direction, minf(direct_distance + 6.0, max_range))
	result["friendly_fire_risk"] = _friendly_fire_risk(obs, aim_direction, teammates, balance)
	result["target_invulnerable"] = bool(target.get("has_respawn_protection", false))
	var safe_current_aim := current_aim.normalized() if current_aim.length_squared() > EPS else obs.aim_direction
	result["aim_error"] = absf(safe_current_aim.angle_to(aim_direction))
	result["predicted_hit_probability"] = _hit_probability(result, direct_distance, max_range)
	result["valid_target"] = true
	if not bool(result["within_lifetime"]):
		result["block_reason"] = "target_out_of_range"
	elif bool(result["wall_blocked"]):
		result["block_reason"] = "wall_blocked"
	elif not bool(result["line_of_sight"]):
		result["block_reason"] = "no_line_of_sight"
	elif bool(result["friendly_fire_risk"]):
		result["block_reason"] = "friendly_fire_risk"
	elif bool(result["target_invulnerable"]):
		result["block_reason"] = "target_invulnerable"
	else:
		result["block_reason"] = ""
	return result

static func evaluate_observation_lane(obs: AgentObservation, target: Dictionary, balance: GameBalance, arena_map: Node, config: HybridAgentConfig) -> Dictionary:
	var current_aim := obs.aim_direction if obs != null else Vector2.RIGHT
	var result := solve_from_observation(obs, target, balance, arena_map, current_aim, config)
	result["current_line_of_sight"] = false
	if obs == null or target.is_empty() or not bool(target.get("valid", false)):
		return result
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var current_target_position := obs.position + AgentObservation.dict_to_vec(target.get("relative_position", {})) * map_size
	result["current_line_of_sight"] = not _line_blocked(arena_map, obs.position, current_target_position)
	return result

static func has_usable_lane(result: Dictionary) -> bool:
	return bool(result.get("valid_target", false)) \
		and bool(result.get("has_solution", false)) \
		and bool(result.get("within_lifetime", false)) \
		and bool(result.get("line_of_sight", false)) \
		and not bool(result.get("wall_blocked", false)) \
		and not bool(result.get("target_invulnerable", false))

static func smooth_aim(previous: Vector2, desired: Vector2, delta: float, smoothing_rate: float) -> Vector2:
	var fallback := previous.normalized() if previous.length_squared() > EPS else Vector2.RIGHT
	if desired.length_squared() <= EPS:
		return fallback
	var target := desired.normalized()
	var rate := maxf(smoothing_rate, 0.0)
	if rate <= EPS or delta <= 0.0:
		return target
	var t := clampf(delta * rate, 0.0, 1.0)
	return fallback.slerp(target, t).normalized()

static func _valid_solution(shooter_position: Vector2, aim_point: Vector2, intercept_time: float, reason: String) -> Dictionary:
	var direction := (aim_point - shooter_position).normalized() if shooter_position.distance_squared_to(aim_point) > EPS else Vector2.RIGHT
	return {
		"valid": true,
		"has_solution": true,
		"intercept_time": maxf(0.0, intercept_time),
		"aim_point": aim_point,
		"aim_direction": direction,
		"reason": reason,
	}

static func _invalid_solution(shooter_position: Vector2, target_position: Vector2, reason: String, suggested_time: float = -1.0) -> Dictionary:
	var direction := (target_position - shooter_position).normalized() if shooter_position.distance_squared_to(target_position) > EPS else Vector2.RIGHT
	return {
		"valid": false,
		"has_solution": false,
		"intercept_time": suggested_time if is_finite(suggested_time) else -1.0,
		"aim_point": target_position,
		"aim_direction": direction,
		"reason": reason,
	}

static func _empty_aim_result(fallback_aim: Vector2) -> Dictionary:
	var aim := fallback_aim.normalized() if fallback_aim.length_squared() > EPS else Vector2.RIGHT
	return {
		"valid": false,
		"has_solution": false,
		"valid_target": false,
		"aim_point": Vector2.ZERO,
		"aim_direction": aim,
		"intercept_time": -1.0,
		"aim_error": PI,
		"predicted_hit_probability": 0.0,
		"line_of_sight": false,
		"wall_blocked": false,
		"within_lifetime": false,
		"friendly_fire_risk": false,
		"target_invulnerable": false,
		"block_reason": "no_target",
		"reason": "no_target",
	}

static func _line_blocked(arena_map: Node, a: Vector2, b: Vector2) -> bool:
	if arena_map != null and arena_map.has_method("is_line_blocked"):
		return bool(arena_map.is_line_blocked(a, b))
	return false

static func _wall_blocks_bullet(arena_map: Node, origin: Vector2, direction: Vector2, distance: float) -> bool:
	if arena_map == null or direction.length_squared() <= EPS:
		return false
	if arena_map.has_method("ray_distance"):
		var ray_distance := float(arena_map.ray_distance(origin, direction, maxf(0.0, distance)))
		return ray_distance + 5.0 < distance
	if arena_map.has_method("is_line_blocked"):
		return bool(arena_map.is_line_blocked(origin, origin + direction.normalized() * distance))
	return false

static func _friendly_fire_risk(obs: AgentObservation, aim_direction: Vector2, teammates: Array, balance: GameBalance) -> bool:
	if obs == null or aim_direction.length_squared() <= EPS:
		return false
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var player_radius := balance.player_radius if balance != null else 22.0
	for player_data in obs.other_players:
		if not bool(player_data.get("valid", false)):
			continue
		if not bool(player_data.get("is_teammate", false)):
			continue
		if not bool(player_data.get("is_alive", false)):
			continue
		var rel := AgentObservation.dict_to_vec(player_data.get("relative_position", {})) * map_size
		var forward := rel.dot(aim_direction.normalized())
		if forward <= 8.0:
			continue
		var lateral := (rel - aim_direction.normalized() * forward).length()
		if lateral <= player_radius * 1.25 and forward < 780.0:
			return true
	for teammate in teammates:
		if teammate is Dictionary:
			var teammate_rel := AgentObservation.dict_to_vec(teammate.get("relative_position", {})) * map_size
			var f := teammate_rel.dot(aim_direction.normalized())
			var l := (teammate_rel - aim_direction.normalized() * f).length()
			if f > 8.0 and l <= player_radius * 1.25:
				return true
	return false

static func _hit_probability(result: Dictionary, distance: float, max_range: float) -> float:
	if not bool(result.get("has_solution", false)):
		return 0.0
	if bool(result.get("wall_blocked", false)) or not bool(result.get("line_of_sight", true)):
		return 0.0
	if bool(result.get("friendly_fire_risk", false)) or bool(result.get("target_invulnerable", false)):
		return 0.0
	var t := float(result.get("intercept_time", 0.0))
	var range_factor := 1.0 - clampf(distance / maxf(max_range, 1.0), 0.0, 1.0) * 0.32
	var time_factor := 1.0 - clampf(t / 1.4, 0.0, 1.0) * 0.42
	return clampf(range_factor * time_factor, 0.0, 1.0)

static func _valid_vector(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
