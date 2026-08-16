extends SceneTree
# Godot 集成测试入口，批量执行项目级运行时断言。

const BallisticAimSolver = preload("res://scripts/agents/ballistic_aim_solver.gd")
const FireControl = preload("res://scripts/agents/fire_control.gd")
const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/tactical_feature_builder.gd")
const TacticalTeacher = preload("res://scripts/agents/tactical_teacher.gd")
const StuckRecovery = preload("res://scripts/agents/stuck_recovery.gd")
const MovementExecutor = preload("res://scripts/agents/movement_executor.gd")
const CoverAnalyzer = preload("res://scripts/agents/cover_analyzer.gd")
const DebugEventLog = preload("res://scripts/debug/debug_event_log.gd")
const DebugRuntimeSnapshot = preload("res://scripts/debug/debug_runtime_snapshot.gd")
const TacticalTrainingProtocolTest = preload("res://tests/unit/tactical_training_protocol_test.gd")
const RewardCalculatorProfileTest = preload("res://tests/unit/reward_calculator_profile_test.gd")
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

class VantageHybridMap:
	extends Node

	func is_line_blocked(a: Vector2, _b: Vector2) -> bool:
		# A horizontal wall blocks the current firing lane, while either lateral
		# step exposes a legal lane to the visible target.
		return absf(a.y - 100.0) < 18.0

	func ray_distance(_origin: Vector2, _direction: Vector2, max_distance: float) -> float:
		return max_distance

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return true

class DistantBarrierHybridMap:
	extends Node

	func is_line_blocked(_a: Vector2, _b: Vector2) -> bool:
		return true

	func ray_distance(_origin: Vector2, direction: Vector2, max_distance: float) -> float:
		# The direct lane looks locally clear but reaches a distant wall before
		# it can open a firing lane. A longer route probe must choose a side.
		if max_distance > 200.0 and direction.x > 0.9:
			return max_distance * 0.35
		return max_distance

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return true

class NearVantageHybridMap:
	extends Node

	func is_line_blocked(a: Vector2, _b: Vector2) -> bool:
		# The direct lane is blocked, but a short lateral step opens it.
		return absf(a.y - 100.0) < 18.0

	func ray_distance(_origin: Vector2, direction: Vector2, max_distance: float) -> float:
		# A long lateral probe reaches a wall, while a short sidestep remains safe.
		# The eventual firing trajectory is horizontal and remains open once the
		# sidestep has been made.
		if direction.x > 0.5:
			return max_distance
		return max_distance if max_distance <= 120.0 else max_distance * 0.35

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return true

class LeadBlockedHybridMap:
	extends Node

	func is_line_blocked(a: Vector2, b: Vector2) -> bool:
		# The current target is unobstructed, but its predicted lead point crosses
		# a horizontal wall. A route above that wall restores the firing lane.
		return a.y < 170.0 and b.y >= 170.0

	func ray_distance(_origin: Vector2, _direction: Vector2, max_distance: float) -> float:
		return max_distance

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return true

