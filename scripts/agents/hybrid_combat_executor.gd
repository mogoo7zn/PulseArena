extends RefCounted
# Deterministic low-level executor for Hybrid Tactical Agent.
class_name HybridCombatExecutor

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/tactical_feature_builder.gd")
const ProjectileThreatAnalyzer = preload("res://scripts/agents/projectile_threat_analyzer.gd")
const CoverAnalyzer = preload("res://scripts/agents/cover_analyzer.gd")
const MovementExecutor = preload("res://scripts/agents/movement_executor.gd")
const FireControl = preload("res://scripts/agents/fire_control.gd")
const StuckRecovery = preload("res://scripts/agents/stuck_recovery.gd")
const BallisticAimSolver = preload("res://scripts/agents/ballistic_aim_solver.gd")

var feature_builder := TacticalFeatureBuilder.new()
var threat_analyzer := ProjectileThreatAnalyzer.new()
var cover_analyzer := CoverAnalyzer.new()
var movement_executor := MovementExecutor.new()
var fire_control := FireControl.new()
var stuck_recovery := StuckRecovery.new()
var last_aim: Vector2 = Vector2.RIGHT
var last_diagnostics: Dictionary = {}

func reset() -> void:
	movement_executor.reset()
	fire_control.reset()
	stuck_recovery.reset()
	last_aim = Vector2.RIGHT
	last_diagnostics.clear()

func execute(obs: AgentObservation, decision: HighLevelDecision, scripted_action: PlayerAction, scripted_target: Dictionary, controlled_player: Node2D, delta: float, tactical_context: Dictionary = {}) -> PlayerAction:
	var action := PlayerAction.new()
	var balance := _balance_for_player(controlled_player)
	var config := HybridAgentConfig.for_profile(str(tactical_context.get("engagement_profile_id", "baseline")))
	var arena_map := _arena_map_for_player(controlled_player)
	if obs == null:
		last_diagnostics = {"error": "missing_observation"}
		return scripted_action.copy() if scripted_action != null else action
	if decision == null:
		decision = HighLevelDecision.scripted_teacher()
	var target := feature_builder.select_target(obs, decision, scripted_target)
	var threat_info: Dictionary = tactical_context.get("threat_info", {})
	if threat_info.is_empty():
		threat_info = threat_analyzer.analyze(obs, balance, config)
	var cover_info := cover_analyzer.analyze(obs, target, arena_map, balance, config)
	var aim_solution := BallisticAimSolver.solve_from_observation(obs, target, balance, arena_map, last_aim, config)
	if not target.is_empty():
		aim_solution["target_health_ratio"] = float(target.get("health_ratio", 1.0))
	var desired_aim: Vector2 = aim_solution.get("aim_direction", obs.aim_direction)
	last_aim = BallisticAimSolver.smooth_aim(last_aim if last_aim.length_squared() > 0.001 else obs.aim_direction, desired_aim, delta, config.max_aim_smoothing_rate)
	action.aim = last_aim
	var fire_diag := fire_control.update(obs, decision, scripted_action, aim_solution, threat_info, balance, config, delta)
	action.shoot = bool(fire_diag.get("fire_allowed", false))
	var move_diag := movement_executor.execute(obs, decision, target, scripted_action, threat_info, cover_info, arena_map, balance, config, delta)
	var intended_move: Vector2 = move_diag.get("move", Vector2.ZERO)
	var safety_diag := _apply_safety_layer(obs, decision, intended_move, threat_info, target, balance, config)
	var move_after_safety: Vector2 = safety_diag.get("move", intended_move)
	var stuck_diag := stuck_recovery.apply(obs, move_after_safety, int(move_diag.get("movement_mode", decision.movement_mode)), cover_info, threat_info, arena_map, balance, config, delta)
	action.move = stuck_diag.get("move", move_after_safety)
	var skill_diag := _skill_action(obs, decision, scripted_action, threat_info, target, action.move, balance, config, safety_diag)
	action.dash = bool(skill_diag.get("dash", false))
	action.shield = bool(skill_diag.get("shield", false))
	action.normalize_vectors(obs.aim_direction)
	last_diagnostics = _diagnostics(obs, decision, target, aim_solution, fire_diag, move_diag, stuck_diag, threat_info, cover_info, safety_diag, skill_diag)
	return action

func get_diagnostics() -> Dictionary:
	return last_diagnostics.duplicate(true)

func _apply_safety_layer(obs: AgentObservation, decision: HighLevelDecision, intended_move: Vector2, threat_info: Dictionary, target: Dictionary, balance: GameBalance, config: HybridAgentConfig) -> Dictionary:
	var threat_level := float(threat_info.get("threat_level", 0.0))
	if threat_level < config.emergency_threat_threshold:
		return {"safety_override": false, "move": intended_move, "override_reason": ""}
	var kill_window := false
	if not target.is_empty():
		var damage_ratio := balance.projectile_damage / maxf(balance.max_health, 1.0)
		kill_window = float(target.get("health_ratio", 1.0)) <= damage_ratio + 0.05
	if kill_window and decision != null and decision.fire_mode == HighLevelDecision.FireMode.ALL_IN:
		return {"safety_override": false, "move": intended_move, "override_reason": "kill_window_preserved"}
	var evade: Vector2 = threat_info.get("recommended_direction", Vector2.ZERO)
	if evade.length_squared() <= 0.001:
		return {"safety_override": false, "move": intended_move, "override_reason": ""}
	return {
		"safety_override": true,
		"override_reason": "emergency_projectile",
		"move": evade.normalized(),
		"original_decision": decision.to_dict() if decision != null else {},
	}

