extends RefCounted
# 奖励计算器，根据伤害、击杀、生存和战术事件生成训练奖励。
class_name RewardCalculator

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")

var config: MatchConfig
var reward_config: RewardConfig
var totals: Dictionary = {}
var components: Dictionary = {}
var authorized_projectile_owners: Dictionary = {}
var tactical_event_counts: Dictionary = {}
var prior_actionable_windows: Dictionary = {}
var tactical_decision_records: Dictionary = {}
var resource_event_counts: Dictionary = {}
var map_event_counts: Dictionary = {}
var collected_pickup_ids: Dictionary = {}

func configure(match_config: MatchConfig, rewards: RewardConfig) -> void:
	config = match_config
	reward_config = rewards
	totals.clear()
	components.clear()
	authorized_projectile_owners.clear()
	tactical_event_counts.clear()
	prior_actionable_windows.clear()
	tactical_decision_records.clear()
	resource_event_counts.clear()
	map_event_counts.clear()
	collected_pickup_ids.clear()

func register_player(player_id: int) -> void:
	totals[player_id] = 0.0
	components[player_id] = {}
	tactical_event_counts[player_id] = {}
	prior_actionable_windows[player_id] = false
	tactical_decision_records[player_id] = {}
	resource_event_counts[player_id] = {}
	map_event_counts[player_id] = {}

func on_damage(attacker_id: int, victim_id: int, amount: float, projectile_id: int = -1) -> bool:
	if attacker_id < 0 or attacker_id == victim_id:
		return false
	var dealt_weight := reward_config.team_damage_dealt if config.team_mode else reward_config.ffa_damage_dealt
	var taken_weight := reward_config.team_damage_taken if config.team_mode else reward_config.ffa_damage_taken
	_add(attacker_id, "damage_dealt", amount * dealt_weight)
	_add(victim_id, "damage_taken", amount * taken_weight)
	var authorized := _is_authorized_projectile(projectile_id, attacker_id)
	if authorized:
		_increment_tactical_event(attacker_id, "authorized_hit")
		_increment_tactical_event(attacker_id, "authorized_damage", roundi(amount))
		if reward_config.legal_window_damage != 0.0:
			_add(attacker_id, "legal_window_damage", amount * reward_config.legal_window_damage)
	if reward_config.efficient_damage != 0.0:
		_add(attacker_id, "efficient_damage", amount * reward_config.efficient_damage)
	if reward_config.unfavorable_exchange != 0.0:
		_add(victim_id, "unfavorable_exchange", amount * reward_config.unfavorable_exchange)
	return authorized

func on_tactical_execution(player_id: int, decision: Dictionary, diagnostics: Dictionary, decision_generation_id: int = -1) -> void:
	if player_id < 0 or bool(diagnostics.get("script_fallback", false)):
		return
	if decision_generation_id > 0:
		var player_records: Dictionary = tactical_decision_records.get(player_id, {})
		player_records[decision_generation_id] = {
			"target_valid": bool(diagnostics.get("target_valid", false)),
			"fire_allowed": bool(diagnostics.get("fire_allowed", false)),
			"fire_block_reason": str(diagnostics.get("fire_block_reason", "")),
		}
		tactical_decision_records[player_id] = player_records
	var target_valid := bool(diagnostics.get("target_valid", false))
	var fire_allowed := bool(diagnostics.get("fire_allowed", false))
	var actionable_window := bool(diagnostics.get("actionable_window", false))
	var was_actionable := bool(prior_actionable_windows.get(player_id, false))
	prior_actionable_windows[player_id] = actionable_window
	if reward_config.actionable_window_entry != 0.0 and actionable_window and not was_actionable:
		_add(player_id, "actionable_window_entry", reward_config.actionable_window_entry)
		_increment_tactical_event(player_id, "actionable_window_entry")
	var fire_mode := int(decision.get("fire_mode", HighLevelDecision.FireMode.HOLD_FIRE))
	var movement_mode := int(decision.get("movement_mode", HighLevelDecision.MovementMode.KEEP_RANGE))
	if fire_mode != HighLevelDecision.FireMode.HOLD_FIRE:
		_increment_tactical_event(player_id, "fire_intent")
		if not fire_allowed:
			var reason := str(diagnostics.get("fire_block_reason", "unspecified"))
			_increment_tactical_event(player_id, "fire_rejected_%s" % (reason if not reason.is_empty() else "unspecified"))
	if reward_config.missed_legal_window != 0.0 and target_valid and actionable_window and fire_mode == HighLevelDecision.FireMode.HOLD_FIRE:
		_add(player_id, "missed_legal_window", reward_config.missed_legal_window)
	var projectile_threat := float(diagnostics.get("primary_projectile_threat", 0.0))
	if reward_config.avoidable_pressure_retreat != 0.0 and movement_mode == HighLevelDecision.MovementMode.RETREAT and target_valid and actionable_window and projectile_threat <= reward_config.pressure_retreat_threat_ceiling and not bool(diagnostics.get("safety_override", false)):
		_add(player_id, "pressure_retreat", reward_config.avoidable_pressure_retreat)
	var override_reason := str(diagnostics.get("override_reason", ""))
	if reward_config.avoidable_override != 0.0 and bool(diagnostics.get("safety_override", false)) and override_reason != "emergency_projectile":
		_add(player_id, "avoidable_override", reward_config.avoidable_override)

