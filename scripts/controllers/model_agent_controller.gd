extends PlayerController
# Runtime model controller backed by the shared Python inference service.
class_name ModelAgentController

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8766
const DEFAULT_TIMEOUT_MS := 16
const PROTOCOL_VERSION := 1

var host: String = DEFAULT_HOST
var port: int = DEFAULT_PORT
var timeout_ms: int = DEFAULT_TIMEOUT_MS
var model_id: String = ""
var strength_profile: String = ""
var peer: StreamPeerTCP
var recv_buffer: String = ""
var request_id: int = 0
var current_action := PlayerAction.new()
var decision_timer: float = 0.0
var fallback: ScriptedAgentController
var last_warning_ms: int = -100000

func _init(config: AgentDifficultyConfig = null, seed: int = 0, host_value: String = DEFAULT_HOST, port_value: int = DEFAULT_PORT, timeout_value_ms: int = DEFAULT_TIMEOUT_MS, model_id_value: String = "") -> void:
	host = host_value
	port = port_value
	timeout_ms = max(timeout_value_ms, 1)
	model_id = model_id_value
	fallback = ScriptedAgentController.new(config, seed)

func set_strength_profile(profile: String) -> void:
	strength_profile = profile.strip_edges()

func reset() -> void:
	current_action = PlayerAction.new()
	decision_timer = 0.0
	recv_buffer = ""
	request_id = 0
	if fallback != null:
		fallback.reset()
	_disconnect()

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	decision_timer -= delta
	if decision_timer > 0.0:
		return current_action.copy()
	decision_timer = _decision_interval()
	var model_action := _request_model_action(observation)
	if model_action != null:
		current_action = model_action
	else:
		current_action = fallback.get_action(observation, delta) if fallback != null else PlayerAction.new()
	current_action.normalize_vectors(observation.aim_direction if observation != null else Vector2.RIGHT)
	return current_action.copy()

func get_label() -> String:
	return "MODEL"

func _decision_interval() -> float:
	var hz := 15.0
	if ConfigDB != null:
		hz = float(ConfigDB.get_balance().agent_decision_hz)
	return 1.0 / maxf(hz, 1.0)

func _request_model_action(observation: AgentObservation) -> PlayerAction:
	if observation == null:
		return null
	if not _ensure_connected():
		_warn_throttled("Model agent service unavailable")
		return null
	request_id += 1
	var payload := {
		"cmd": "act",
		"protocol": PROTOCOL_VERSION,
		"request_id": request_id,
		"player_id": observation.player_id,
		"observation": observation.to_dict(),
		"flat_observation": Array(observation.to_flat_array()),
	}
	if not model_id.is_empty():
		payload["model_id"] = model_id
	if not strength_profile.is_empty():
		payload["strength_profile"] = strength_profile
	var err := peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())
	if err != OK:
		_disconnect()
		_warn_throttled("Model agent request failed", {"error": err})
		return null
	var response := _read_response(request_id)
	if response.is_empty():
		return null
	var response_model_id := str(response.get("model_id", ""))
	if not model_id.is_empty() and not response_model_id.is_empty() and response_model_id != model_id:
		_warn_throttled("Model agent returned different model", {"requested": model_id, "received": response_model_id})
	var action_data: Variant = response.get("action", {})
	if typeof(action_data) != TYPE_DICTIONARY:
		_warn_throttled("Model agent response missing action")
		return null
	return PlayerAction.from_dict(action_data, observation.aim_direction)

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
				_warn_throttled("Model agent service error", {"message": str(data.get("message", ""))})
				return {}
			return data
		OS.delay_msec(1)
	return {}

func _disconnect() -> void:
	if peer != null:
		peer.disconnect_from_host()
	peer = null
	recv_buffer = ""

func _warn_throttled(message: String, context: Dictionary = {}) -> void:
	var now := Time.get_ticks_msec()
	if now - last_warning_ms < 1500:
		return
	last_warning_ms = now
	var full_context := context.duplicate()
	full_context["host"] = host
	full_context["port"] = port
	AppLog.warn(message, full_context)
