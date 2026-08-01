extends PlayerController
# Hybrid Tactical Agent: learned high-level decisions plus deterministic combat executor.
class_name HybridAgentController

const HighLevelDecision = preload("res://scripts/agents/hybrid/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid/hybrid_agent_config.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/hybrid/tactical_feature_builder.gd")
const HybridCombatExecutor = preload("res://scripts/agents/hybrid/hybrid_combat_executor.gd")

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8766
const DEFAULT_TIMEOUT_MS := 16
const PROTOCOL_VERSION := 2
const REMOTE_MODEL_PREFIX := "remote:"
const RECONNECT_COOLDOWN_MS := 750

var host: String = DEFAULT_HOST
var port: int = DEFAULT_PORT
var timeout_ms: int = DEFAULT_TIMEOUT_MS
var model_id: String = HybridAgentConfig.MODEL_ID
var peer: StreamPeerTCP
var recv_buffer: String = ""
var request_id: int = 0
var pending_request_id: int = 0
var pending_request_started_ms: int = 0
var next_connect_attempt_ms: int = 0
var decision_timer: float = 0.0
var current_action := PlayerAction.new()
var current_decision := HighLevelDecision.new()
var last_remote_decision := HighLevelDecision.new()
var has_remote_decision: bool = false
var scripted: ScriptedAgentController
var feature_builder := TacticalFeatureBuilder.new()
var executor := HybridCombatExecutor.new()
var config := HybridAgentConfig.new()
var last_warning_ms: int = -100000
var low_confidence_timer: float = 0.0
var fallback_timer: float = 0.0
var no_target_fire_timer: float = 0.0
var repeated_decision_timer: float = 0.0
var previous_decision_key: String = ""
var fallback_counts: Dictionary = {}
var last_diagnostics: Dictionary = {}
var inference_latency_ms: float = 0.0

func _init(config_value: AgentDifficultyConfig = null, seed: int = 0, host_value: String = DEFAULT_HOST, port_value: int = DEFAULT_PORT, timeout_value_ms: int = DEFAULT_TIMEOUT_MS, model_id_value: String = "") -> void:
	host = host_value
	port = port_value
	timeout_ms = max(timeout_value_ms, 1)
	model_id = model_id_value if not model_id_value.is_empty() else HybridAgentConfig.MODEL_ID
	var hard_config := config_value if config_value != null else AgentDifficultyConfig.make("hard")
	if hard_config.name != "hard":
		hard_config = AgentDifficultyConfig.make("hard")
	scripted = ScriptedAgentController.new(hard_config, seed)

func reset() -> void:
	current_action = PlayerAction.new()
	current_decision = HighLevelDecision.new()
	decision_timer = 0.0
	recv_buffer = ""
	request_id = 0
	pending_request_id = 0
	pending_request_started_ms = 0
	next_connect_attempt_ms = 0
	has_remote_decision = false
	last_remote_decision = HighLevelDecision.new()
	low_confidence_timer = 0.0
	fallback_timer = 0.0
	no_target_fire_timer = 0.0
	repeated_decision_timer = 0.0
	previous_decision_key = ""
	fallback_counts.clear()
	last_diagnostics.clear()
	inference_latency_ms = 0.0
	if scripted != null:
		scripted.reset()
	executor.reset()
	_disconnect()

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	if _uses_remote_inference():
		var async_decision = _poll_model_response()
		if async_decision != null:
			current_decision = async_decision
	decision_timer -= delta
	if decision_timer > 0.0:
		return current_action.copy()
	decision_timer = _decision_interval()
	var scripted_action := scripted.get_action(observation, delta) if scripted != null else PlayerAction.new()
	var scripted_target := _scripted_target(observation)
	var tactical_data := feature_builder.build(observation, _balance(), config, current_decision)
	var masks: Dictionary = tactical_data.get("action_masks", {})
	var decision := _select_decision(observation, tactical_data, scripted_action, masks, delta)
	var legal_after_mask := decision.apply_masks(masks)
	if not legal_after_mask:
		_count_fallback("mask_corrected")
	if not HighLevelDecision.masks_have_any_action(masks):
		decision = HighLevelDecision.scripted_teacher(request_id)
		_count_fallback("empty_masks")
	_update_fallback_guards(observation, decision, delta)
	if fallback_timer > 0.0:
		decision = HighLevelDecision.scripted_teacher(request_id)
	current_decision = decision
	current_action = executor.execute(observation, decision, scripted_action, scripted_target, controlled_player, _decision_interval(), tactical_data)
	current_action.normalize_vectors(observation.aim_direction if observation != null else Vector2.RIGHT)
	_update_no_target_fire_guard(observation, current_action, decision, delta)
	_collect_diagnostics(decision, tactical_data)
	return current_action.copy()