func register_authorized_projectile(projectile_id: int, player_id: int, decision_generation_or_diagnostics: Variant = -1, diagnostics: Dictionary = {}) -> void:
	if projectile_id < 0 or player_id < 0:
		return
	if authorized_projectile_owners.has(projectile_id):
		return
	var decision_generation_id := -1
	var decision_facts: Dictionary = diagnostics
	if typeof(decision_generation_or_diagnostics) == TYPE_INT:
		decision_generation_id = int(decision_generation_or_diagnostics)
	elif typeof(decision_generation_or_diagnostics) == TYPE_DICTIONARY:
		decision_facts = decision_generation_or_diagnostics as Dictionary
	if bool(decision_facts.get("script_fallback", false)):
		return
	if decision_generation_id == 0:
		return
	if decision_generation_id > 0:
		decision_facts = tactical_decision_records.get(player_id, {}).get(decision_generation_id, {})
	if bool(decision_facts.get("target_valid", false)) and bool(decision_facts.get("fire_allowed", false)):
		authorized_projectile_owners[projectile_id] = {
			"player_id": player_id,
			"decision_generation_id": decision_generation_id,
		}
		_increment_tactical_event(player_id, "fire_authorized")
		_increment_tactical_event(player_id, "authorized_projectile")
		if reward_config.legal_window_commitment != 0.0:
			_add(player_id, "legal_window_commitment", reward_config.legal_window_commitment)
		if reward_config.authorized_projectile_cost != 0.0:
			_add(player_id, "authorized_projectile_cost", reward_config.authorized_projectile_cost)

func discard_projectile(projectile_id: int) -> void:
	authorized_projectile_owners.erase(projectile_id)

func on_kill(killer_id: int, victim_id: int) -> void:
	if killer_id >= 0 and killer_id != victim_id:
		_add(killer_id, "kill", reward_config.team_kill if config.team_mode else reward_config.ffa_kill)
	_add(victim_id, "death", reward_config.team_death if config.team_mode else reward_config.ffa_death)

func on_environment_damage(victim_id: int, amount: float, hazard: String = "environment") -> void:
	if victim_id < 0:
		return
	_increment_map_event(victim_id, "%s_damage" % hazard, roundi(amount))
	_add(victim_id, "%s_damage_taken" % hazard, amount * reward_config.environment_damage_taken)

func on_environment_death(victim_id: int, hazard: String = "environment") -> void:
	if victim_id < 0:
		return
	_increment_map_event(victim_id, "%s_death" % hazard)
	_add(victim_id, "%s_death" % hazard, reward_config.environment_death)

