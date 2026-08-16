extends RefCounted

const EnvironmentBridgeScript = preload("res://scripts/rl/environment_bridge.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/tactical_feature_builder.gd")

class FakeController:
	extends RefCounted

	var hybrid: bool = false
	var current_decision = HighLevelDecision.new()
	var feature_builder := TacticalFeatureBuilder.new()
	var config := HybridAgentConfig.new()

	func _init(hybrid_value: bool) -> void:
		hybrid = hybrid_value

	func get_label() -> String:
		return "HYBRID" if hybrid else "SCRIPTED"

class FakePlayer:
	extends RefCounted

	var player_id: int = -1
	var controller: FakeController

	func _init(player_id_value: int, hybrid: bool) -> void:
		player_id = player_id_value
		controller = FakeController.new(hybrid)

class FakeArena:
	extends Node

	var players: Array = []
	var balance := GameBalance.default()
	var finished: bool = false
	var tactical_decision_cache: Dictionary = {}
	var apply_call_count: int = 0
	var diagnostics_by_id: Dictionary = {}

	func _init(hybrid_flags: Array[bool]) -> void:
		for player_id in range(hybrid_flags.size()):
			players.append(FakePlayer.new(player_id, hybrid_flags[player_id]))

	func build_observation(player, _validate_private_fields: bool = false) -> AgentObservation:
		var obs := AgentObservation.new()
		obs.player_id = int(player.player_id)
		obs.position = Vector2(540.0 + float(player.player_id) * 108.0, 303.75)
		obs.health_ratio = 0.75
		obs.energy_ratio = 0.8
		return obs

	func get_rewards() -> Dictionary:
		var rewards: Dictionary = {}
		for player in players:
			rewards[int(player.player_id)] = 0.0
		return rewards

	func get_reward_components(_player_id: int) -> Dictionary:
		return {}

	func get_tactical_player_ids() -> Array[int]:
		var out: Array[int] = []
		for player in players:
			if str(player.controller.get_label()) == "HYBRID":
				out.append(int(player.player_id))
		return out

	func apply_tactical_decisions(decisions: Dictionary) -> bool:
		apply_call_count += 1
		for player_id in decisions.keys():
			var decision = decisions[player_id].copy()
			tactical_decision_cache[int(player_id)] = decision
			players[int(player_id)].controller.current_decision = decision.copy()
		return true

	func get_executed_tactical_decision(player_id: int) -> Dictionary:
		return players[player_id].controller.current_decision.to_dict()

	func get_tactical_diagnostics(player_id: int) -> Dictionary:
		return diagnostics_by_id.get(player_id, {}).duplicate(true)

func run() -> int:
	var failures := 0
	var bridge := EnvironmentBridgeScript.new()
	failures += _test_runtime_tactical_feature_schema()
	failures += _test_tactical_snapshot_has_runtime_feature_schema(bridge)
	failures += _test_tactical_step_rejects_raw_action_payload(bridge)
	bridge.free()
	failures += _test_tactical_submission_requires_exact_player_set_atomically()
	failures += _test_non_hybrid_players_are_not_advertised_as_tactical()
	failures += _test_nested_private_diagnostics_are_removed()
	failures += _test_reward_profile_round_trip()
	return failures

func _test_runtime_tactical_feature_schema() -> int:
	var obs := AgentObservation.new()
	obs.player_id = 0
	obs.position = Vector2(540.0, 303.75)
	obs.health_ratio = 0.75
	obs.energy_ratio = 0.8
	var tactical_data := TacticalFeatureBuilder.new().build(
		obs,
		GameBalance.default(),
		HybridAgentConfig.new()
	)
	var features: PackedFloat32Array = tactical_data.get("features", PackedFloat32Array())
	if features.size() != 142 or not is_equal_approx(features[0], 0.25) or not is_equal_approx(features[1], 0.25):
		push_error("TACTICAL TEST: TacticalFeatureBuilder must runtime-build the 142-value v2 schema")
		return 1
	var masks: Dictionary = tactical_data.get("action_masks", {})
	var expected_sizes := {
		"target_slot": 7,
		"movement_mode": 12,
		"fire_mode": 6,
		"skill_mode": 6,
	}
	for key in expected_sizes:
		if not masks.has(key) or (masks[key] as Array).size() != int(expected_sizes[key]):
			push_error("TACTICAL TEST: runtime builder returned an invalid %s action mask" % key)
			return 1
	return 0