func get_label() -> String:
	return "HYBRID"

func get_diagnostics() -> Dictionary:
	return last_diagnostics.duplicate(true)

func _decision_interval() -> float:
	var hz := config.decision_hz
	if ConfigDB != null:
		hz = float(ConfigDB.get_balance().agent_decision_hz)
	return 1.0 / maxf(hz, 1.0)

func _select_decision(observation: AgentObservation, tactical_data: Dictionary, scripted_action: PlayerAction, masks: Dictionary, delta: float) -> HighLevelDecision:
	if observation == null:
		_count_fallback("missing_observation")
		return HighLevelDecision.scripted_teacher(request_id)
	if fallback_timer > 0.0:
		fallback_timer = maxf(0.0, fallback_timer - delta)
		return HighLevelDecision.scripted_teacher(request_id)
	if _uses_remote_inference():
		var remote_decision = _remote_decision_step(observation, tactical_data)
		if remote_decision != null:
			return remote_decision
		_count_fallback("remote_pending_or_unavailable")
		return HighLevelDecision.scripted_teacher(request_id)
	return _local_prior_decision(observation, tactical_data, scripted_action, masks)

func _local_prior_decision(obs: AgentObservation, tactical_data: Dictionary, _scripted_action: PlayerAction, masks: Dictionary) -> HighLevelDecision:
	var decision = HighLevelDecision.scripted_teacher(request_id)
	var threat_info: Dictionary = tactical_data.get("threat_info", {})
	var high_threat := float(threat_info.get("threat_level", 0.0)) >= config.high_threat_threshold
	var any_enemy := bool(_mask_allows(masks.get("target_slot", []), HighLevelDecision.TargetSlot.BEST_VISIBLE_ENEMY)) or bool(_mask_allows(masks.get("target_slot", []), HighLevelDecision.TargetSlot.LOWEST_HEALTH_ENEMY))
	if any_enemy:
		decision.target_slot = HighLevelDecision.TargetSlot.SCRIPTED_TARGET
	else:
		decision.target_slot = HighLevelDecision.TargetSlot.NONE
		decision.fire_mode = HighLevelDecision.FireMode.HOLD_FIRE
	if high_threat and _mask_allows(masks.get("movement_mode", []), HighLevelDecision.MovementMode.EVADE_PROJECTILE):
		decision.movement_mode = HighLevelDecision.MovementMode.EVADE_PROJECTILE
	elif any_enemy:
		decision.movement_mode = HighLevelDecision.MovementMode.USE_SCRIPTED_MOVEMENT
	else:
		decision.movement_mode = HighLevelDecision.MovementMode.MOVE_TO_CENTER
	if any_enemy and obs.energy_ratio >= 0.18:
		decision.fire_mode = HighLevelDecision.FireMode.USE_SCRIPTED_FIRE_MODE
	elif any_enemy:
		decision.fire_mode = HighLevelDecision.FireMode.CONSERVATIVE
	decision.skill_mode = HighLevelDecision.SkillMode.USE_SCRIPTED_SKILL if any_enemy else HighLevelDecision.SkillMode.AUTO_DEFENSE
	decision.confidence = 1.0
	decision.apply_masks(masks)
	return decision

func _remote_decision_step(observation: AgentObservation, tactical_data: Dictionary):
	var received = _poll_model_response()
	if received != null:
		return received
	_expire_pending_request()
	if pending_request_id <= 0:
		_send_model_request(observation, tactical_data)
	if has_remote_decision:
		return last_remote_decision.copy()
	return null

