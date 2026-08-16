extends RefCounted
# Converts high-level movement modes into normalized PlayerAction movement.
class_name MovementExecutor

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const CoverAnalyzer = preload("res://scripts/agents/cover_analyzer.gd")
const BallisticAimSolver = preload("res://scripts/agents/ballistic_aim_solver.gd")

const EPS := 0.00001

var last_mode: int = HighLevelDecision.MovementMode.KEEP_RANGE
var hold_timer: float = 0.0
var engagement_vantage_direction: Vector2 = Vector2.ZERO
var engagement_vantage_timer: float = 0.0

func reset() -> void:
	last_mode = HighLevelDecision.MovementMode.KEEP_RANGE
	hold_timer = 0.0
	engagement_vantage_direction = Vector2.ZERO
	engagement_vantage_timer = 0.0

func execute(obs: AgentObservation, decision: HighLevelDecision, target: Dictionary, scripted_action: PlayerAction, threat_info: Dictionary, cover_info: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig, delta: float) -> Dictionary:
	var mode := decision.movement_mode if decision != null else HighLevelDecision.MovementMode.KEEP_RANGE
	if mode == HighLevelDecision.MovementMode.USE_SCRIPTED_MOVEMENT and scripted_action != null:
		return _finish(scripted_action.move, mode, "scripted")
	mode = _apply_hysteresis(mode, threat_info, config, delta)
	var dir := Vector2.ZERO
	var reason := HighLevelDecision.movement_name(mode)
	var rel_target := _target_relative_world(obs, target, balance)
	var target_distance := rel_target.length()
	match mode:
		HighLevelDecision.MovementMode.HOLD:
			dir = Vector2.ZERO
		HighLevelDecision.MovementMode.CHASE:
			dir = _engagement_vantage(obs, target, rel_target, arena_map, balance, config, threat_info, delta) if target_distance > EPS else Vector2.ZERO
			if config != null and config.engagement_vantage_enabled and not dir.is_equal_approx(rel_target.normalized()):
				reason = "engagement_vantage"
		HighLevelDecision.MovementMode.KEEP_RANGE:
			dir = _keep_range(rel_target, target_distance, config)
		HighLevelDecision.MovementMode.STRAFE_CLOCKWISE:
			dir = rel_target.normalized().orthogonal() if target_distance > EPS else Vector2.ZERO
		HighLevelDecision.MovementMode.STRAFE_COUNTERCLOCKWISE:
			dir = -rel_target.normalized().orthogonal() if target_distance > EPS else Vector2.ZERO
		HighLevelDecision.MovementMode.RETREAT:
			dir = -rel_target.normalized() if target_distance > EPS else Vector2.ZERO
		HighLevelDecision.MovementMode.SEEK_COVER:
			dir = cover_info.get("cover_direction", Vector2.ZERO)
		HighLevelDecision.MovementMode.PEEK_FROM_COVER:
			dir = _peek_direction(rel_target, cover_info)
		HighLevelDecision.MovementMode.SEEK_BEST_PICKUP:
			dir = obs.nearest_resource_relative_position.normalized() if obs != null and obs.nearest_resource_relative_position.length_squared() > EPS else Vector2.ZERO
		HighLevelDecision.MovementMode.MOVE_TO_CENTER:
			dir = _center_direction(obs, balance)
		HighLevelDecision.MovementMode.EVADE_PROJECTILE:
			dir = threat_info.get("recommended_direction", Vector2.ZERO)
	if dir.length_squared() <= EPS:
		dir = cover_info.get("safe_space_direction", Vector2.ZERO)
	if dir.length_squared() > EPS:
		dir = _avoid_wall(obs, dir.normalized(), cover_info, arena_map, balance, config)
	return _finish(dir, mode, reason)