func _test_tactical_snapshot_has_runtime_feature_schema(bridge: EnvironmentBridge) -> int:
	if not bridge.has_method("get_tactical_snapshot"):
		push_error("TACTICAL TEST: EnvironmentBridge.get_tactical_snapshot is missing")
		return 1
	var snapshot: Dictionary = bridge.call("get_tactical_snapshot")
	if int(snapshot.get("protocol", -1)) != 2:
		push_error("TACTICAL TEST: snapshot protocol must be 2")
		return 1
	var players: Dictionary = snapshot.get("players", {})
	if not players.is_empty():
		push_error("TACTICAL TEST: an uninitialized bridge must have no tactical players")
		return 1
	return 0

func _test_tactical_step_rejects_raw_action_payload(bridge: EnvironmentBridge) -> int:
	if not bridge.has_method("apply_tactical_decisions"):
		push_error("TACTICAL TEST: EnvironmentBridge.apply_tactical_decisions is missing")
		return 1
	if bool(bridge.call("apply_tactical_decisions", {0: {"move_x": 1.0}})):
		push_error("TACTICAL TEST: tactical decisions accepted a raw move_x action")
		return 1
	if bridge.get_last_tactical_error().find("move_x") < 0:
		push_error("TACTICAL TEST: raw move_x rejection must identify the forbidden field")
		return 1
	return 0

func _test_tactical_submission_requires_exact_player_set_atomically() -> int:
	var failures := 0
	var bridge := EnvironmentBridgeScript.new()
	var arena := FakeArena.new([true, true])
	bridge.arena = arena
	if not bridge.apply_tactical_decisions({
		0: _decision(10),
		1: _decision(11),
	}):
		push_error("TACTICAL TEST: complete two-player tactical submission must be accepted")
		failures += 1
	var apply_count_before := arena.apply_call_count
	var accepted_partial := bridge.apply_tactical_decisions({0: _decision(99)})
	if accepted_partial:
		push_error("TACTICAL TEST: partial tactical submission must be rejected atomically")
		failures += 1
	if arena.apply_call_count != apply_count_before:
		push_error("TACTICAL TEST: rejected partial submission reached the arena cache")
		failures += 1
	if int(arena.tactical_decision_cache[0].decision_id) != 10 or int(arena.tactical_decision_cache[1].decision_id) != 11:
		push_error("TACTICAL TEST: rejected partial submission mixed new and stale decisions")
		failures += 1
	bridge.arena = null
	arena.free()
	bridge.free()
	return failures

func _test_non_hybrid_players_are_not_advertised_as_tactical() -> int:
	var failures := 0
	var bridge := EnvironmentBridgeScript.new()
	var arena := FakeArena.new([true, false])
	bridge.arena = arena
	var snapshot := bridge.get_tactical_snapshot()
	var players: Dictionary = snapshot.get("players", {})
	var hybrid_data: Dictionary = players.get(0, {})
	var scripted_data: Dictionary = players.get(1, {})
	if not bool(hybrid_data.get("supports_tactical_decisions", false)):
		push_error("TACTICAL TEST: Hybrid player must advertise tactical capability")
		failures += 1
	if bool(scripted_data.get("supports_tactical_decisions", true)):
		push_error("TACTICAL TEST: non-Hybrid player must explicitly reject tactical capability")
		failures += 1
	if scripted_data.has("tactical_features") or scripted_data.has("action_masks"):
		push_error("TACTICAL TEST: non-Hybrid snapshot fabricated tactical features or masks")
		failures += 1
	var info: Dictionary = snapshot.get("info", {})
	if info.get("tactical_player_ids", []) != [0]:
		push_error("TACTICAL TEST: snapshot must advertise exactly the live Hybrid player IDs")
		failures += 1
	if not bridge.apply_tactical_decisions({0: _decision(20)}):
		push_error("TACTICAL TEST: snapshot-advertised tactical player set must be accepted")
		failures += 1
	if bridge.apply_tactical_decisions({
		0: _decision(21),
		1: _decision(22),
	}):
		push_error("TACTICAL TEST: non-advertised player ID must be rejected")
		failures += 1
	bridge.arena = null
	arena.free()
	bridge.free()
	return failures

