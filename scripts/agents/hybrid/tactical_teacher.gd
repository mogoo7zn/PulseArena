extends RefCounted
# Rule-based high-level labeler for Hybrid Tactical v2 replay collection.
class_name TacticalTeacher

const HighLevelDecision = preload("res://scripts/agents/hybrid/tactical_decision.gd")

const LABEL_VERSION := 1
const EPS := 0.00001

func build_label(obs: AgentObservation, tactical_data: Dictionary, balance: GameBalance, diagnostics: Dictionary = {}) -> Dictionary:
	var decision := HighLevelDecision.new()
	var masks: Dictionary = tactical_data.get("action_masks", {})
	var threat_info: Dictionary = tactical_data.get("threat_info", {})
	var label_weight := 1.0
	var confidence := 0.78
	var source := "teacher_rule_v1"
	var reason := ""
	if obs == null or not obs.is_alive:
		decision.target_slot = HighLevelDecision.TargetSlot.NONE
		decision.movement_mode = HighLevelDecision.MovementMode.HOLD
		decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
		decision.skill_mode = HighLevelDecision.SkillMode.NONE
		label_weight = 0.20
		confidence = 0.35
		source = "teacher_inactive"
		reason = "missing_or_dead"
		return _finish(decision, masks, label_weight, confidence, source, reason)
	var target_info := _target_info(obs)
	var has_enemy := bool(target_info.get("has_enemy", false))
	var threat_level := clampf(float(threat_info.get("threat_level", 0.0)), 0.0, 1.0)
	var high_threat := threat_level >= 0.72
	var emergency := threat_level >= 0.88
	if not has_enemy:
		decision.target_slot = HighLevelDecision.TargetSlot.NONE
		decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
		decision.movement_mode = HighLevelDecision.MovementMode.SEEK_BEST_PICKUP if _has_pickup(obs) else HighLevelDecision.MovementMode.MOVE_TO_CENTER
		decision.skill_mode = HighLevelDecision.SkillMode.AUTO_DEFENSE if high_threat else HighLevelDecision.SkillMode.NONE
		reason = "objective_without_enemy"
	else:
		_assign_target(decision, target_info, balance)
		_assign_movement(decision, obs, target_info, high_threat, emergency)
		_assign_fire(decision, obs, target_info, threat_info, balance, high_threat, emergency)
		_assign_skill(decision, obs, target_info, threat_info, high_threat, emergency)
		reason = "enemy_tactical_rule"
	if bool(diagnostics.get("safety_override", false)):
		label_weight *= 0.72
		confidence = minf(confidence, 0.62)
		reason += ":safety_override_seen"
	if bool(diagnostics.get("script_fallback", false)):
		label_weight *= 0.65
		confidence = minf(confidence, 0.58)
		reason += ":fallback_seen"
	return _finish(decision, masks, label_weight, confidence, source, reason)

func _assign_target(decision: HighLevelDecision, target_info: Dictionary, balance: GameBalance) -> void:
	var lowest_health := float(target_info.get("lowest_health", 1.0))
	var damage_ratio := _damage_ratio(balance)
	if lowest_health <= damage_ratio + 0.12:
		decision.target_slot = HighLevelDecision.TargetSlot.LOWEST_HEALTH_ENEMY
	else:
		decision.target_slot = HighLevelDecision.TargetSlot.BEST_VISIBLE_ENEMY

func _assign_movement(decision: HighLevelDecision, obs: AgentObservation, target_info: Dictionary, high_threat: bool, emergency: bool) -> void:
	if high_threat:
		decision.movement_mode = HighLevelDecision.MovementMode.EVADE_PROJECTILE
		return
	var distance := float(target_info.get("closest_distance", 1.0))
	if obs.health_ratio < 0.34:
		decision.movement_mode = HighLevelDecision.MovementMode.SEEK_COVER if _near_wall_or_cover(obs) else HighLevelDecision.MovementMode.RETREAT
	elif obs.energy_ratio < 0.18:
		decision.movement_mode = HighLevelDecision.MovementMode.SEEK_BEST_PICKUP if _has_pickup(obs) else HighLevelDecision.MovementMode.SEEK_COVER
	elif distance > 0.34:
		decision.movement_mode = HighLevelDecision.MovementMode.CHASE
	elif distance < 0.13:
		decision.movement_mode = HighLevelDecision.MovementMode.RETREAT
	elif emergency:
		decision.movement_mode = HighLevelDecision.MovementMode.EVADE_PROJECTILE
	else:
		decision.movement_mode = HighLevelDecision.MovementMode.KEEP_RANGE