func _skill_action(obs: AgentObservation, decision: HighLevelDecision, scripted_action: PlayerAction, threat_info: Dictionary, target: Dictionary, move: Vector2, balance: GameBalance, config: HybridAgentConfig, safety_diag: Dictionary) -> Dictionary:
	var out := {"dash": false, "shield": false, "skill_reason": ""}
	var mode := decision.skill_mode if decision != null else HighLevelDecision.SkillMode.NONE
	if mode == HighLevelDecision.SkillMode.USE_SCRIPTED_SKILL and scripted_action != null:
		out["dash"] = scripted_action.dash
		out["shield"] = scripted_action.shield
		out["skill_reason"] = "scripted"
		return out
	var energy := obs.energy_ratio * balance.max_energy
	var high_threat := float(threat_info.get("threat_level", 0.0)) >= config.high_threat_threshold
	var can_dash := obs.dash_cooldown_ratio <= 0.01 and energy >= balance.dash_energy_cost
	var can_shield := obs.shield_cooldown_ratio <= 0.01 and energy >= balance.shield_energy_cost
	match mode:
		HighLevelDecision.SkillMode.AUTO_DEFENSE:
			if high_threat and can_shield and (obs.health_ratio < 0.58 or bool(safety_diag.get("safety_override", false))):
				out["shield"] = true
				out["skill_reason"] = "auto_shield"
			elif high_threat and can_dash and move.length_squared() > 0.001:
				out["dash"] = true
				out["skill_reason"] = "auto_dash"
		HighLevelDecision.SkillMode.DASH_EVADE:
			out["dash"] = high_threat and can_dash and move.length_squared() > 0.001
			out["skill_reason"] = "dash_evade"
		HighLevelDecision.SkillMode.DASH_ENGAGE:
			out["dash"] = can_dash and not target.is_empty() and obs.energy_ratio > 0.50
			out["skill_reason"] = "dash_engage"
		HighLevelDecision.SkillMode.SHIELD:
			out["shield"] = can_shield and (high_threat or obs.health_ratio < 0.45)
			out["skill_reason"] = "shield"
		_:
			out["skill_reason"] = "none"
	return out

func _diagnostics(obs: AgentObservation, decision: HighLevelDecision, target: Dictionary, aim_solution: Dictionary, fire_diag: Dictionary, move_diag: Dictionary, stuck_diag: Dictionary, threat_info: Dictionary, cover_info: Dictionary, safety_diag: Dictionary, skill_diag: Dictionary) -> Dictionary:
	var aim_point: Vector2 = aim_solution.get("aim_point", Vector2.ZERO)
	return {
		"protocol_version": HighLevelDecision.PROTOCOL_VERSION,
		"target": HighLevelDecision.target_name(decision.target_slot),
		"movement_mode": HighLevelDecision.movement_name(int(move_diag.get("movement_mode", decision.movement_mode))),
		"fire_mode": HighLevelDecision.fire_name(int(fire_diag.get("fire_mode", decision.fire_mode))),
		"skill_mode": HighLevelDecision.skill_name(decision.skill_mode),
		"confidence": decision.confidence,
		"target_valid": not target.is_empty(),
		"line_of_sight": bool(aim_solution.get("line_of_sight", false)),
		"target_health_ratio": float(target.get("health_ratio", 0.0)) if not target.is_empty() else 0.0,
		"predicted_aim_point": AgentObservation.vec_to_dict(aim_point),
		"aim_error": float(aim_solution.get("aim_error", PI)),
		"predicted_hit_probability": float(fire_diag.get("predicted_hit_probability", 0.0)),
		"reserved_energy": float(fire_diag.get("reserved_energy", 0.0)),
		"reserve_ratio": float(fire_diag.get("reserve_ratio", 0.0)),
		"reserve_basis": str(fire_diag.get("reserve_basis", "base")),
		"fire_allowed": bool(fire_diag.get("fire_allowed", false)),
		"fire_block_reason": str(fire_diag.get("fire_block_reason", "")),
		"movement_reason": str(move_diag.get("movement_reason", "")),
		"burst_state": fire_diag.get("burst_state", {}),
		"stuck_score": float(stuck_diag.get("stuck_score", 0.0)),
		"stuck_recovery_active": bool(stuck_diag.get("stuck_recovery_active", false)),
		"primary_projectile_threat": float(threat_info.get("threat_level", 0.0)),
		"safety_override": bool(safety_diag.get("safety_override", false)),
		"override_reason": str(safety_diag.get("override_reason", "")),
		"skill_reason": str(skill_diag.get("skill_reason", "")),
		"nearest_wall_distance_ratio": float(cover_info.get("nearest_wall_distance_ratio", 1.0)),
	}

func _balance_for_player(controlled_player: Node2D) -> GameBalance:
	if controlled_player != null:
		var value: Variant = controlled_player.get("balance")
		if value is GameBalance:
			return value
	if ConfigDB != null:
		return ConfigDB.get_balance()
	return GameBalance.default()

func _arena_map_for_player(controlled_player: Node2D) -> Node:
	if controlled_player == null:
		return null
	var node: Node = controlled_player
	while node != null:
		var value: Variant = node.get("arena_map")
		if value is Node:
			return value
		node = node.get_parent()
	return null
