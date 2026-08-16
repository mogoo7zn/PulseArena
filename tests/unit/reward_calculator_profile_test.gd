extends RefCounted

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const RewardCalculatorScript = preload("res://scripts/rl/reward_calculator.gd")

func run() -> int:
	var failures := 0
	failures += _test_legal_window_damage_requires_an_authorized_projectile_hit()
	failures += _test_authorized_projectile_events_are_counted_once()
	failures += _test_authorized_projectile_keeps_its_decision_generation()
	failures += _test_blocked_fire_does_not_receive_legal_window_reward()
	failures += _test_pressure_retreat_penalty_requires_a_safe_actionable_window()
	failures += _test_pressure_profile_rewards_window_entry_once_and_charges_authorized_shot()
	failures += _test_resource_value_rewards_only_realized_benefit()
	failures += _test_map_event_sources_remain_separate()
	failures += _test_score_margin_profile_rewards_real_damage_and_positive_margin_only()
	return failures

func _test_legal_window_damage_requires_an_authorized_projectile_hit() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	calculator.register_player(1)
	calculator.on_tactical_execution(0, _normal_fire_decision(), {
		"target_valid": true,
		"fire_allowed": true,
		"actionable_window": true,
		"safety_override": false,
	})
	if calculator.get_components(0).has("legal_window_commitment"):
		push_error("REWARD TEST: legal-window commitment must wait for a realized authorized projectile")
		return 1
	calculator.register_authorized_projectile(41, 0, {
		"target_valid": true,
		"fire_allowed": true,
	})
	calculator.on_damage(0, 1, 10.0, 41)
	var components := calculator.get_components(0)
	if not is_equal_approx(float(components.get("legal_window_commitment", 0.0)), 0.05):
		push_error("REWARD TEST: one realized authorized projectile must receive one commitment reward")
		return 1
	if not is_equal_approx(float(components.get("legal_window_damage", 0.0)), 0.30):
		push_error("REWARD TEST: only an authorized projectile hit must receive legal-window damage reward")
		return 1
	return 0

func _test_blocked_fire_does_not_receive_legal_window_reward() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	calculator.on_tactical_execution(0, _normal_fire_decision(), {
		"target_valid": true,
		"fire_allowed": false,
		"actionable_window": true,
		"safety_override": false,
	})
	calculator.register_authorized_projectile(42, 0, {
		"target_valid": true,
		"fire_allowed": false,
	})
	calculator.on_damage(0, 1, 10.0, 42)
	var components := calculator.get_components(0)
	if components.has("legal_window_commitment") or components.has("legal_window_damage"):
		push_error("REWARD TEST: blocked fire must not receive legal-window rewards")
		return 1
	return 0

func _test_authorized_projectile_events_are_counted_once() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	calculator.register_player(1)
	calculator.register_authorized_projectile(71, 0, {"target_valid": true, "fire_allowed": true})
	calculator.on_damage(0, 1, 10.0, 71)
	calculator.on_damage(0, 1, 10.0, 71)
	if not calculator.has_method("get_tactical_event_counts"):
		push_error("REWARD TEST: tactical event counter API is missing")
		return 1
	var events: Dictionary = calculator.call("get_tactical_event_counts", 0)
	if int(events.get("authorized_projectile", 0)) != 1 or int(events.get("authorized_hit", 0)) != 1:
		push_error("REWARD TEST: authorized projectile and hit events must be counted exactly once")
		return 1
	return 0

func _test_authorized_projectile_keeps_its_decision_generation() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	calculator.register_player(1)
	calculator.on_tactical_execution(0, _normal_fire_decision(), {
		"target_valid": true,
		"fire_allowed": true,
		"actionable_window": true,
	}, 7)
	calculator.register_authorized_projectile(73, 0, 7, {
		"target_valid": true,
		"fire_allowed": true,
	})
	# A later decision is blocked. It must not retroactively change projectile 73.
	calculator.on_tactical_execution(0, _normal_fire_decision(), {
		"target_valid": true,
		"fire_allowed": false,
		"actionable_window": false,
	}, 8)
	calculator.on_damage(0, 1, 10.0, 73)
	var events: Dictionary = calculator.get_tactical_event_counts(0)
	if int(events.get("fire_authorized", 0)) != 1:
		push_error("REWARD TEST: a valid generation must emit exactly one fire_authorized event")
		return 1
	if int(events.get("authorized_hit", 0)) != 1 or int(events.get("authorized_damage", 0)) != 10:
		push_error("REWARD TEST: hit and damage must retain the projectile's decision generation")
		return 1
	return 0

func _test_score_margin_profile_rewards_real_damage_and_positive_margin_only() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "score_margin_discipline"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	calculator.register_player(1)
	calculator.on_damage(0, 1, 10.0)
	calculator.on_match_finished({
		"winner_player_id": 0,
		"winner_team_id": -1,
		"standings": [
			{"player_id": 0, "team_id": 0, "score": 2},
			{"player_id": 1, "team_id": 1, "score": 1},
		],
	})
	var winner_components := calculator.get_components(0)
	var loser_components := calculator.get_components(1)
	if not is_equal_approx(float(winner_components.get("efficient_damage", 0.0)), 0.20):
		push_error("REWARD TEST: score-margin profile must reward realized damage")
		return 1
	if not is_equal_approx(float(loser_components.get("unfavorable_exchange", 0.0)), -0.20):
		push_error("REWARD TEST: score-margin profile must penalize realized damage taken")
		return 1
	if not is_equal_approx(float(winner_components.get("positive_score_margin", 0.0)), 0.25):
		push_error("REWARD TEST: only a true positive score margin receives the terminal margin reward")
		return 1
	return 0