func _assign_fire(decision: HighLevelDecision, obs: AgentObservation, target_info: Dictionary, threat_info: Dictionary, balance: GameBalance, high_threat: bool, emergency: bool) -> void:
	var distance := float(target_info.get("closest_distance", 1.0))
	var lowest_health := float(target_info.get("lowest_health", 1.0))
	var kill_window := lowest_health <= _damage_ratio(balance) + 0.08
	if emergency or bool(threat_info.get("defense_priority", false)):
		decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
	elif obs.energy_ratio < 0.12:
		decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
	elif high_threat:
		decision.fire_mode = HighLevelDecision.FireMode.CONSERVATIVE
	elif kill_window and obs.energy_ratio >= 0.28:
		decision.fire_mode = HighLevelDecision.FireMode.ALL_IN
	elif distance < 0.24 and obs.energy_ratio >= 0.35:
		decision.fire_mode = HighLevelDecision.FireMode.BURST
	elif obs.energy_ratio < 0.30 or distance > 0.42:
		decision.fire_mode = HighLevelDecision.FireMode.CONSERVATIVE
	else:
		decision.fire_mode = HighLevelDecision.FireMode.NORMAL

func _assign_skill(decision: HighLevelDecision, obs: AgentObservation, target_info: Dictionary, _threat_info: Dictionary, high_threat: bool, emergency: bool) -> void:
	var distance := float(target_info.get("closest_distance", 1.0))
	var dash_ready := obs.dash_cooldown_ratio <= 0.01 and obs.energy_ratio >= 0.30
	var shield_ready := obs.shield_cooldown_ratio <= 0.01 and obs.energy_ratio >= 0.25
	if emergency and shield_ready and obs.health_ratio < 0.62:
		decision.skill_mode = HighLevelDecision.SkillMode.SHIELD
	elif high_threat and dash_ready:
		decision.skill_mode = HighLevelDecision.SkillMode.DASH_EVADE
	elif obs.health_ratio < 0.38 and shield_ready:
		decision.skill_mode = HighLevelDecision.SkillMode.SHIELD
	elif distance > 0.38 and obs.energy_ratio >= 0.50 and dash_ready:
		decision.skill_mode = HighLevelDecision.SkillMode.DASH_ENGAGE
	else:
		decision.skill_mode = HighLevelDecision.SkillMode.AUTO_DEFENSE

func _finish(decision: HighLevelDecision, masks: Dictionary, label_weight: float, confidence: float, source: String, reason: String) -> Dictionary:
	var legal := decision.apply_masks(masks)
	if not legal:
		label_weight *= 0.55
		confidence = minf(confidence, 0.52)
		reason += ":mask_corrected"
	decision.confidence = clampf(confidence, 0.0, 1.0)
	return {
		"decision": decision.to_dict(),
		"label_weight": clampf(label_weight, 0.05, 1.0),
		"label_confidence": decision.confidence,
		"label_source": source,
		"label_reason": reason,
		"teacher_label_version": LABEL_VERSION,
	}

func _target_info(obs: AgentObservation) -> Dictionary:
	var closest_slot := -1
	var closest_distance := INF
	var lowest_slot := -1
	var lowest_health := INF
	for i in range(mini(AgentObservation.MAX_OTHER_PLAYERS, obs.other_players.size())):
		var candidate: Dictionary = obs.other_players[i]
		if not _is_valid_enemy(candidate):
			continue
		var rel := AgentObservation.dict_to_vec(candidate.get("relative_position", {}))
		var distance := rel.length()
		if distance < closest_distance:
			closest_distance = distance
			closest_slot = i
		var health := float(candidate.get("health_ratio", 1.0))
		if health < lowest_health:
			lowest_health = health
			lowest_slot = i
	return {
		"has_enemy": closest_slot >= 0,
		"closest_slot": closest_slot,
		"closest_distance": closest_distance if closest_slot >= 0 else 1.0,
		"lowest_slot": lowest_slot,
		"lowest_health": lowest_health if lowest_slot >= 0 else 1.0,
	}

func _is_valid_enemy(candidate: Dictionary) -> bool:
	return bool(candidate.get("valid", false)) and bool(candidate.get("is_alive", false)) and not bool(candidate.get("is_teammate", false))

func _has_pickup(obs: AgentObservation) -> bool:
	return obs.nearest_resource_relative_position.length_squared() > 0.0001

func _near_wall_or_cover(obs: AgentObservation) -> bool:
	for value in obs.ray_results:
		if float(value) < 0.35:
			return true
	for value in obs.boundary_distances:
		if float(value) < 0.18:
			return true
	return false

func _damage_ratio(balance: GameBalance) -> float:
	if balance == null:
		return 0.20
	return balance.projectile_damage / maxf(balance.max_health, 1.0)