class FlippingVantageHybridMap:
	extends Node

	var lane_round: int = -1
	var origin := Vector2(800, 600)

	func is_line_blocked(a: Vector2, _b: Vector2) -> bool:
		if a.is_equal_approx(origin):
			lane_round += 1
			return true
		# The safe visible side changes between decisions. A pressure route must
		# retain the first safe side briefly instead of immediately oscillating.
		return a.y <= origin.y if lane_round == 0 else a.y >= origin.y

	func ray_distance(_origin: Vector2, _direction: Vector2, max_distance: float) -> float:
		return max_distance

	func is_spawn_area_clear(_point: Vector2, _radius: float) -> bool:
		return true

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
	failures += _test_pressure_feature_visibility()
	failures += _test_pressure_cover_and_reserve_controls()
	failures += _test_hybrid_movement_and_stuck()
	failures += _test_hybrid_protocol()
	failures += _test_debug_data()
	failures += TacticalTrainingProtocolTest.new().run()
	failures += RewardCalculatorProfileTest.new().run()
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
	var replay_config := MatchConfig.new()
	replay_config.replay_output_dir = "training/data/replays/visibility_aware_pressure_bc"
	replay_config.training_spawn_policy = "engagement_window"
	var restored := MatchConfig.from_dict(replay_config.to_dict())
	if restored.replay_output_dir != replay_config.replay_output_dir:
		push_error("CONFIG TEST: replay collection directory must survive MatchConfig serialization")
		return 1
	if restored.training_spawn_policy != "engagement_window":
		push_error("CONFIG TEST: training engagement spawn policy must survive MatchConfig serialization")
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
	decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
	var held_fire := fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1)
	if bool(held_fire.get("fire_allowed", false)) or not bool(held_fire.get("actionable_window", false)):
		push_error("FIRE TEST: hold-fire must expose a viable-but-declined actionable window")
		failures += 1
	decision.fire_mode = HighLevelDecision.FireMode.NORMAL
	var wall_aim := _aim_solution(true, false, true, false, 0.05, 0.82, 0.4)
	if bool(fc.update(obs, decision, PlayerAction.new(), wall_aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		failures += 1
	var pressure_config := HybridAgentConfig.for_profile("legal_window_pressure")
	var marginal_aim := _aim_solution(true, true, false, false, 0.30, 0.48, 0.4)
	fc.reset()
	if bool(fc.update(obs, decision, PlayerAction.new(), marginal_aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		push_error("FIRE TEST: default profile must retain its stricter normal-fire gate")
		failures += 1
	fc.reset()
	if not bool(fc.update(obs, decision, PlayerAction.new(), marginal_aim, {}, balance, pressure_config, 0.1).get("fire_allowed", false)):
		push_error("FIRE TEST: legal-window profile should take a safe, marginal firing opportunity")
		failures += 1
	obs.energy_ratio = 0.10
	obs.dash_cooldown_ratio = 0.0
	obs.shield_cooldown_ratio = 1.0
	fc.reset()
	var dash_reserve := fc.update(obs, decision, PlayerAction.new(), aim, {}, balance, config, 0.1)
	if str(dash_reserve.get("reserve_basis", "")) != "dash_ready":
		push_error("FIRE TEST: a ready dash must explain a reserve-energy rejection")
		failures += 1
	obs.dash_cooldown_ratio = 1.0
	fc.reset()
	var threat_reserve := fc.update(obs, decision, PlayerAction.new(), aim, {"has_threat": true, "threat_level": 0.80}, balance, config, 0.1)
	if str(threat_reserve.get("reserve_basis", "")) != "projectile_threat":
		push_error("FIRE TEST: projectile pressure must explain a reserve-energy rejection")
		failures += 1
	obs.energy_ratio = 0.50
	obs.dash_cooldown_ratio = 0.0
	obs.shield_cooldown_ratio = 0.0
	obs.energy_ratio = 0.50
	decision.fire_mode = HighLevelDecision.FireMode.CONSERVATIVE
	var conservative_aim := _aim_solution(true, true, false, false, 0.10, 0.62, 0.4)
	fc.reset()
	if bool(fc.update(obs, decision, PlayerAction.new(), conservative_aim, {}, balance, config, 0.1).get("fire_allowed", false)):
		push_error("FIRE TEST: default conservative profile must preserve its energy reserve")
		failures += 1
	fc.reset()
	if not bool(fc.update(obs, decision, PlayerAction.new(), conservative_aim, {}, balance, pressure_config, 0.1).get("fire_allowed", false)):
		push_error("FIRE TEST: pressure profile should spend the configured engagement reserve")
		failures += 1
	obs.energy_ratio = 1.0
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

func _test_pressure_feature_visibility() -> int:
	var obs := AgentObservation.new()
	obs.position = Vector2(800.0, 600.0)
	obs.other_players = [{
		"relative_position": {"x": 0.20, "y": 0.0},
		"relative_velocity": {"x": 0.0, "y": 0.0},
		"aim_direction": {"x": -1.0, "y": 0.0},
		"health_ratio": 1.0,
		"is_teammate": false,
		"is_alive": true,
		"is_shielding": false,
		"is_dashing": false,
		"has_respawn_protection": false,
		"valid": true,
	}]
	var blocked_map := FakeHybridMap.new()
	blocked_map.line_blocked = true
	var pressure_config := HybridAgentConfig.for_profile("legal_window_pressure")
	var blocked_tactical := TacticalFeatureBuilder.new().build(
		obs,
		GameBalance.default(),
		pressure_config,
		null,
		blocked_map
	)
	var pressure_features: PackedFloat32Array = blocked_tactical.get("features", PackedFloat32Array())
	# Enemy features begin at 28; the target-level geometric visibility slot is
	# the former duplicate-valid field at offset 14.
	if pressure_features.size() != TacticalFeatureBuilder.FEATURE_DIM or pressure_features[42] != 0.0:
		push_error("FEATURE TEST: pressure policy must receive map-blocked target visibility")
		return 1
	var blocked_fire_mask: Array = blocked_tactical.get("action_masks", {}).get("fire_mode", [])
	for fire_mode in [HighLevelDecision.FireMode.CONSERVATIVE, HighLevelDecision.FireMode.NORMAL, HighLevelDecision.FireMode.BURST, HighLevelDecision.FireMode.ALL_IN, HighLevelDecision.FireMode.USE_SCRIPTED_FIRE_MODE]:
		if fire_mode < blocked_fire_mask.size() and bool(blocked_fire_mask[fire_mode]):
			push_error("FEATURE TEST: a map-blocked target must expose only HOLD_FIRE until pressure movement opens a lane")
			return 1
	var blocked_movement_mask: Array = blocked_tactical.get("action_masks", {}).get("movement_mode", [])
	for blind_spacing_mode in [HighLevelDecision.MovementMode.HOLD, HighLevelDecision.MovementMode.KEEP_RANGE, HighLevelDecision.MovementMode.STRAFE_CLOCKWISE, HighLevelDecision.MovementMode.STRAFE_COUNTERCLOCKWISE, HighLevelDecision.MovementMode.RETREAT]:
		if blind_spacing_mode < blocked_movement_mask.size() and bool(blocked_movement_mask[blind_spacing_mode]):
			push_error("FEATURE TEST: a map-blocked pressure target must not permit blind spacing movement")
			return 1
	if HighLevelDecision.MovementMode.CHASE >= blocked_movement_mask.size() or not bool(blocked_movement_mask[HighLevelDecision.MovementMode.CHASE]):
		push_error("FEATURE TEST: a map-blocked pressure target must retain CHASE to seek a firing lane")
		return 1
	var lead_obs := AgentObservation.new()
	lead_obs.position = Vector2(100.0, 100.0)
	lead_obs.other_players = [{
		"relative_position": {"x": 0.25, "y": 0.0},
		"relative_velocity": {"x": 0.0, "y": 0.40},
		"is_teammate": false,
		"is_alive": true,
		"valid": true,
	}]
	var lead_tactical := TacticalFeatureBuilder.new().build(lead_obs, GameBalance.default(), pressure_config, null, LeadBlockedHybridMap.new())
	var lead_movement_mask: Array = lead_tactical.get("action_masks", {}).get("movement_mode", [])
	if bool(lead_movement_mask[HighLevelDecision.MovementMode.KEEP_RANGE]) or not bool(lead_movement_mask[HighLevelDecision.MovementMode.CHASE]):
		push_error("FEATURE TEST: a predicted intercept blocked by geometry must force pressure movement to seek a ballistic lane")
		return 1
	var legacy_features: PackedFloat32Array = TacticalFeatureBuilder.new().build(
		obs,
		GameBalance.default(),
		HybridAgentConfig.new(),
		null,
		blocked_map
	).get("features", PackedFloat32Array())
	if legacy_features.size() != TacticalFeatureBuilder.FEATURE_DIM or legacy_features[42] != 1.0:
		push_error("FEATURE TEST: default deployed policy inputs must preserve legacy visibility semantics")
		return 1
	var blocked_label := TacticalTeacher.new().build_label(
		obs,
		TacticalFeatureBuilder.new().build(obs, GameBalance.default(), pressure_config, null, blocked_map),
		GameBalance.default()
	).get("decision", {}) as Dictionary
	if int(blocked_label.get("movement_mode", -1)) != HighLevelDecision.MovementMode.CHASE:
		push_error("FEATURE TEST: pressure teacher must seek a firing lane when the target is map-blocked")
		return 1
	if int(blocked_label.get("fire_mode", -1)) != HighLevelDecision.FireMode.HOLD_FIRE:
		push_error("FEATURE TEST: pressure teacher must not label firing through a map-blocked target")
		return 1
	var close_tactical := TacticalFeatureBuilder.new().build(obs, GameBalance.default(), pressure_config, null, FakeHybridMap.new())
	close_tactical["engagement_profile_id"] = "legal_window_pressure"
	obs.other_players[0]["relative_position"] = {"x": 0.08, "y": 0.0}
	var close_pressure_label := TacticalTeacher.new().build_label(obs, close_tactical, GameBalance.default()).get("decision", {}) as Dictionary
	if int(close_pressure_label.get("movement_mode", -1)) != HighLevelDecision.MovementMode.KEEP_RANGE:
		push_error("FEATURE TEST: pressure teacher must restore fighting range instead of learning passive RETREAT at close range")
		return 1
	return 0

func _test_pressure_cover_and_reserve_controls() -> int:
	var failures := 0
	var balance := GameBalance.default()
	var pressure_config := HybridAgentConfig.for_profile("legal_window_pressure")
	if pressure_config.cover_health_threshold <= 0.34 or pressure_config.cover_threat_threshold <= 0.0:
		push_error("PRESSURE TEST: existing pressure profile must expose cover thresholds")
		failures += 1
	var cover_obs := AgentObservation.new()
	cover_obs.position = Vector2(800.0, 600.0)
	cover_obs.health_ratio = 0.44
	cover_obs.energy_ratio = 0.70
	cover_obs.ray_results = PackedFloat32Array([0.20])
	cover_obs.other_players = [{
		"relative_position": {"x": 0.20, "y": 0.0},
		"relative_velocity": {"x": 0.0, "y": 0.0},
		"aim_direction": {"x": -1.0, "y": 0.0},
		"health_ratio": 1.0,
		"is_teammate": false,
		"is_alive": true,
		"is_shielding": false,
		"is_dashing": false,
		"has_respawn_protection": false,
		"valid": true,
	}]
	var cover_data := TacticalFeatureBuilder.new().build(cover_obs, balance, pressure_config, null, FakeHybridMap.new())
	cover_data["engagement_profile_id"] = "legal_window_pressure"
	cover_data["threat_info"] = {"threat_level": 0.50, "has_threat": true}
	var teacher := TacticalTeacher.new()
	var cover_label := teacher.build_label(cover_obs, cover_data, balance, {}, pressure_config).get("decision", {}) as Dictionary
	if int(cover_label.get("movement_mode", -1)) != HighLevelDecision.MovementMode.SEEK_COVER:
		push_error("PRESSURE TEST: medium threat plus available cover must teach cover use")
		failures += 1
	cover_data["threat_info"] = {"threat_level": 0.80, "has_threat": true}
	var emergency_masks: Dictionary = (cover_data.get("action_masks", {}) as Dictionary).duplicate(true)
	var emergency_movement_mask: Array = emergency_masks.get("movement_mode", [])
	if HighLevelDecision.MovementMode.EVADE_PROJECTILE < emergency_movement_mask.size():
		emergency_movement_mask[HighLevelDecision.MovementMode.EVADE_PROJECTILE] = true
	emergency_masks["movement_mode"] = emergency_movement_mask
	cover_data["action_masks"] = emergency_masks
	var emergency_label := teacher.build_label(cover_obs, cover_data, balance, {}, pressure_config).get("decision", {}) as Dictionary
	if int(emergency_label.get("movement_mode", -1)) != HighLevelDecision.MovementMode.EVADE_PROJECTILE:
		push_error("PRESSURE TEST: high threat must override cover with projectile evasion")
		failures += 1
	var fire_obs := AgentObservation.new()
	fire_obs.energy_ratio = 0.36
	fire_obs.health_ratio = 1.0
	fire_obs.shoot_cooldown_ratio = 0.0
	fire_obs.dash_cooldown_ratio = 0.0
	fire_obs.shield_cooldown_ratio = 0.0
	var decision := HighLevelDecision.new()
	decision.fire_mode = HighLevelDecision.FireMode.NORMAL
	var aim := _aim_solution(true, true, false, false, 0.05, 0.82, 0.40)
	var threat := {"has_threat": true, "threat_level": 0.30}
	var fire_control := FireControl.new()
	if bool(fire_control.update(fire_obs, decision, PlayerAction.new(), aim, threat, balance, HybridAgentConfig.new(), 0.1).get("fire_allowed", false)):
		push_error("PRESSURE TEST: default profile must preserve its defensive reserve")
		failures += 1
	fire_control.reset()
	if not bool(fire_control.update(fire_obs, decision, PlayerAction.new(), aim, threat, balance, pressure_config, 0.1).get("fire_allowed", false)):
		push_error("PRESSURE TEST: existing pressure profile must use a legal non-emergency firing window")
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
	decision.movement_mode = HighLevelDecision.MovementMode.CHASE
	var pressure_target := {"valid": true, "relative_position": {"x": 0.4, "y": 0.0}}
	var vantage_move := MovementExecutor.new().execute(
		obs,
		decision,
		pressure_target,
		PlayerAction.new(),
		{},
		{"safe_space_direction": Vector2.RIGHT, "nearest_wall_direction": Vector2.ZERO},
		VantageHybridMap.new(),
		balance,
		HybridAgentConfig.for_profile("legal_window_pressure"),
		0.1
	)
	var vantage_vector: Vector2 = vantage_move.get("move", Vector2.ZERO)
	if absf(vantage_vector.y) < 0.1:
		push_error("MOVEMENT TEST: pressure chase must sidestep toward a visible firing lane")
		failures += 1
	var distant_barrier_move := MovementExecutor.new().execute(
		obs,
		decision,
		pressure_target,
		PlayerAction.new(),
		{},
		{"safe_space_direction": Vector2.RIGHT, "nearest_wall_direction": Vector2.ZERO},
		DistantBarrierHybridMap.new(),
		balance,
		HybridAgentConfig.for_profile("legal_window_pressure"),
		0.1
	)
	var distant_barrier_vector: Vector2 = distant_barrier_move.get("move", Vector2.ZERO)
	if absf(distant_barrier_vector.y) < 0.1:
		push_error("MOVEMENT TEST: pressure chase must route around a distant blocked firing lane")
		failures += 1
	var near_vantage_move := MovementExecutor.new().execute(
		obs,
		decision,
		pressure_target,
		PlayerAction.new(),
		{},
		{"safe_space_direction": Vector2.RIGHT, "nearest_wall_direction": Vector2.ZERO},
		NearVantageHybridMap.new(),
		balance,
		HybridAgentConfig.for_profile("legal_window_pressure"),
		0.1
	)
	var near_vantage_vector: Vector2 = near_vantage_move.get("move", Vector2.ZERO)
	if absf(near_vantage_vector.y) < 0.1:
		push_error("MOVEMENT TEST: pressure chase must use a short safe sidestep when the long probe is blocked")
		failures += 1
	var lead_target := {"valid": true, "relative_position": {"x": 0.25, "y": 0.0}, "relative_velocity": {"x": 0.0, "y": 0.40}}
	var lead_vantage_move := MovementExecutor.new().execute(
		obs,
		decision,
		lead_target,
		PlayerAction.new(),
		{},
		{"safe_space_direction": Vector2.RIGHT, "nearest_wall_direction": Vector2.ZERO},
		LeadBlockedHybridMap.new(),
		balance,
		HybridAgentConfig.for_profile("legal_window_pressure"),
		0.1
	)
	var lead_vantage_vector: Vector2 = lead_vantage_move.get("move", Vector2.ZERO)
	if absf(lead_vantage_vector.y) < 0.1:
		push_error("MOVEMENT TEST: pressure chase must sidestep when only the predicted intercept lane is blocked")
		failures += 1
	var route_obs := AgentObservation.new()
	route_obs.position = Vector2(800, 600)
	var route_mover := MovementExecutor.new()
	var flipping_map := FlippingVantageHybridMap.new()
	var first_route := route_mover.execute(route_obs, decision, pressure_target, PlayerAction.new(), {}, {"safe_space_direction": Vector2.RIGHT}, flipping_map, balance, HybridAgentConfig.for_profile("legal_window_pressure"), 0.1)
	var second_route := route_mover.execute(route_obs, decision, pressure_target, PlayerAction.new(), {}, {"safe_space_direction": Vector2.RIGHT}, flipping_map, balance, HybridAgentConfig.for_profile("legal_window_pressure"), 0.1)
	var first_route_vector: Vector2 = first_route.get("move", Vector2.ZERO)
	var second_route_vector: Vector2 = second_route.get("move", Vector2.ZERO)
	if first_route_vector.y * second_route_vector.y <= 0.0:
		push_error("MOVEMENT TEST: pressure chase must retain its safe firing-vantage side")
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
