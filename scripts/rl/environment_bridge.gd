extends Node
# 训练环境桥接层，连接 Godot 比赛循环与外部强化学习进程。
class_name EnvironmentBridge

const ARENA_SCENE_PATH := "res://scenes/arena/ArenaRoot.tscn"
const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/tactical_feature_builder.gd")
const TACTICAL_PROTOCOL := HighLevelDecision.PROTOCOL_VERSION
const TACTICAL_DECISION_FIELDS := {
	"protocol": true,
	"protocol_version": true,
	"target_slot": true,
	"movement_mode": true,
	"fire_mode": true,
	"skill_mode": true,
	"confidence": true,
	"decision_id": true,
	"candidate_index": true,
	"target_name": true,
	"movement_name": true,
	"fire_name": true,
	"skill_name": true,
}
const SAFE_DIAGNOSTIC_INT_FIELDS := [
	"protocol_version",
	"decision_generation_id",
]
const SAFE_DIAGNOSTIC_FLOAT_FIELDS := [
	"confidence",
	"target_health_ratio",
	"aim_error",
	"predicted_hit_probability",
	"stuck_score",
	"primary_projectile_threat",
	"nearest_wall_distance_ratio",
	"inference_latency_ms",
]
const SAFE_DIAGNOSTIC_BOOL_FIELDS := [
	"target_valid",
	"line_of_sight",
	"fire_allowed",
	"actionable_window",
	"stuck_recovery_active",
	"safety_override",
	"script_fallback",
]
const SAFE_DIAGNOSTIC_STRING_FIELDS := [
	"target",
	"movement_mode",
	"movement_reason",
	"fire_mode",
	"skill_mode",
	"fire_block_reason",
	"override_reason",
	"skill_reason",
	"model_id",
]
const SAFE_FALLBACK_COUNT_FIELDS := {
	"mask_corrected": true,
	"empty_masks": true,
	"missing_observation": true,
	"remote_pending_or_unavailable": true,
	"remote_error": true,
	"protocol_error": true,
	"invalid_response_type": true,
	"missing_decision": true,
	"non_finite_decision": true,
	"model_id_mismatch": true,
	"timeout": true,
	"timeout_or_disconnected": true,
	"low_confidence": true,
	"decision_collapse": true,
	"no_target_fire": true,
}

var arena: Node
var last_actions: Dictionary = {}
var last_tactical_decisions: Dictionary = {}
var tactical_reward_baseline: Dictionary = {}
var last_tactical_error: String = ""

func reset_environment(config_data: Variant) -> void:
	if arena != null:
		arena.queue_free()
	var config: MatchConfig = config_data if config_data is MatchConfig else MatchConfig.from_dict(config_data)
	var requested_headless := true
	if config_data is MatchConfig:
		requested_headless = (config_data as MatchConfig).headless
	elif config_data is Dictionary and (config_data as Dictionary).has("headless"):
		requested_headless = bool((config_data as Dictionary).get("headless", true))
	config.headless = requested_headless
	if not config.record_replay:
		config.training_fast_mode = true
	var arena_scene := load(ARENA_SCENE_PATH) as PackedScene
	arena = arena_scene.instantiate()
	add_child(arena)
	arena.configure(config)
	last_actions.clear()
	last_tactical_decisions.clear()
	tactical_reward_baseline.clear()
	last_tactical_error = ""

func get_observations() -> Dictionary:
	var out: Dictionary = {}
	if arena == null:
		return out
	for player in arena.players:
		out[player.player_id] = arena.build_observation(player).to_dict()
	return out

func apply_actions(actions: Dictionary) -> void:
	last_actions = actions.duplicate(true)
	if arena != null and arena.has_method("apply_training_actions"):
		arena.apply_training_actions(actions)