func _send_model_request(observation: AgentObservation, tactical_data: Dictionary) -> bool:
	if not _ensure_connected_nonblocking():
		_warn_throttled("Hybrid tactical service unavailable")
		return false
	request_id += 1
	pending_request_id = request_id
	pending_request_started_ms = Time.get_ticks_msec()
	var features: PackedFloat32Array = tactical_data.get("features", PackedFloat32Array())
	var payload := {
		"cmd": "act_tactical",
		"protocol": PROTOCOL_VERSION,
		"request_id": pending_request_id,
		"player_id": observation.player_id,
		"model_id": _request_model_id(),
		"observation": observation.to_dict(),
		"tactical_features": Array(features),
		"action_masks": tactical_data.get("action_masks", {}),
		"schema_version": int(tactical_data.get("schema_version", TacticalFeatureBuilder.FEATURE_SCHEMA_VERSION)),
	}
	var err := peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())
	if err != OK:
		_disconnect()
		pending_request_id = 0
		_warn_throttled("Hybrid tactical request failed", {"error": err})
		return false
	return true

func _poll_model_response():
	if peer == null:
		return null
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			_disconnect()
		return null
	var available := peer.get_available_bytes()
	if available > 0:
		recv_buffer += peer.get_utf8_string(available)
	while recv_buffer.find("\n") >= 0:
		var index := recv_buffer.find("\n")
		var line := recv_buffer.substr(0, index).strip_edges()
		recv_buffer = recv_buffer.substr(index + 1)
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var data := parsed as Dictionary
		if str(data.get("type", "")) == "hello":
			continue
		if str(data.get("type", "")) == "error":
			_count_fallback("remote_error")
			_warn_throttled("Hybrid tactical service error", {"message": str(data.get("message", ""))})
			pending_request_id = 0
			continue
		if pending_request_id > 0 and int(data.get("request_id", -1)) != pending_request_id:
			continue
		var decision = _decision_from_response(data)
		if decision == null:
			pending_request_id = 0
			continue
		pending_request_id = 0
		inference_latency_ms = float(Time.get_ticks_msec() - pending_request_started_ms)
		if data.has("latency_ms"):
			inference_latency_ms = float(data.get("latency_ms", inference_latency_ms))
		last_remote_decision = decision.copy()
		has_remote_decision = true
		return decision
	return null

func _decision_from_response(response: Dictionary):
	if int(response.get("protocol", response.get("protocol_version", PROTOCOL_VERSION))) != PROTOCOL_VERSION:
		_count_fallback("protocol_error")
		return null
	if str(response.get("type", "")) != "tactical_decision":
		_count_fallback("invalid_response_type")
		return null
	var decision_data: Variant = response.get("decision", {})
	if typeof(decision_data) != TYPE_DICTIONARY:
		_count_fallback("missing_decision")
		return null
	var decision = HighLevelDecision.from_dict(decision_data)
	if not _decision_is_finite(decision):
		_count_fallback("non_finite_decision")
		return null
	var response_model_id := str(response.get("model_id", _request_model_id()))
	if not response_model_id.is_empty() and response_model_id != _request_model_id():
		_count_fallback("model_id_mismatch")
		return null
	return decision

func _expire_pending_request() -> void:
	if pending_request_id <= 0:
		return
	if Time.get_ticks_msec() - pending_request_started_ms <= timeout_ms:
		return
	_count_fallback("timeout")
	pending_request_id = 0

func _ensure_connected_nonblocking() -> bool:
	var now := Time.get_ticks_msec()
	if peer != null:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			peer.set_no_delay(true)
			return true
		if status == StreamPeerTCP.STATUS_CONNECTING:
			return false
		_disconnect()
	if now < next_connect_attempt_ms:
		return false
	next_connect_attempt_ms = now + RECONNECT_COOLDOWN_MS
	peer = StreamPeerTCP.new()
	var err := peer.connect_to_host(host, port)
	if err != OK:
		peer = null
		return false
	peer.poll()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.set_no_delay(true)
		return true
	return false

func _uses_remote_inference() -> bool:
	if model_id.begins_with(REMOTE_MODEL_PREFIX):
		return true
	if model_id.is_empty():
		return false
	return model_id != HybridAgentConfig.MODEL_ID

