extends SceneTree
# Godot 集成测试入口，批量执行项目级运行时断言。

const BallisticAimSolver = preload("res://scripts/agents/hybrid/ballistic_aim_solver.gd")
const FireControl = preload("res://scripts/agents/hybrid/fire_control.gd")
const HighLevelDecision = preload("res://scripts/agents/hybrid/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid/hybrid_agent_config.gd")
const StuckRecovery = preload("res://scripts/agents/hybrid/stuck_recovery.gd")
const MovementExecutor = preload("res://scripts/agents/hybrid/movement_executor.gd")
const CoverAnalyzer = preload("res://scripts/agents/hybrid/cover_analyzer.gd")
const DebugEventLog = preload("res://scripts/debug/debug_event_log.gd")
const DebugRuntimeSnapshot = preload("res://scripts/debug/debug_runtime_snapshot.gd")
const TacticalTrainingProtocolTest = preload("res://tests/unit/tactical_training_protocol_test.gd")
class FakeHybridMap:
	extends Node

	var line_blocked: bool = false
	var block_positive_x: bool = false

	func is_line_blocked(_a: Vector2, _b: Vector2) -> bool:
		return line_blocked

	func ray_distance(_origin: Vector2, direction: Vector2, max_distance: float) -> float:
		if line_blocked:
			return max_distance * 0.35
		if block_positive_x and direction.x > 0.2:
			return max_distance * 0.25
		return max_distance

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return not line_blocked

func _init() -> void:
	var failures := 0
	failures += _test_player_action()
	failures += _test_observation()
	failures += _test_rules()
	failures += _test_visibility_filter()
	failures += _test_mode_configs()
	failures += _test_observation_player_privacy()
	failures += _test_hybrid_ballistics()
	failures += _test_hybrid_fire_control()
	failures += _test_hybrid_movement_and_stuck()
	failures += _test_hybrid_protocol()
	failures += _test_debug_data()
	failures += TacticalTrainingProtocolTest.new().run()
	if failures == 0:
		print("PASS: Godot unit tests")
		quit(0)
	else:
		push_error("FAIL: %d Godot tests failed" % failures)
		quit(1)

func _test_player_action() -> int:
	var action := PlayerAction.new()
	action.move = Vector2(2, 0)
	action.aim = Vector2.ZERO
	action.shoot = true
	action.normalize_vectors(Vector2.UP)
	var copy := PlayerAction.from_dict(action.to_dict(), Vector2.RIGHT)
	return 0 if copy.move.is_equal_approx(Vector2.RIGHT) and copy.aim.is_equal_approx(Vector2.UP) and copy.shoot else 1

func _test_observation() -> int:
	var obs := AgentObservation.new()
	obs.player_id = 7
	var flat := obs.to_flat_array()
	var restored := AgentObservation.from_dict(obs.to_dict())
	return 0 if flat.size() > 100 and restored.player_id == 7 else 1

func _test_rules() -> int:
	var ffa := MatchConfig.preset_human_vs_agent(3)
	var team := MatchConfig.preset_2_humans_vs_2_agents()
	if TeamRules.are_teammates(ffa, 0, 0, 0, 1):
		return 1
	if not TeamRules.are_teammates(team, 0, 0, 0, 1):
		return 1
	if TeamRules.can_damage(team, 0, 0, 0, 1):
		return 1
	return 0

func _test_visibility_filter() -> int:
	if not _contains_private_fields({"magazine": 6, "health_ratio": 0.5}):
		return 1
	if not _contains_private_fields({"reloadRemaining": 0.25}):
		return 1
	if _contains_private_fields({"health_ratio": 0.5, "is_dashing": true, "valid": true}):
		return 1
	return 0

func _test_mode_configs() -> int:
	var configs: Array[MatchConfig] = [
		MatchConfig.preset_human_vs_agent(1),
		MatchConfig.preset_human_vs_agent(2),
		MatchConfig.preset_human_vs_agent(3),
		MatchConfig.preset_2_humans_vs_2_agents(),
		MatchConfig.preset_training_ffa_agents(4),
	]
	for config in configs:
		if config.total_players() > 4:
			return 1
	return 0

func _test_observation_player_privacy() -> int:
	var observed := [
		{
			"relative_position": {"x": 0.1, "y": 0.0},
			"relative_velocity": {"x": 0.0, "y": 0.0},
			"aim_direction": {"x": 1.0, "y": 0.0},
			"health_ratio": 0.5,
			"is_teammate": false,
			"is_alive": true,
			"is_shielding": false,
			"is_dashing": false,
			"has_respawn_protection": false,
			"valid": true,
		}
	]
	if _contains_private_fields(observed):
		return 1
	for entry in observed:
		if bool(entry.get("valid", false)):
			if not entry.has("health_ratio"):
				return 1
			if entry.has("energy_ratio") or entry.has("shoot_cooldown_ratio") or entry.has("magazine"):
				return 1
	return 0

