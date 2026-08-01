extends RefCounted
# Converts high-level movement modes into normalized PlayerAction movement.
class_name MovementExecutor

const HighLevelDecision = preload("res://scripts/agents/hybrid/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid/hybrid_agent_config.gd")
const CoverAnalyzer = preload("res://scripts/agents/hybrid/cover_analyzer.gd")

const EPS := 0.00001

var last_mode: int = HighLevelDecision.MovementMode.KEEP_RANGE
var hold_timer: float = 0.0

func reset() -> void:
	last_mode = HighLevelDecision.MovementMode.KEEP_RANGE
	hold_timer = 0.0

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
			dir = rel_target.normalized() if target_distance > EPS else Vector2.ZERO
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
