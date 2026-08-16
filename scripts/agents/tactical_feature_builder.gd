extends RefCounted
# Builds normalized tactical features and masks from public observations and,
# for opt-in training profiles, public map collision geometry.
class_name TacticalFeatureBuilder

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const ProjectileThreatAnalyzer = preload("res://scripts/agents/projectile_threat_analyzer.gd")
const BallisticAimSolver = preload("res://scripts/agents/ballistic_aim_solver.gd")

const FEATURE_SCHEMA_VERSION := 2
const FEATURE_DIM := 142

var threat_analyzer := ProjectileThreatAnalyzer.new()

func build(obs: AgentObservation, balance: GameBalance, config: HybridAgentConfig, current_decision: HighLevelDecision = null, arena_map: Node = null) -> Dictionary:
	var features := PackedFloat32Array()
	var threat_info := threat_analyzer.analyze(obs, balance, config)
	var masks := build_action_masks(obs, balance, config, threat_info, arena_map)
	_append_self_features(features, obs, balance, current_decision)
	_append_enemy_features(features, obs, balance, config, arena_map)
	_append_threat_features(features, threat_info)
	_append_environment_features(features, obs, balance)
	while features.size() < FEATURE_DIM:
		features.append(0.0)
	if features.size() > FEATURE_DIM:
		features.resize(FEATURE_DIM)
	return {
		"schema_version": FEATURE_SCHEMA_VERSION,
		"features": features,
		"action_masks": masks,
		"threat_info": threat_info,
		"feature_names": feature_names(),
	}

func build_action_masks(obs: AgentObservation, balance: GameBalance, config: HybridAgentConfig, threat_info: Dictionary = {}, arena_map: Node = null) -> Dictionary:
	var enemy_valid := _enemy_valid_slots(obs)
	var any_enemy := not enemy_valid.is_empty()
	var has_pickup := obs != null and obs.nearest_resource_relative_position.length_squared() > 0.0001
	var high_threat := false
	if obs != null:
		var threat := threat_info if not threat_info.is_empty() else threat_analyzer.analyze(obs, balance, config)
		high_threat = float(threat.get("threat_level", 0.0)) >= (config.high_threat_threshold if config != null else 0.72)
	var target_mask := []
	for _i in range(HighLevelDecision.TARGET_SLOT_COUNT):
		target_mask.append(false)
	target_mask[HighLevelDecision.TargetSlot.NONE] = true
	target_mask[HighLevelDecision.TargetSlot.SCRIPTED_TARGET] = true
	for slot in enemy_valid:
		var target_slot := HighLevelDecision.TargetSlot.ENEMY_0 + int(slot)
		if target_slot >= HighLevelDecision.TargetSlot.ENEMY_0 and target_slot <= HighLevelDecision.TargetSlot.ENEMY_2:
			target_mask[target_slot] = true
	target_mask[HighLevelDecision.TargetSlot.BEST_VISIBLE_ENEMY] = any_enemy
	target_mask[HighLevelDecision.TargetSlot.LOWEST_HEALTH_ENEMY] = any_enemy
	var movement_mask := []
	for i in range(HighLevelDecision.MOVEMENT_MODE_COUNT):
		movement_mask.append(true)
	movement_mask[HighLevelDecision.MovementMode.SEEK_BEST_PICKUP] = has_pickup
	movement_mask[HighLevelDecision.MovementMode.EVADE_PROJECTILE] = high_threat
	var can_open_fire := any_enemy
	if config != null and config.engagement_profile_id == "legal_window_pressure":
		can_open_fire = _has_reachable_visible_enemy(obs, balance, config, arena_map)
		# When an observed enemy is behind geometry, spacing modes preserve the
		# blocked lane instead of creating a new angle.  Keep only actions that
		# can seek a lane or answer an independent safety/resource need.  CHASE is
		# deliberately left legal so an illegal policy choice is corrected to it.
		if any_enemy and not can_open_fire:
			for blind_spacing_mode in [
				HighLevelDecision.MovementMode.HOLD,
				HighLevelDecision.MovementMode.KEEP_RANGE,
				HighLevelDecision.MovementMode.STRAFE_CLOCKWISE,
				HighLevelDecision.MovementMode.STRAFE_COUNTERCLOCKWISE,
				HighLevelDecision.MovementMode.RETREAT,
			]:
				movement_mask[blind_spacing_mode] = false
	var fire_mask := []
	for i in range(HighLevelDecision.FIRE_MODE_COUNT):
		fire_mask.append(can_open_fire)
	fire_mask[HighLevelDecision.FireMode.HOLD_FIRE] = true
	fire_mask[HighLevelDecision.FireMode.USE_SCRIPTED_FIRE_MODE] = can_open_fire
	if obs == null or obs.energy_ratio <= 0.03:
		fire_mask[HighLevelDecision.FireMode.BURST] = false
		fire_mask[HighLevelDecision.FireMode.ALL_IN] = false
	var skill_mask := []
	for i in range(HighLevelDecision.SKILL_MODE_COUNT):
		skill_mask.append(true)
	skill_mask[HighLevelDecision.SkillMode.DASH_EVADE] = obs != null and obs.dash_cooldown_ratio <= 0.01 and obs.energy_ratio >= 0.30 and high_threat
	skill_mask[HighLevelDecision.SkillMode.DASH_ENGAGE] = obs != null and obs.dash_cooldown_ratio <= 0.01 and obs.energy_ratio >= 0.45 and any_enemy
	skill_mask[HighLevelDecision.SkillMode.SHIELD] = obs != null and obs.shield_cooldown_ratio <= 0.01 and obs.energy_ratio >= 0.25
	skill_mask[HighLevelDecision.SkillMode.AUTO_DEFENSE] = true
	skill_mask[HighLevelDecision.SkillMode.NONE] = true
	skill_mask[HighLevelDecision.SkillMode.USE_SCRIPTED_SKILL] = true
	return {
		"target_slot": target_mask,
		"movement_mode": movement_mask,
		"fire_mode": fire_mask,
		"skill_mode": skill_mask,
	}