func _test_pressure_retreat_penalty_requires_a_safe_actionable_window() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	var retreat := {
		"fire_mode": HighLevelDecision.FireMode.HOLD_FIRE,
		"movement_mode": HighLevelDecision.MovementMode.RETREAT,
	}
	calculator.on_tactical_execution(0, retreat, {
		"target_valid": true,
		"fire_allowed": true,
		"actionable_window": true,
		"primary_projectile_threat": 0.0,
		"safety_override": false,
	})
	var pressure_penalty := float(calculator.get_components(0).get("pressure_retreat", 0.0))
	if pressure_penalty >= 0.0:
		push_error("REWARD TEST: threat-free retreat from an actionable window must be penalized")
		return 1
	var emergency := RewardCalculatorScript.new() as RewardCalculator
	emergency.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	emergency.register_player(0)
	emergency.on_tactical_execution(0, retreat, {
		"target_valid": true,
		"fire_allowed": true,
		"actionable_window": true,
		"primary_projectile_threat": 0.95,
		"safety_override": true,
		"override_reason": "emergency_projectile",
	})
	if emergency.get_components(0).has("pressure_retreat"):
		push_error("REWARD TEST: emergency retreat must not receive pressure penalty")
		return 1
	return 0

func _test_pressure_profile_rewards_window_entry_once_and_charges_authorized_shot() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	var decision := _normal_fire_decision()
	calculator.on_tactical_execution(0, decision, {"target_valid": true, "actionable_window": false})
	calculator.on_tactical_execution(0, decision, {"target_valid": true, "actionable_window": true})
	calculator.on_tactical_execution(0, decision, {"target_valid": true, "actionable_window": true})
	calculator.register_authorized_projectile(99, 0, {"target_valid": true, "fire_allowed": true})
	var components := calculator.get_components(0)
	if not is_equal_approx(float(components.get("actionable_window_entry", 0.0)), 0.02):
		push_error("REWARD TEST: a newly acquired actionable window must receive exactly one small approach reward")
		return 1
	if not is_equal_approx(float(components.get("authorized_projectile_cost", 0.0)), -0.01):
		push_error("REWARD TEST: each realized authorized projectile must carry a small energy-efficiency cost")
		return 1
	var events: Dictionary = calculator.get_tactical_event_counts(0)
	if int(events.get("actionable_window_entry", 0)) != 1:
		push_error("REWARD TEST: a continuously open firing lane must not farm entry rewards")
		return 1
	return 0

func _test_resource_value_rewards_only_realized_benefit() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	calculator.configure(config, RewardConfig.default().for_profile(config.reward_profile_id))
	calculator.register_player(0)
	# Full-health and magnet collection are observable but cannot farm positive reward.
	calculator.on_pickup_collected(201, 0, "health", false, 0.0)
	calculator.on_pickup_collected(202, 0, "magnet", true, 0.0)
	if calculator.get_components(0).has("pickup_health_value") or calculator.get_components(0).has("contested_pickup_capture"):
		push_error("REWARD TEST: collection without realized value must not grant positive reward")
		return 1
	calculator.on_pickup_collected(203, 0, "health", true, 12.0)
	calculator.on_pickup_collected(203, 0, "health", true, 12.0)
	calculator.on_pickup_collected(208, 0, "haste", false, 0.0, 310.0)
	calculator.on_pickup_collected(209, 0, "pulse", false, 0.0, 560.0)
	calculator.on_pickup_shield_absorption(0, 204, 8.0)
	calculator.on_pickup_authorized_damage(0, "haste", 205, 10.0)
	calculator.on_pickup_authorized_damage(0, "overcharge", 206, 10.0)
	calculator.on_pickup_effect_expired(0, "shield", 207, false)
	var events: Dictionary = calculator.get_resource_event_counts(0)
	if int(events.get("contested_pickup_capture", 0)) != 1 or int(events.get("health_restored", 0)) != 12:
		push_error("REWARD TEST: pickup collection must be exactly once and value must match restored health")
		return 1
	if int(events.get("shield_absorbed", 0)) != 8 or int(events.get("haste_authorized_damage", 0)) != 10 or int(events.get("overcharge_authorized_damage", 0)) != 10 or int(events.get("shield_expired_unused", 0)) != 1:
		push_error("REWARD TEST: shield and buffs must be rewarded only after realized benefit")
		return 1
	if int(events.get("pickup_contest_approach", 0)) != 1 or int(events.get("pickup_uncontested_far", 0)) != 1:
		push_error("REWARD TEST: pickup diagnostics must distinguish near-miss contention from distant collection")
		return 1
	return 0

func _test_map_event_sources_remain_separate() -> int:
	var calculator := RewardCalculatorScript.new() as RewardCalculator
	var config := MatchConfig.new()
	calculator.configure(config, RewardConfig.default())
	calculator.register_player(0)
	calculator.on_environment_damage(0, 4.0, "dungeon_trap")
	calculator.on_environment_death(0, "sky_squeeze")
	calculator.on_map_event(0, "mist_portal")
	var events: Dictionary = calculator.get_map_event_counts(0)
	if int(events.get("dungeon_trap_damage", 0)) != 4 or int(events.get("sky_squeeze_death", 0)) != 1 or int(events.get("mist_portal", 0)) != 1:
		push_error("REWARD TEST: map mechanics must retain source-specific event counters")
		return 1
	return 0


func _normal_fire_decision() -> Dictionary:
	return {"fire_mode": HighLevelDecision.FireMode.NORMAL}
