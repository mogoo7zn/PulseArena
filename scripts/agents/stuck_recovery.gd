extends RefCounted
# Detects non-tactical wall sticking and applies short deterministic recovery.
class_name StuckRecovery

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const CoverAnalyzer = preload("res://scripts/agents/cover_analyzer.gd")

const EPS := 0.00001

var position_history: Array[Vector2] = []
var command_history: Array[Vector2] = []
var mode_history: Array[int] = []
var recovery_timer: float = 0.0
var cooldown_timer: float = 0.0
var recovery_direction: Vector2 = Vector2.ZERO
var stuck_score: float = 0.0
var last_reason: String = ""

func reset() -> void:
	position_history.clear()
	command_history.clear()
	mode_history.clear()
	recovery_timer = 0.0
	cooldown_timer = 0.0
	recovery_direction = Vector2.ZERO
	stuck_score = 0.0
	last_reason = ""

func apply(obs: AgentObservation, intended_move: Vector2, movement_mode: int, cover_info: Dictionary, threat_info: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig, delta: float) -> Dictionary:
	cooldown_timer = maxf(0.0, cooldown_timer - delta)
	_record(obs, intended_move, movement_mode)
	if recovery_timer > 0.0:
		recovery_timer = maxf(0.0, recovery_timer - delta)
		if _recovered(obs, config):
			recovery_timer = 0.0
			cooldown_timer = config.stuck_recovery_cooldown
		else:
			return _result(recovery_direction, true, last_reason)
	var tactical_cover := bool(cover_info.get("has_cover_target", false)) and (movement_mode == HighLevelDecision.MovementMode.SEEK_COVER or movement_mode == HighLevelDecision.MovementMode.PEEK_FROM_COVER)
	var detected := _detect_stuck(config, tactical_cover)
	if detected and cooldown_timer <= 0.0:
		recovery_direction = _choose_recovery_direction(obs, intended_move, cover_info, threat_info, arena_map, balance)
		if recovery_direction.length_squared() > EPS:
			recovery_timer = config.stuck_recovery_duration
			last_reason = "stuck_recovery"
			return _result(recovery_direction, true, last_reason)
	return _result(intended_move, false, "")

func _record(obs: AgentObservation, intended_move: Vector2, movement_mode: int) -> void:
	if obs == null:
		return
	position_history.append(obs.position)
	command_history.append(intended_move)
	mode_history.append(movement_mode)
	while position_history.size() > 28:
		position_history.pop_front()
	while command_history.size() > 28:
		command_history.pop_front()
	while mode_history.size() > 28:
		mode_history.pop_front()

func _detect_stuck(config: HybridAgentConfig, tactical_cover: bool) -> bool:
	if tactical_cover or position_history.size() < 9:
		stuck_score = 0.0
		return false
	var displacement := position_history[0].distance_to(position_history[position_history.size() - 1])
	var avg_cmd := 0.0
	var flips := 0
	for i in range(command_history.size()):
		avg_cmd += command_history[i].length()
		if i > 0 and command_history[i].length_squared() > EPS and command_history[i - 1].length_squared() > EPS and command_history[i].dot(command_history[i - 1]) < -0.35:
			flips += 1
	avg_cmd /= float(maxi(command_history.size(), 1))
	var low_motion := displacement <= config.stuck_max_displacement
	var commanded := avg_cmd >= config.stuck_min_command
	var oscillating := flips >= 4
	stuck_score = clampf((1.0 - displacement / maxf(config.stuck_max_displacement, 1.0)) * 0.65 + avg_cmd * 0.35 + (0.25 if oscillating else 0.0), 0.0, 1.0)
	return commanded and low_motion and (stuck_score > 0.72 or oscillating)

func _choose_recovery_direction(obs: AgentObservation, intended_move: Vector2, cover_info: Dictionary, threat_info: Dictionary, arena_map: Node, balance: GameBalance) -> Vector2:
	var wall_dir: Vector2 = cover_info.get("nearest_wall_direction", Vector2.ZERO)
	var safe_space: Vector2 = cover_info.get("safe_space_direction", Vector2.ZERO)
	var threat_dir: Vector2 = threat_info.get("recommended_direction", Vector2.ZERO)
	var tangent := wall_dir.orthogonal() if wall_dir.length_squared() > EPS else intended_move.orthogonal()
	var candidates: Array[Vector2] = [
		safe_space,
		tangent,
		-tangent,
		(safe_space + tangent).normalized(),
		(safe_space - tangent).normalized(),
		threat_dir,
		-intended_move,
	]
	var cover := CoverAnalyzer.new()
	for candidate in candidates:
		if candidate.length_squared() <= EPS:
			continue
		var dir := candidate.normalized()
		if cover.candidate_is_safe(obs, dir, arena_map, balance, 104.0):
			return dir
	return safe_space.normalized() if safe_space.length_squared() > EPS else Vector2.ZERO

func _recovered(obs: AgentObservation, config: HybridAgentConfig) -> bool:
	if position_history.size() < 3 or obs == null:
		return false
	var recent := position_history[maxi(0, position_history.size() - 3)].distance_to(obs.position)
	return recent > config.stuck_max_displacement * 1.25

func _result(move: Vector2, active: bool, reason: String) -> Dictionary:
	return {
		"move": move.normalized() if move.length_squared() > 1.0 else move,
		"stuck_recovery_active": active,
		"stuck_score": stuck_score,
		"stuck_reason": reason,
		"recovery_cooldown": cooldown_timer,
	}