func _has_reachable_visible_enemy(obs: AgentObservation, balance: GameBalance, config: HybridAgentConfig, arena_map: Node) -> bool:
	if obs == null or balance == null:
		return false
	for candidate in obs.other_players:
		if not _is_valid_enemy(candidate):
			continue
		if config.target_visibility_features_enabled:
			if arena_map == null or not arena_map.has_method("is_line_blocked"):
				continue
			var lane := BallisticAimSolver.evaluate_observation_lane(obs, candidate, balance, arena_map, config)
			if not BallisticAimSolver.has_usable_lane(lane):
				continue
		return true
	return false

func select_target(obs: AgentObservation, decision: HighLevelDecision, scripted_target: Dictionary = {}) -> Dictionary:
	if obs == null or decision == null:
		return {}
	match decision.target_slot:
		HighLevelDecision.TargetSlot.NONE:
			return {}
		HighLevelDecision.TargetSlot.ENEMY_0, HighLevelDecision.TargetSlot.ENEMY_1, HighLevelDecision.TargetSlot.ENEMY_2:
			var index := decision.target_slot - HighLevelDecision.TargetSlot.ENEMY_0
			if index >= 0 and index < obs.other_players.size():
				var candidate: Dictionary = obs.other_players[index]
				return candidate if _is_valid_enemy(candidate) else {}
			return {}
		HighLevelDecision.TargetSlot.LOWEST_HEALTH_ENEMY:
			return _lowest_health_enemy(obs)
		HighLevelDecision.TargetSlot.SCRIPTED_TARGET:
			return scripted_target if not scripted_target.is_empty() else _best_visible_enemy(obs)
		_:
			return _best_visible_enemy(obs)