func _test_nested_private_diagnostics_are_removed() -> int:
	var failures := 0
	var bridge := EnvironmentBridgeScript.new()
	var arena := FakeArena.new([true])
	arena.diagnostics_by_id[0] = {
		"line_of_sight": false,
		"movement_reason": "engagement_vantage",
		"reserve_basis": "dash_ready",
		"reserve_ratio": 0.26,
		"fallback_counts": {
			"timeout": 2,
			"reserved_energy": 99.0,
			"nested": {"ammo": 3},
		},
		"burst_state": {
			"remaining": 2,
			"recovery_timer": 0.25,
			"reload_remaining": 0.5,
		},
		"decision": {
			"protocol_version": 2,
			"target_slot": 0,
			"movement_mode": 0,
			"fire_mode": 0,
			"skill_mode": 0,
			"magazine": 7,
		},
		"model_id": {"ammo": "private-model-data"},
	}
	bridge.arena = arena
	var snapshot := bridge.get_tactical_snapshot()
	var diagnostics: Dictionary = (snapshot.get("players", {}) as Dictionary).get(0, {}).get("diagnostics", {})
	if _contains_private_diagnostic_key(diagnostics):
		push_error("TACTICAL TEST: nested private diagnostic fields escaped serialization")
		failures += 1
	var fallback_counts: Dictionary = diagnostics.get("fallback_counts", {})
	if int(fallback_counts.get("timeout", 0)) != 2:
		push_error("TACTICAL TEST: safe fallback count was removed with private data")
		failures += 1
	if bool(diagnostics.get("line_of_sight", true)) or str(diagnostics.get("movement_reason", "")) != "engagement_vantage":
		push_error("TACTICAL TEST: safe tactical diagnostics must preserve line-of-sight and movement reason")
		failures += 1
	if str(diagnostics.get("reserve_basis", "")) != "dash_ready" or not is_equal_approx(float(diagnostics.get("reserve_ratio", 0.0)), 0.26):
		push_error("TACTICAL TEST: safe tactical diagnostics must preserve reserve cause and ratio")
		failures += 1
	if diagnostics.has("model_id"):
		push_error("TACTICAL TEST: non-string container was coerced into a safe primitive field")
		failures += 1
	bridge.arena = null
	arena.free()
	bridge.free()
	return failures

func _test_reward_profile_round_trip() -> int:
	var config := MatchConfig.new()
	config.reward_profile_id = "legal_window_pressure"
	var restored := MatchConfig.from_dict(config.to_dict())
	if restored.reward_profile_id != "legal_window_pressure":
		push_error("TACTICAL TEST: MatchConfig must preserve reward_profile_id through serialization")
		return 1
	return 0


func _decision(decision_id: int) -> Dictionary:
	return {
		"protocol": 2,
		"target_slot": 0,
		"movement_mode": 0,
		"fire_mode": 0,
		"skill_mode": 0,
		"confidence": 1.0,
		"decision_id": decision_id,
	}

func _contains_private_diagnostic_key(value: Variant) -> bool:
	if value is Dictionary:
		for key in value.keys():
			var normalized := str(key).to_lower().replace("-", "_")
			if normalized in ["reserve_basis", "reserve_ratio"]:
				continue
			for token in ["ammo", "reserve", "energy", "magazine", "reload", "cooldown"]:
				if normalized.find(token) >= 0:
					return true
			if _contains_private_diagnostic_key(value[key]):
				return true
	elif value is Array:
		for item in value:
			if _contains_private_diagnostic_key(item):
				return true
	return false