func apply_tactical_decisions(decisions: Dictionary) -> bool:
	last_tactical_error = ""
	if decisions.is_empty():
		return _reject_tactical("step_tactical decisions must not be empty")
	for key in decisions.keys():
		var raw: Variant = decisions[key]
		if typeof(raw) != TYPE_DICTIONARY:
			return _reject_tactical("Tactical decision for player %s must be a dictionary" % str(key))
		var decision_data := raw as Dictionary
		for field in decision_data.keys():
			if not TACTICAL_DECISION_FIELDS.has(str(field)):
				return _reject_tactical("Raw or unknown tactical decision field: %s" % str(field))
		if decision_data.has("protocol") and int(decision_data.get("protocol", TACTICAL_PROTOCOL)) != TACTICAL_PROTOCOL:
			return _reject_tactical("Tactical decision protocol must be %d" % TACTICAL_PROTOCOL)
		if decision_data.has("protocol_version") and int(decision_data.get("protocol_version", TACTICAL_PROTOCOL)) != TACTICAL_PROTOCOL:
			return _reject_tactical("Tactical decision protocol_version must be %d" % TACTICAL_PROTOCOL)
	if arena == null:
		return _reject_tactical("Environment has not been reset")
	var tactical_player_ids := _tactical_player_ids()
	if tactical_player_ids.is_empty():
		return _reject_tactical("Environment has no tactical-controllable players")
	var received_player_ids: Array[int] = []
	for key in decisions.keys():
		var player_id := _parse_player_id(key)
		if player_id < 0 or received_player_ids.has(player_id):
			return _reject_tactical("step_tactical decisions must contain exactly tactical player IDs %s" % str(tactical_player_ids))
		received_player_ids.append(player_id)
	received_player_ids.sort()
	if received_player_ids != tactical_player_ids:
		return _reject_tactical(
			"step_tactical decisions must contain exactly tactical player IDs %s; received %s"
			% [str(tactical_player_ids), str(received_player_ids)]
		)
	var players_by_id: Dictionary = {}
	for player in arena.players:
		var player_id := int(player.player_id)
		if tactical_player_ids.has(player_id):
			players_by_id[player_id] = player
	var masked_decisions: Dictionary = {}
	for key in decisions.keys():
		var player_id := _parse_player_id(key)
		var raw: Variant = decisions[key]
		var decision_data := raw as Dictionary
		var player = players_by_id[player_id]
		var tactical_data := _build_tactical_data(player)
		var masks: Dictionary = tactical_data.get("action_masks", {})
		if not HighLevelDecision.masks_have_any_action(masks):
			return _reject_tactical("Player %d has no legal tactical action" % player_id)
		var decision = HighLevelDecision.from_dict(decision_data)
		decision.apply_masks(masks)
		masked_decisions[player_id] = decision
	if not arena.has_method("apply_tactical_decisions") or not bool(arena.apply_tactical_decisions(masked_decisions)):
		return _reject_tactical("Arena rejected tactical decisions")
	last_tactical_decisions.clear()
	for player_id in masked_decisions.keys():
		last_tactical_decisions[player_id] = masked_decisions[player_id].copy()
	return true

func get_tactical_snapshot() -> Dictionary:
	var snapshot := {
		"protocol": TACTICAL_PROTOCOL,
		"players": {},
		"terminated": get_terminated(),
		"truncated": get_truncated(),
	}
	if arena == null:
		return snapshot
	var rewards := get_rewards()
	var players_out: Dictionary = {}
	var tactical_player_ids := _tactical_player_ids()
	for player in arena.players:
		var player_id := int(player.player_id)
		var total_reward := float(rewards.get(player_id, 0.0))
		var previous_reward := float(tactical_reward_baseline.get(player_id, 0.0))
		var supports_tactical := tactical_player_ids.has(player_id)
		var player_data := {
			"player_id": player_id,
			"supports_tactical_decisions": supports_tactical,
			"reward_delta": total_reward - previous_reward,
			"reward_total": total_reward,
			"reward_components": {},
		}
		if arena.has_method("get_reward_components"):
			player_data["reward_components"] = arena.get_reward_components(player_id)
		if arena.has_method("get_tactical_event_counts"):
			player_data["tactical_event_counts"] = arena.get_tactical_event_counts(player_id)
		if arena.has_method("get_resource_event_counts"):
			player_data["resource_event_counts"] = arena.get_resource_event_counts(player_id)
		if arena.has_method("get_map_event_counts"):
			player_data["map_event_counts"] = arena.get_map_event_counts(player_id)
		if not supports_tactical:
			players_out[player_id] = player_data
			tactical_reward_baseline[player_id] = total_reward
			continue
		var tactical_data := _build_tactical_data(player)
		var decision: Variant = _executed_decision_for(player)
		var diagnostics: Dictionary = {}
		if arena.has_method("get_tactical_diagnostics"):
			diagnostics = _safe_diagnostics(arena.get_tactical_diagnostics(player_id))
		player_data["tactical_features"] = Array(tactical_data.get("features", PackedFloat32Array()))
		player_data["action_masks"] = tactical_data.get("action_masks", {}).duplicate(true)
		player_data["executed_decision"] = decision.to_dict()
		player_data["diagnostics"] = diagnostics
		players_out[player_id] = player_data
		tactical_reward_baseline[player_id] = total_reward
	snapshot["players"] = players_out
	snapshot["rewards"] = rewards
	var info := {
		"players": arena.players.size(),
		"supports_tactical_decisions": not tactical_player_ids.is_empty(),
		"tactical_player_ids": tactical_player_ids,
		"feature_schema_version": TacticalFeatureBuilder.FEATURE_SCHEMA_VERSION,
		"reward_profile_id": _reward_profile_id(),
	}
	_add_match_result_info(info)
	snapshot["info"] = info
	return snapshot

func get_last_tactical_error() -> String:
	return last_tactical_error

func step() -> void:
	if arena == null:
		return
	arena._physics_process(1.0 / float(arena.balance.physics_hz))

func get_rewards() -> Dictionary:
	return arena.get_rewards() if arena != null else {}

func get_terminated() -> bool:
	return arena == null or arena.finished

func get_truncated() -> bool:
	return false

func get_info() -> Dictionary:
	var info := {
		"players": arena.players.size() if arena != null else 0,
		"last_actions": last_actions,
		"supports_external_actions": true,
		"supports_multi_arena": false,
	}
	_add_match_result_info(info)
	return info