func _request_model_id() -> String:
	return model_id.substr(REMOTE_MODEL_PREFIX.length()) if model_id.begins_with(REMOTE_MODEL_PREFIX) else model_id

func _mask_allows(mask: Variant, index: int) -> bool:
	if mask is Array:
		return index >= 0 and index < mask.size() and bool(mask[index])
	if mask is PackedFloat32Array:
		return index >= 0 and index < mask.size() and bool(mask[index])
	return false

func _request_or_fallback(observation: AgentObservation, tactical_data: Dictionary, scripted_action: PlayerAction, masks: Dictionary, delta: float) -> HighLevelDecision:
	if observation == null:
		_count_fallback("missing_observation")
		return HighLevelDecision.scripted_teacher(request_id)
	if fallback_timer > 0.0:
		fallback_timer = maxf(0.0, fallback_timer - delta)
		return HighLevelDecision.scripted_teacher(request_id)
	var response := _request_model_decision(observation, tactical_data)
	if response.is_empty():
		_count_fallback("timeout_or_disconnected")
		return HighLevelDecision.scripted_teacher(request_id)
	if int(response.get("protocol", response.get("protocol_version", PROTOCOL_VERSION))) != PROTOCOL_VERSION:
		_count_fallback("protocol_error")
		return HighLevelDecision.scripted_teacher(request_id)
	if str(response.get("type", "")) != "tactical_decision":
		_count_fallback("invalid_response_type")
		return HighLevelDecision.scripted_teacher(request_id)
	var decision_data: Variant = response.get("decision", {})
	if typeof(decision_data) != TYPE_DICTIONARY:
		_count_fallback("missing_decision")
		return HighLevelDecision.scripted_teacher(request_id)
	var decision = HighLevelDecision.from_dict(decision_data)
	if not _decision_is_finite(decision):
		_count_fallback("non_finite_decision")
		return HighLevelDecision.scripted_teacher(request_id)
	if not str(response.get("model_id", model_id)).is_empty() and str(response.get("model_id", model_id)) != model_id:
		_count_fallback("model_id_mismatch")
		return HighLevelDecision.scripted_teacher(request_id)
	return decision

func _request_model_decision(observation: AgentObservation, tactical_data: Dictionary) -> Dictionary:
	if not _ensure_connected():
		_warn_throttled("Hybrid tactical service unavailable")
		return {}
	request_id += 1
	var start := Time.get_ticks_msec()
	var features: PackedFloat32Array = tactical_data.get("features", PackedFloat32Array())
	var payload := {
		"cmd": "act_tactical",
		"protocol": PROTOCOL_VERSION,
		"request_id": request_id,
		"player_id": observation.player_id,
		"model_id": model_id,
		"observation": observation.to_dict(),
		"tactical_features": Array(features),
		"action_masks": tactical_data.get("action_masks", {}),
		"schema_version": int(tactical_data.get("schema_version", TacticalFeatureBuilder.FEATURE_SCHEMA_VERSION)),
	}
	var err := peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())
	if err != OK:
		_disconnect()
		_warn_throttled("Hybrid tactical request failed", {"error": err})
		return {}
	var response := _read_response(request_id)
	inference_latency_ms = float(Time.get_ticks_msec() - start)
	if response.has("latency_ms"):
		inference_latency_ms = float(response.get("latency_ms", inference_latency_ms))
	return response

func _ensure_connected() -> bool:
	if peer != null:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return true
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
			return _wait_for_connection()
	_disconnect()
	peer = StreamPeerTCP.new()
	var err := peer.connect_to_host(host, port)
	if err != OK:
		peer = null
		return false
	return _wait_for_connection()

func _wait_for_connection() -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start <= timeout_ms:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			peer.set_no_delay(true)
			return true
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_disconnect()
			return false
		OS.delay_msec(1)
	return false