func on_match_finished(result: Dictionary) -> void:
	var winner := int(result.get("winner_player_id", -1))
	var winner_team := int(result.get("winner_team_id", -1))
	var teams_by_player: Dictionary = {}
	for standing in result.get("standings", []):
		teams_by_player[int(standing.get("player_id", -1))] = int(standing.get("team_id", -1))
	for player_id in totals.keys():
		var won_team_match := config.team_mode and winner_team >= 0 and int(teams_by_player.get(player_id, -1)) == winner_team
		if won_team_match or (not config.team_mode and int(player_id) == winner):
			_add(int(player_id), "win", reward_config.team_win if config.team_mode else reward_config.ffa_win)
		if reward_config.positive_score_margin != 0.0 and _score_margin_for_player(int(player_id), result) > 0:
			_add(int(player_id), "positive_score_margin", reward_config.positive_score_margin)

func get_total(player_id: int) -> float:
	return float(totals.get(player_id, 0.0))

func get_components(player_id: int) -> Dictionary:
	return components.get(player_id, {}).duplicate()

func get_tactical_event_counts(player_id: int) -> Dictionary:
	return tactical_event_counts.get(player_id, {}).duplicate()

func get_resource_event_counts(player_id: int) -> Dictionary:
	return resource_event_counts.get(player_id, {}).duplicate()

func get_map_event_counts(player_id: int) -> Dictionary:
	return map_event_counts.get(player_id, {}).duplicate()

func on_map_event(player_id: int, event_source: String, amount: int = 1) -> void:
	if player_id < 0 or event_source.is_empty():
		return
	_increment_map_event(player_id, event_source, amount)

func get_resource_contest_radius() -> float:
	return reward_config.resource_contest_radius if reward_config != null else 0.0

func on_pickup_collected(pickup_id: int, player_id: int, pickup_type: String, contested: bool, restored_health: float = 0.0, nearest_enemy_distance: float = -1.0) -> void:
	if pickup_id < 0 or player_id < 0 or collected_pickup_ids.has(pickup_id):
		return
	collected_pickup_ids[pickup_id] = true
	_increment_resource_event(player_id, "pickup_collected_%s" % pickup_type)
	_record_pickup_contest_proximity(player_id, nearest_enemy_distance)
	if pickup_type == "magnet":
		return
	if contested:
		_increment_resource_event(player_id, "contested_pickup_capture")
		if reward_config.contested_pickup_capture != 0.0:
			_add(player_id, "contested_pickup_capture", reward_config.contested_pickup_capture)
	if pickup_type == "health":
		if restored_health > 0.0:
			_increment_resource_event(player_id, "health_restored", roundi(restored_health))
			if reward_config.pickup_health_value_per_hp != 0.0:
				_add(player_id, "pickup_health_value", restored_health * reward_config.pickup_health_value_per_hp)
		else:
			_increment_resource_event(player_id, "health_no_value")

func _record_pickup_contest_proximity(player_id: int, nearest_enemy_distance: float) -> void:
	if nearest_enemy_distance < 0.0:
		return
	var contest_radius := get_resource_contest_radius()
	if contest_radius <= 0.0:
		return
	if nearest_enemy_distance <= contest_radius:
		_increment_resource_event(player_id, "pickup_contest_within_radius")
	elif nearest_enemy_distance <= contest_radius * 1.6:
		_increment_resource_event(player_id, "pickup_contest_approach")
	else:
		_increment_resource_event(player_id, "pickup_uncontested_far")

func on_pickup_shield_absorption(player_id: int, pickup_id: int, amount: float) -> void:
	if player_id < 0 or pickup_id < 0 or amount <= 0.0:
		return
	_increment_resource_event(player_id, "shield_absorbed", roundi(amount))
	if reward_config.pickup_shield_absorb_value_per_hp != 0.0:
		_add(player_id, "pickup_shield_absorb_value", amount * reward_config.pickup_shield_absorb_value_per_hp)