func _append_self_features(out: PackedFloat32Array, obs: AgentObservation, balance: GameBalance, current_decision: HighLevelDecision) -> void:
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var max_speed := balance.move_speed if balance != null else 260.0
	if obs == null:
		for _i in range(28):
			out.append(0.0)
		return
	out.append_array(PackedFloat32Array([
		clampf(obs.position.x / map_size.x, 0.0, 1.0),
		clampf(obs.position.y / map_size.y, 0.0, 1.0),
		clampf(obs.velocity.x / maxf(max_speed, 1.0), -1.0, 1.0),
		clampf(obs.velocity.y / maxf(max_speed, 1.0), -1.0, 1.0),
		obs.aim_direction.x,
		obs.aim_direction.y,
		clampf(obs.health_ratio, 0.0, 1.0),
		clampf(obs.energy_ratio, 0.0, 1.0),
		clampf(obs.shoot_cooldown_ratio, 0.0, 1.0),
		clampf(obs.dash_cooldown_ratio, 0.0, 1.0),
		clampf(obs.shield_cooldown_ratio, 0.0, 1.0),
		1.0 if obs.is_alive else 0.0,
		1.0 if obs.is_shielding else 0.0,
		1.0 if obs.has_respawn_protection else 0.0,
		clampf(obs.remaining_time_ratio, 0.0, 1.0),
		float(obs.map_id) / 3.0,
		float(obs.game_mode_id),
	]))
	var decision := current_decision if current_decision != null else HighLevelDecision.new()
	out.append(float(decision.target_slot) / float(maxi(HighLevelDecision.TARGET_SLOT_COUNT - 1, 1)))
	out.append(float(decision.movement_mode) / float(maxi(HighLevelDecision.MOVEMENT_MODE_COUNT - 1, 1)))
	out.append(float(decision.fire_mode) / float(maxi(HighLevelDecision.FIRE_MODE_COUNT - 1, 1)))
	out.append(float(decision.skill_mode) / float(maxi(HighLevelDecision.SKILL_MODE_COUNT - 1, 1)))
	for value in obs.boundary_distances:
		out.append(clampf(value, 0.0, 1.0))
	var corner := 0.0
	for value in obs.boundary_distances:
		if value < 0.08:
			corner += 0.25
	out.append(clampf(corner, 0.0, 1.0))
	out.append(_nearest_wall_ratio(obs))
	out.append(_low_ray_ratio(obs))

func _append_enemy_features(out: PackedFloat32Array, obs: AgentObservation, balance: GameBalance, config: HybridAgentConfig, arena_map: Node) -> void:
	if obs == null:
		for _i in range(AgentObservation.MAX_OTHER_PLAYERS * 20):
			out.append(0.0)
		return
	for i in range(AgentObservation.MAX_OTHER_PLAYERS):
		var p: Dictionary = obs.other_players[i] if i < obs.other_players.size() else AgentObservation.empty_player()
		var rel := AgentObservation.dict_to_vec(p.get("relative_position", {}))
		var vel := AgentObservation.dict_to_vec(p.get("relative_velocity", {}))
		var aim := AgentObservation.dict_to_vec(p.get("aim_direction", {"x": 1.0, "y": 0.0}))
		var distance := rel.length()
		var los := _target_visibility(obs, p, balance, config, arena_map)
		var intercept_time_norm := clampf(distance * (balance.map_size.length() if balance != null else 2480.0) / maxf((balance.projectile_speed if balance != null else 850.0) * (balance.projectile_lifetime if balance != null else 1.4), 1.0), 0.0, 1.0)
		var health := clampf(float(p.get("health_ratio", 0.0)), 0.0, 1.0)
		var kill_chance := 1.0 - clampf(health / maxf((balance.projectile_damage if balance != null else 20.0) / maxf((balance.max_health if balance != null else 100.0), 1.0) + 0.001, 1.0), 0.0, 1.0)
		out.append_array(PackedFloat32Array([
			rel.x,
			rel.y,
			vel.x,
			vel.y,
			clampf(distance, 0.0, 1.0),
			aim.x,
			aim.y,
			health,
			1.0 if bool(p.get("is_teammate", false)) else 0.0,
			1.0 if bool(p.get("is_alive", false)) else 0.0,
			1.0 if bool(p.get("is_shielding", false)) else 0.0,
			1.0 if bool(p.get("is_dashing", false)) else 0.0,
			1.0 if bool(p.get("has_respawn_protection", false)) else 0.0,
			1.0 if bool(p.get("valid", false)) else 0.0,
			los,
			intercept_time_norm,
			kill_chance,
			0.0,
			1.0 if bool(p.get("valid", false)) else 0.0,
			float(i) / 3.0,
		]))

func _target_visibility(obs: AgentObservation, player_data: Dictionary, balance: GameBalance, config: HybridAgentConfig, arena_map: Node) -> float:
	var valid_enemy := bool(player_data.get("valid", false)) and not bool(player_data.get("is_teammate", false))
	if not valid_enemy:
		return 0.0
	# Default controllers retain the exact old duplicate-valid input at this
	# index, so already deployed checkpoints do not silently change behavior.
	if config == null or not config.target_visibility_features_enabled:
		return 1.0
	# Pressure training always supplies the arena map.  Missing geometry is not
	# treated as a legal lane, preventing a false-positive firing cue.
	if obs == null or balance == null or arena_map == null or not arena_map.has_method("is_line_blocked"):
		return 0.0
	var target_position := obs.position + AgentObservation.dict_to_vec(player_data.get("relative_position", {})) * balance.map_size
	return 0.0 if bool(arena_map.is_line_blocked(obs.position, target_position)) else 1.0