func _read_response(expected_request_id: int) -> Dictionary:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start <= timeout_ms:
		if peer == null:
			return {}
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_disconnect()
			return {}
		var available := peer.get_available_bytes()
		if available > 0:
			recv_buffer += peer.get_utf8_string(available)
		while recv_buffer.find("\n") >= 0:
			var index := recv_buffer.find("\n")
			var line := recv_buffer.substr(0, index).strip_edges()
			recv_buffer = recv_buffer.substr(index + 1)
			if line.is_empty():
				continue
			var parsed: Variant = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
			var data := parsed as Dictionary
			if str(data.get("type", "")) == "hello":
				continue
			if int(data.get("request_id", expected_request_id)) != expected_request_id:
				continue
			if str(data.get("type", "")) == "error":
				_warn_throttled("Hybrid tactical service error", {"message": str(data.get("message", ""))})
				return {}
			return data
		OS.delay_msec(1)
	return {}

func _disconnect() -> void:
	if peer != null:
		peer.disconnect_from_host()
	peer = null
	recv_buffer = ""

func _scripted_target(obs: AgentObservation) -> Dictionary:
	if obs == null:
		return {}
	var best: Dictionary = {}
	var best_score := INF
	for candidate in obs.other_players:
		if not bool(candidate.get("valid", false)) or bool(candidate.get("is_teammate", false)) or not bool(candidate.get("is_alive", false)):
			continue
		var rel := AgentObservation.dict_to_vec(candidate.get("relative_position", {}))
		var score := rel.length()
		if score < best_score:
			best_score = score
			best = candidate
	return best

func _update_fallback_guards(_obs: AgentObservation, decision: HighLevelDecision, delta: float) -> void:
	if decision.confidence < config.low_confidence_threshold:
		low_confidence_timer += delta
	else:
		low_confidence_timer = 0.0
	if low_confidence_timer >= config.low_confidence_window:
		fallback_timer = config.fallback_recover_window
		_count_fallback("low_confidence")
	var key := "%d:%d:%d:%d" % [decision.target_slot, decision.movement_mode, decision.fire_mode, decision.skill_mode]
	if key == previous_decision_key:
		repeated_decision_timer += delta
	else:
		repeated_decision_timer = 0.0
		previous_decision_key = key
	if repeated_decision_timer >= config.collapse_window and decision.fire_mode != HighLevelDecision.FireMode.HOLD_FIRE:
		fallback_timer = config.fallback_recover_window
		_count_fallback("decision_collapse")
		repeated_decision_timer = 0.0

func _update_no_target_fire_guard(obs: AgentObservation, action: PlayerAction, decision: HighLevelDecision, delta: float) -> void:
	if obs == null:
		return
	var target := feature_builder.select_target(obs, decision, _scripted_target(obs))
	if action.shoot and target.is_empty():
		no_target_fire_timer += delta
	else:
		no_target_fire_timer = 0.0
	if no_target_fire_timer >= config.no_target_fire_window:
		fallback_timer = config.fallback_recover_window
		_count_fallback("no_target_fire")
		no_target_fire_timer = 0.0

func _decision_is_finite(decision: HighLevelDecision) -> bool:
	return decision != null and is_finite(decision.confidence)

func _collect_diagnostics(decision: HighLevelDecision, tactical_data: Dictionary) -> void:
	var executor_diag := executor.get_diagnostics()
	last_diagnostics = executor_diag
	last_diagnostics["model_id"] = model_id
	last_diagnostics["inference_latency_ms"] = inference_latency_ms
	last_diagnostics["script_fallback"] = fallback_timer > 0.0 or decision.target_slot == HighLevelDecision.TargetSlot.SCRIPTED_TARGET
	last_diagnostics["fallback_counts"] = fallback_counts.duplicate()
	last_diagnostics["action_masks"] = tactical_data.get("action_masks", {})
	last_diagnostics["decision"] = decision.to_dict()

func _count_fallback(reason: String) -> void:
	fallback_counts[reason] = int(fallback_counts.get(reason, 0)) + 1

func _balance() -> GameBalance:
	if controlled_player != null:
		var value: Variant = controlled_player.get("balance")
		if value is GameBalance:
			return value
	if ConfigDB != null:
		return ConfigDB.get_balance()
	return GameBalance.default()

func _warn_throttled(message: String, context: Dictionary = {}) -> void:
	var now := Time.get_ticks_msec()
	if now - last_warning_ms < 1500:
		return
	last_warning_ms = now
	var full_context := context.duplicate()
	full_context["host"] = host
	full_context["port"] = port
	AppLog.warn(message, full_context)