func _test_hybrid_ballistics() -> int:
	var failures := 0
	var s := Vector2.ZERO
	var static_hit := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2.ZERO, 100.0, 2.0)
	if not bool(static_hit.get("has_solution", false)) or absf(float(static_hit.get("intercept_time", 0.0)) - 1.0) > 0.01:
		failures += 1
	var lateral := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2(0, 25), 100.0, 2.0)
	if not bool(lateral.get("has_solution", false)) or (lateral.get("aim_point", Vector2.ZERO) as Vector2).y <= 0.0:
		failures += 1
	var head_on := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2(-25, 0), 100.0, 2.0)
	if not bool(head_on.get("has_solution", false)) or float(head_on.get("intercept_time", 2.0)) >= 1.0:
		failures += 1
	var unreachable := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2(200, 0), 100.0, 2.0)
	if bool(unreachable.get("has_solution", false)):
		failures += 1
	var no_positive := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2(10, 0), 10.0, 2.0)
	if bool(no_positive.get("has_solution", false)):
		failures += 1
	var linear := BallisticAimSolver.solve_intercept(s, Vector2(100, 0), Vector2(0, 100), 100.0, 2.0)
	if bool(linear.get("has_solution", false)):
		failures += 1
	var tiny_speed := BallisticAimSolver.solve_intercept(s, Vector2(10, 0), Vector2.ZERO, 0.000001, 2.0)
	if bool(tiny_speed.get("has_solution", false)):
		failures += 1
	var extreme := BallisticAimSolver.solve_intercept(Vector2(1000000, -1000000), Vector2(1000200, -999900), Vector2(10, -5), 850.0, 2.0)
	if not bool(extreme.get("valid", false)):
		failures += 1
	var nan_guard := BallisticAimSolver.solve_intercept(Vector2(NAN, 0), Vector2(1, 0), Vector2.ZERO, 100.0, 1.0)
	if bool(nan_guard.get("valid", false)):
		failures += 1
	return failures