func _apply_hysteresis(mode: int, threat_info: Dictionary, config: HybridAgentConfig, delta: float) -> int:
	hold_timer = maxf(0.0, hold_timer - delta)
	var emergency := bool(threat_info.get("has_threat", false)) and float(threat_info.get("threat_level", 0.0)) >= (config.high_threat_threshold if config != null else 0.72)
	if emergency:
		last_mode = mode
		hold_timer = 0.0
		return mode
	if mode != last_mode and _is_jitter_pair(mode, last_mode) and hold_timer > 0.0:
		return last_mode
	if mode != last_mode:
		last_mode = mode
		hold_timer = config.movement_hysteresis if config != null else 0.18
	return mode

func _is_jitter_pair(a: int, b: int) -> bool:
	if (a == HighLevelDecision.MovementMode.STRAFE_CLOCKWISE and b == HighLevelDecision.MovementMode.STRAFE_COUNTERCLOCKWISE) or (a == HighLevelDecision.MovementMode.STRAFE_COUNTERCLOCKWISE and b == HighLevelDecision.MovementMode.STRAFE_CLOCKWISE):
		return true
	if (a == HighLevelDecision.MovementMode.CHASE and b == HighLevelDecision.MovementMode.RETREAT) or (a == HighLevelDecision.MovementMode.RETREAT and b == HighLevelDecision.MovementMode.CHASE):
		return true
	return false

func _keep_range(rel_target: Vector2, distance: float, config: HybridAgentConfig) -> Vector2:
	if distance <= EPS:
		return Vector2.ZERO
	var preferred := config.preferred_range if config != null else 420.0
	if distance > preferred * 1.18:
		return rel_target.normalized()
	if distance < preferred * 0.72:
		return -rel_target.normalized()
	return rel_target.normalized().orthogonal()

func _engagement_vantage(obs: AgentObservation, target: Dictionary, rel_target: Vector2, arena_map: Node, balance: GameBalance, config: HybridAgentConfig, threat_info: Dictionary, delta: float) -> Vector2:
	var direct := rel_target.normalized()
	if obs == null or direct.length_squared() <= EPS or config == null or not config.engagement_vantage_enabled:
		return direct
	engagement_vantage_timer = maxf(0.0, engagement_vantage_timer - delta)
	if bool(threat_info.get("has_threat", false)) and float(threat_info.get("threat_level", 0.0)) >= config.high_threat_threshold:
		engagement_vantage_direction = Vector2.ZERO
		engagement_vantage_timer = 0.0
		return direct
	if arena_map == null or not arena_map.has_method("is_line_blocked") or target.is_empty():
		return direct
	if _has_ballistic_lane(obs, target, arena_map, balance, config, obs.position):
		engagement_vantage_direction = Vector2.ZERO
		engagement_vantage_timer = 0.0
		return direct
	var target_world := obs.position + rel_target
	var probe := maxf(48.0, config.engagement_vantage_probe_distance)
	var samples := maxi(8, config.engagement_vantage_samples)
	var cover := CoverAnalyzer.new()
	if engagement_vantage_timer > 0.0 and engagement_vantage_direction.length_squared() > EPS and cover.candidate_is_safe(obs, engagement_vantage_direction, arena_map, balance, probe) and _has_ballistic_lane(obs, target, arena_map, balance, config, obs.position + engagement_vantage_direction * probe):
		return engagement_vantage_direction
	# Prefer a long side-step when it has a firing lane.  Around local walls the
	# long probe can be rejected even though a shorter lateral step is safe and
	# already opens the lane, so only fall back to shorter probes when necessary.
	var fallback_direction := direct
	var fallback_score := -INF
	for candidate_probe in [probe, probe * 0.60, probe * 0.35]:
		var best_lane_direction := Vector2.ZERO
		var best_lane_score := -INF
		for index in range(samples):
			var candidate_direction := Vector2.RIGHT.rotated(TAU * float(index) / float(samples))
			if not cover.candidate_is_safe(obs, candidate_direction, arena_map, balance, candidate_probe):
				continue
			var candidate: Vector2 = obs.position + candidate_direction * candidate_probe
			var has_lane := _has_ballistic_lane(obs, target, arena_map, balance, config, candidate)
			var candidate_distance: float = candidate.distance_to(target_world)
			var score: float = 0.55 * (1.0 - clampf(candidate_distance / maxf(rel_target.length() + candidate_probe, 1.0), 0.0, 1.0))
			score += 0.18 * candidate_direction.dot(direct)
			if has_lane and score > best_lane_score:
				best_lane_score = score
				best_lane_direction = candidate_direction
			elif candidate_probe == probe and score > fallback_score:
				fallback_score = score
				fallback_direction = candidate_direction
		if best_lane_direction.length_squared() > EPS:
			engagement_vantage_direction = best_lane_direction.normalized()
			engagement_vantage_timer = config.engagement_vantage_hold_seconds
			return engagement_vantage_direction
	engagement_vantage_direction = fallback_direction.normalized()
	engagement_vantage_timer = config.engagement_vantage_hold_seconds
	return engagement_vantage_direction