func _add_match_result_info(info: Dictionary) -> void:
	if arena == null or not get_terminated() or not arena.has_method("get_match_result"):
		return
	var result: Variant = arena.get_match_result()
	if typeof(result) == TYPE_DICTIONARY and not (result as Dictionary).is_empty():
		info["match_result"] = (result as Dictionary).duplicate(true)

func _reward_profile_id() -> String:
	if arena == null:
		return "baseline"
	var match_config: Variant = arena.get("config")
	if match_config is MatchConfig:
		return (match_config as MatchConfig).reward_profile_id
	return "baseline"

func _build_tactical_data(player) -> Dictionary:
	var observation: AgentObservation = arena.build_observation(player)
	var current_decision: Variant = _executed_decision_for(player)
	var builder: Variant = player.controller.get("feature_builder") if player.controller != null else null
	if builder != null and builder.has_method("build"):
		var tactical_config := HybridAgentConfig.for_profile(_reward_profile_id())
		var arena_map: Variant = arena.get("arena_map")
		return builder.build(observation, arena.balance, tactical_config, current_decision, arena_map as Node)
	return {}

func _executed_decision_for(player):
	if arena != null and arena.has_method("get_executed_tactical_decision"):
		var executed: Variant = arena.get_executed_tactical_decision(int(player.player_id))
		if typeof(executed) == TYPE_DICTIONARY and not (executed as Dictionary).is_empty():
			return HighLevelDecision.from_dict(executed)
	if last_tactical_decisions.has(int(player.player_id)):
		return last_tactical_decisions[int(player.player_id)].copy()
	var current: Variant = player.controller.get("current_decision") if player.controller != null else null
	if current != null and current.has_method("copy"):
		return current.copy()
	return HighLevelDecision.new()

func _safe_diagnostics(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source := value as Dictionary
	var out: Dictionary = {}
	for field in SAFE_DIAGNOSTIC_INT_FIELDS:
		if source.has(field) and typeof(source[field]) == TYPE_INT:
			out[field] = int(source[field])
	for field in SAFE_DIAGNOSTIC_FLOAT_FIELDS:
		if source.has(field) and typeof(source[field]) in [TYPE_INT, TYPE_FLOAT]:
			var number := float(source[field])
			if is_finite(number):
				out[field] = number
	for field in SAFE_DIAGNOSTIC_BOOL_FIELDS:
		if source.has(field) and typeof(source[field]) == TYPE_BOOL:
			out[field] = bool(source[field])
	for field in SAFE_DIAGNOSTIC_STRING_FIELDS:
		if source.has(field) and typeof(source[field]) in [TYPE_STRING, TYPE_STRING_NAME]:
			out[field] = str(source[field])
	var aim_point: Variant = source.get("predicted_aim_point", {})
	if typeof(aim_point) == TYPE_DICTIONARY:
		var point := aim_point as Dictionary
		var raw_x: Variant = point.get("x")
		var raw_y: Variant = point.get("y")
		if typeof(raw_x) in [TYPE_INT, TYPE_FLOAT] and typeof(raw_y) in [TYPE_INT, TYPE_FLOAT]:
			var x := float(raw_x)
			var y := float(raw_y)
			if is_finite(x) and is_finite(y):
				out["predicted_aim_point"] = {"x": x, "y": y}
	var burst_state: Variant = source.get("burst_state", {})
	if typeof(burst_state) == TYPE_DICTIONARY:
		var burst := burst_state as Dictionary
		var remaining: Variant = burst.get("remaining")
		var recovery: Variant = burst.get("recovery_timer")
		if typeof(remaining) == TYPE_INT and typeof(recovery) in [TYPE_INT, TYPE_FLOAT]:
			var recovery_timer := float(recovery)
			if is_finite(recovery_timer):
				out["burst_state"] = {
					"remaining": int(remaining),
					"recovery_timer": recovery_timer,
				}
	var fallback_counts: Variant = source.get("fallback_counts", {})
	if typeof(fallback_counts) == TYPE_DICTIONARY:
		var safe_counts: Dictionary = {}
		for field in (fallback_counts as Dictionary).keys():
			var key := str(field)
			var count: Variant = (fallback_counts as Dictionary)[field]
			if SAFE_FALLBACK_COUNT_FIELDS.has(key) and typeof(count) == TYPE_INT:
				safe_counts[key] = maxi(int(count), 0)
		out["fallback_counts"] = safe_counts
	return out

func _tactical_player_ids() -> Array[int]:
	if arena == null or not arena.has_method("get_tactical_player_ids"):
		return []
	var out: Array[int] = []
	for value in arena.get_tactical_player_ids():
		var player_id := int(value)
		if player_id >= 0 and not out.has(player_id):
			out.append(player_id)
	out.sort()
	return out

func _parse_player_id(key: Variant) -> int:
	if key is int:
		return int(key)
	var text := str(key)
	return int(text) if text.is_valid_int() else -1

func _reject_tactical(message: String) -> bool:
	last_tactical_error = message
	return false