func on_pickup_authorized_damage(player_id: int, pickup_type: String, pickup_id: int, amount: float) -> void:
	if player_id < 0 or pickup_id < 0 or amount <= 0.0:
		return
	if pickup_type == "haste":
		_increment_resource_event(player_id, "haste_authorized_damage", roundi(amount))
		if reward_config.pickup_haste_damage_value_per_hp != 0.0:
			_add(player_id, "pickup_haste_damage_value", amount * reward_config.pickup_haste_damage_value_per_hp)
	elif pickup_type == "overcharge":
		_increment_resource_event(player_id, "overcharge_authorized_damage", roundi(amount))
		if reward_config.pickup_overcharge_damage_value_per_hp != 0.0:
			_add(player_id, "pickup_overcharge_damage_value", amount * reward_config.pickup_overcharge_damage_value_per_hp)

func on_pickup_effect_expired(player_id: int, pickup_type: String, pickup_id: int, realized: bool) -> void:
	if player_id < 0 or pickup_id < 0 or realized:
		return
	_increment_resource_event(player_id, "%s_expired_unused" % pickup_type)

func _is_authorized_projectile(projectile_id: int, attacker_id: int) -> bool:
	if projectile_id < 0:
		return false
	var record: Variant = authorized_projectile_owners.get(projectile_id, {})
	authorized_projectile_owners.erase(projectile_id)
	return typeof(record) == TYPE_DICTIONARY and int((record as Dictionary).get("player_id", -1)) == attacker_id

func _score_margin_for_player(player_id: int, result: Dictionary) -> int:
	if config.team_mode:
		var team_by_player: Dictionary = {}
		for standing in result.get("standings", []):
			team_by_player[int(standing.get("player_id", -1))] = int(standing.get("team_id", -1))
		var player_team := int(team_by_player.get(player_id, -1))
		var team_scores: Dictionary = result.get("team_scores", {})
		if player_team < 0 or not team_scores.has(player_team):
			return 0
		var best_opponent_score := -INF
		for team_id in team_scores.keys():
			if int(team_id) != player_team:
				best_opponent_score = maxf(best_opponent_score, float(team_scores[team_id]))
		return int(team_scores[player_team]) - int(best_opponent_score) if best_opponent_score > -INF else 0
	var player_score := 0
	var best_opponent_score := -INF
	for standing in result.get("standings", []):
		var standing_player_id := int(standing.get("player_id", -1))
		var standing_score := int(standing.get("score", 0))
		if standing_player_id == player_id:
			player_score = standing_score
		else:
			best_opponent_score = maxf(best_opponent_score, float(standing_score))
	return player_score - int(best_opponent_score) if best_opponent_score > -INF else 0

func _add(player_id: int, component: String, value: float) -> void:
	if not totals.has(player_id):
		register_player(player_id)
	totals[player_id] = float(totals[player_id]) + value
	var data: Dictionary = components[player_id]
	data[component] = float(data.get(component, 0.0)) + value
	var tree := Engine.get_main_loop() as SceneTree
	var events := tree.root.get_node_or_null("GameEvents") if tree != null else null
	if events != null and events.has_method("emit_reward_changed"):
		events.emit_reward_changed({"player_id": player_id, "total": totals[player_id], "components": data.duplicate()})

func _increment_tactical_event(player_id: int, event_name: String, amount: int = 1) -> void:
	if not tactical_event_counts.has(player_id):
		tactical_event_counts[player_id] = {}
	var player_events: Dictionary = tactical_event_counts[player_id]
	player_events[event_name] = int(player_events.get(event_name, 0)) + amount

func _increment_resource_event(player_id: int, event_name: String, amount: int = 1) -> void:
	if not resource_event_counts.has(player_id):
		resource_event_counts[player_id] = {}
	var player_events: Dictionary = resource_event_counts[player_id]
	player_events[event_name] = int(player_events.get(event_name, 0)) + amount

func _increment_map_event(player_id: int, event_name: String, amount: int = 1) -> void:
	if not map_event_counts.has(player_id):
		map_event_counts[player_id] = {}
	var player_events: Dictionary = map_event_counts[player_id]
	player_events[event_name] = int(player_events.get(event_name, 0)) + amount