func _has_ballistic_lane(obs: AgentObservation, target: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig, shooter_position: Vector2) -> bool:
	if obs == null:
		return false
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var target_world := obs.position + AgentObservation.dict_to_vec(target.get("relative_position", {})) * map_size
	var candidate_target := target.duplicate(true)
	candidate_target["relative_position"] = AgentObservation.vec_to_dict((target_world - shooter_position) / map_size)
	var candidate_obs := AgentObservation.new()
	candidate_obs.position = shooter_position
	candidate_obs.aim_direction = obs.aim_direction
	var lane := BallisticAimSolver.evaluate_observation_lane(candidate_obs, candidate_target, balance, arena_map, config)
	return BallisticAimSolver.has_usable_lane(lane)

func _peek_direction(rel_target: Vector2, cover_info: Dictionary) -> Vector2:
	var cover_dir: Vector2 = cover_info.get("cover_direction", Vector2.ZERO)
	if rel_target.length_squared() <= EPS:
		return cover_dir
	var strafe := rel_target.normalized().orthogonal()
	if cover_dir.length_squared() > EPS and strafe.dot(cover_dir) < 0.0:
		strafe = -strafe
	return (strafe * 0.75 + cover_dir * 0.25).normalized()

func _avoid_wall(obs: AgentObservation, direction: Vector2, cover_info: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig) -> Vector2:
	var probe := config.wall_probe_distance if config != null else 120.0
	var cover := CoverAnalyzer.new()
	if not cover.would_hit_wall(obs, direction, arena_map, balance, probe):
		return direction
	var wall_dir: Vector2 = cover_info.get("nearest_wall_direction", Vector2.ZERO)
	var tangent := wall_dir.orthogonal() if wall_dir.length_squared() > EPS else direction.orthogonal()
	var safe_space: Vector2 = cover_info.get("safe_space_direction", Vector2.ZERO)
	var candidates: Array[Vector2] = [tangent, -tangent, safe_space, (safe_space + tangent).normalized(), (safe_space - tangent).normalized()]
	for candidate in candidates:
		if candidate.length_squared() > EPS and not cover.would_hit_wall(obs, candidate.normalized(), arena_map, balance, probe * 0.7):
			return candidate.normalized()
	return safe_space.normalized() if safe_space.length_squared() > EPS else Vector2.ZERO

func _target_relative_world(obs: AgentObservation, target: Dictionary, balance: GameBalance) -> Vector2:
	if obs == null or target.is_empty() or not bool(target.get("valid", false)):
		return Vector2.ZERO
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	return AgentObservation.dict_to_vec(target.get("relative_position", {})) * map_size

func _center_direction(obs: AgentObservation, balance: GameBalance) -> Vector2:
	if obs == null:
		return Vector2.ZERO
	var center := (balance.map_size if balance != null else Vector2(2160, 1215)) * 0.5
	var dir := center - obs.position
	return dir.normalized() if dir.length_squared() > EPS else Vector2.ZERO

func _finish(move: Vector2, mode: int, reason: String) -> Dictionary:
	var normalized := move.normalized() if move.length_squared() > 1.0 else move
	return {
		"move": normalized,
		"movement_mode": mode,
		"movement_reason": reason,
	}