func _append_threat_features(out: PackedFloat32Array, threat_info: Dictionary) -> void:
	var recommended: Vector2 = threat_info.get("recommended_direction", Vector2.ZERO)
	out.append_array(PackedFloat32Array([
		clampf(float(threat_info.get("threat_level", 0.0)), 0.0, 1.0),
		clampf(float(threat_info.get("time_to_hit", 999.0)) / 1.4, 0.0, 1.0),
		clampf(float(threat_info.get("closest_distance", 999.0)) / 300.0, 0.0, 1.0),
		recommended.x,
		recommended.y,
		clampf(float(threat_info.get("bullet_density", 0.0)), 0.0, 1.0),
		1.0 if bool(threat_info.get("has_threat", false)) else 0.0,
		1.0 if bool(threat_info.get("defense_priority", false)) else 0.0,
	]))
	var risks: Dictionary = threat_info.get("risk_by_direction", {})
	var risk_values := risks.values()
	for i in range(8):
		out.append(clampf(float(risk_values[i]) if i < risk_values.size() else 0.0, 0.0, 1.0))

func _append_environment_features(out: PackedFloat32Array, obs: AgentObservation, balance: GameBalance) -> void:
	if obs == null:
		for _i in range(38):
			out.append(0.0)
		return
	for value in obs.ray_results:
		out.append(clampf(value, 0.0, 1.0))
	out.append(obs.nearest_resource_relative_position.x)
	out.append(obs.nearest_resource_relative_position.y)
	out.append(clampf(obs.nearest_resource_relative_position.length(), 0.0, 1.0))
	out.append(1.0 if obs.nearest_resource_relative_position.length_squared() > 0.0001 else 0.0)
	out.append(0.0)
	out.append(0.0)
	out.append(0.0)
	out.append(0.0)
	out.append(float(obs.map_id) / 3.0)
	out.append(float(obs.game_mode_id))
	out.append(_nearest_wall_ratio(obs))
	out.append(_low_ray_ratio(obs))
	out.append(_open_space_score(obs))
	out.append(0.0)
	out.append(0.0)
	out.append(0.0)
	out.append(0.0)
	out.append(0.0)

func feature_names() -> PackedStringArray:
	var names := PackedStringArray()
	for i in range(FEATURE_DIM):
		names.append("hybrid_feature_%03d" % i)
	return names

func _enemy_valid_slots(obs: AgentObservation) -> Array[int]:
	var out: Array[int] = []
	if obs == null:
		return out
	for i in range(mini(AgentObservation.MAX_OTHER_PLAYERS, obs.other_players.size())):
		if _is_valid_enemy(obs.other_players[i]):
			out.append(i)
	return out

func _best_visible_enemy(obs: AgentObservation) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for candidate in obs.other_players:
		if not _is_valid_enemy(candidate):
			continue
		var rel := AgentObservation.dict_to_vec(candidate.get("relative_position", {}))
		var score := rel.length()
		if score < best_score:
			best_score = score
			best = candidate
	return best

func _lowest_health_enemy(obs: AgentObservation) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for candidate in obs.other_players:
		if not _is_valid_enemy(candidate):
			continue
		var score := float(candidate.get("health_ratio", 1.0))
		if score < best_score:
			best_score = score
			best = candidate
	return best

func _is_valid_enemy(candidate: Dictionary) -> bool:
	return bool(candidate.get("valid", false)) and bool(candidate.get("is_alive", false)) and not bool(candidate.get("is_teammate", false))

func _nearest_wall_ratio(obs: AgentObservation) -> float:
	var best := 1.0
	for value in obs.ray_results:
		best = minf(best, clampf(value, 0.0, 1.0))
	for value in obs.boundary_distances:
		best = minf(best, clampf(value, 0.0, 1.0))
	return best

func _low_ray_ratio(obs: AgentObservation) -> float:
	var count := 0
	for value in obs.ray_results:
		if value < 0.18:
			count += 1
	return float(count) / float(maxi(obs.ray_results.size(), 1))

func _open_space_score(obs: AgentObservation) -> float:
	var total := 0.0
	for value in obs.ray_results:
		total += clampf(value, 0.0, 1.0)
	return total / float(maxi(obs.ray_results.size(), 1))