func _test_hybrid_fire_control() -> int:
	var failures := 0
	var obs := AgentObservation.new()
	obs.energy_ratio = 1.0
	obs.health_ratio = 1.0
	obs.shoot_cooldown_ratio = 0.0
	var balance := GameBalance.default()
	var config := HybridAgentConfig.new()
	var decision := HighLevelDecision.new()
	decision.fire_mode = HighLevelDecision.FireMode.NORMAL
	var aim := _aim_solution(true, true, false, false, 0.05, 0.82, 0.4)
	var fc := FireControl.new()
	if not bool(fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	var wall_aim := _aim_solution(true, false, true, false, 0.05, 0.82, 0.4)
	if bool(fc.update(obs, decision, PlayerAction.new(), wall_aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	obs.energy_ratio = 0.13
	if bool(fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	obs.energy_ratio = 1.0
	decision.fire_mode = HighLevelDecision.FireMode.BURST
	fc.reset()
	for _i in range(config.burst_size):
		if not bool(fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1).get("fire_allowed", false)):
			failures += 1
	if bool(fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	decision.fire_mode = HighLevelDecision.FireMode.ALL_IN
	fc.reset()
	var no_kill := _aim_solution(true, true, false, false, 0.05, 0.82, 0.8)
	if bool(fc.update(obs, decision, PlayerAction.new(), no_kill, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	var friendly := _aim_solution(true, true, false, true, 0.05, 0.82, 0.2)
	decision.fire_mode = HighLevelDecision.FireMode.NORMAL
	if bool(fc.update(obs, decision, PlayerAction.new(), friendly, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	var no_target := _aim_solution(false, true, false, false, 0.05, 0.82, 0.2)
	if bool(fc.update(obs, decision, PlayerAction.new(), no_target, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	return failures

func _test_hybrid_movement_and_stuck() -> int:
	var failures := 0
	var obs := AgentObservation.new()
	obs.position = Vector2(100, 100)
	obs.boundary_distances = PackedFloat32Array([0.05, 0.95, 0.05, 0.95])
	var balance := GameBalance.default()
	var config := HybridAgentConfig.new()
	var stuck := StuckRecovery.new()
	var cover_info := {"has_cover_target": true, "nearest_wall_direction": Vector2.LEFT, "safe_space_direction": Vector2.RIGHT}
	for _i in range(12):
		var covered := stuck.apply(obs, Vector2.RIGHT, HighLevelDecision.MovementMode.SEEK_COVER, cover_info, {}, FakeHybridMap.new(), balance, config, 0.08)
		if bool(covered.get("stuck_recovery_active", false)):
			failures += 1
			break
	stuck.reset()
	cover_info["has_cover_target"] = false
	var recovered := false
	for _i in range(12):
		var result := stuck.apply(obs, Vector2.RIGHT, HighLevelDecision.MovementMode.CHASE, cover_info, {}, FakeHybridMap.new(), balance, config, 0.08)
		recovered = recovered or bool(result.get("stuck_recovery_active", false))
	if not recovered:
		failures += 1
	var mover := MovementExecutor.new()
	var decision := HighLevelDecision.new()
	decision.movement_mode = HighLevelDecision.MovementMode.EVADE_PROJECTILE
	var map := FakeHybridMap.new()
	map.block_positive_x = true
	var move := mover.execute(obs, decision, {}, PlayerAction.new(), {"recommended_direction": Vector2.RIGHT}, {"safe_space_direction": Vector2.LEFT, "nearest_wall_direction": Vector2.RIGHT}, map, balance, config, 0.1)
	var move_vec: Vector2 = move.get("move", Vector2.ZERO)
	if move_vec.x > 0.1:
		failures += 1
	var cover := CoverAnalyzer.new()
	if cover.candidate_is_safe(obs, Vector2.LEFT + Vector2.UP, FakeHybridMap.new(), balance, 120.0):
		failures += 1
	return failures

func _test_hybrid_protocol() -> int:
	var failures := 0
	var decision = HighLevelDecision.from_dict({
		"protocol": 2,
		"target_slot": 999,
		"movement_mode": 999,
		"fire_mode": 999,
		"skill_mode": 999,
		"confidence": INF,
	})
	if decision.protocol_version != HighLevelDecision.PROTOCOL_VERSION or decision.confidence != 0.0:
		failures += 1
	var masks := {
		"target_slot": [true, false, false, false, false, false, true],
		"movement_mode": [true, false, false, false, false, false, false, false, false, true, false, true],
		"fire_mode": [true, false, false, false, false, true],
		"skill_mode": [true, true, false, false, false, true],
	}
	if not decision.apply_masks(masks):
		if not bool(masks["target_slot"][decision.target_slot]):
			failures += 1
	if MatchConfig.AGENT_CONTROLLER_MODEL != "model":
		failures += 1
	if MatchConfig.AGENT_CONTROLLER_HYBRID != "hybrid":
		failures += 1
	return failures

func _test_debug_data() -> int:
	var log := DebugEventLog.new()
	for index in range(55):
		log.append_game_event("projectile_fired", {"owner_id": index % 4})
	log.append_game_event("player_damaged", {"victim_id": 1, "energy": 0.7, "reserve": 12.0})
	var lines := log.get_lines()
	var snapshot := DebugRuntimeSnapshot.build("dungeon", "PLAYING", 42.0, 4, 9, 60.0, 16.7)
	if lines.size() != 50 or "energy" in "\n".join(lines).to_lower() or "reserve" in "\n".join(lines).to_lower():
		return 1
	return 0 if snapshot == {"map_id": "dungeon", "state": "PLAYING", "remaining_seconds": 42.0, "player_count": 4, "projectile_count": 9, "fps": 60.0, "frame_ms": 16.7} else 1

func _aim_solution(valid_target: bool, los: bool, wall: bool, friendly: bool, aim_error: float, hit: float, target_health: float) -> Dictionary:
	return {
		"valid_target": valid_target,
		"has_solution": valid_target,
		"line_of_sight": los,
		"wall_blocked": wall,
		"within_lifetime": true,
		"friendly_fire_risk": friendly,
		"target_invulnerable": false,
		"aim_error": aim_error,
		"predicted_hit_probability": hit,
		"target_health_ratio": target_health,
	}

func _contains_private_fields(data: Variant) -> bool:
	if data is Dictionary:
		for key in data.keys():
			if _is_private_key(str(key)):
				return true
			if _contains_private_fields(data[key]):
				return true
	elif data is Array:
		for item in data:
			if _contains_private_fields(item):
				return true
	return false

func _is_private_key(key: String) -> bool:
	var normalized := key.to_lower().replace("-", "_")
	var compact := normalized.replace("_", "")
	var private_tokens := PackedStringArray(["ammo", "reserve", "magazine", "reloadremaining", "reload_remaining", "reloadtimer", "reload_timer", "weaponcooldown", "weapon_cooldown", "shootcooldown", "shoot_cooldown", "energy"])
	for token in private_tokens:
		var t := String(token).to_lower()
		if normalized == t or compact == t.replace("_", ""):
			return true
		if normalized.find(t) >= 0 or compact.find(t.replace("_", "")) >= 0:
			return true
	return false
