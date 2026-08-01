extends Node
class_name TrainingServer

const DEFAULT_PORT := 8765

var bridge := EnvironmentBridge.new()
var server := TCPServer.new()
var peer: StreamPeerTCP
var recv_buffer := ""
var port: int = DEFAULT_PORT
var pending_reset_response := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(bridge)
	port = _get_int_arg("--port", DEFAULT_PORT)
	var err := server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("TrainingServer failed to listen on port %d" % port)
		get_tree().quit(2)
		return
	print(JSON.stringify({"training_server": "listening", "host": "127.0.0.1", "port": port}))

func _process(_delta: float) -> void:
	if peer == null and server.is_connection_available():
		peer = server.take_connection()
		peer.set_no_delay(true)
		_send({"type": "hello", "protocol": 1, "port": port})
	if peer == null:
		return
	if pending_reset_response and bridge.arena != null and bridge.arena.started:
		get_tree().paused = true
		pending_reset_response = false
		_send(_snapshot("reset_ok"))
	_read_commands()

func _read_commands() -> void:
	var available := peer.get_available_bytes()
	if available <= 0:
		return
	recv_buffer += peer.get_utf8_string(available)
	while recv_buffer.find("\n") >= 0:
		var index := recv_buffer.find("\n")
		var line := recv_buffer.substr(0, index).strip_edges()
		recv_buffer = recv_buffer.substr(index + 1)
		if not line.is_empty():
			_handle_command(line)

func _handle_command(line: String) -> void:
	var data: Variant = JSON.parse_string(line)
	if typeof(data) != TYPE_DICTIONARY:
		_send({"type": "error", "message": "Invalid JSON command"})
		return
	var cmd := str(data.get("cmd", ""))
	match cmd:
		"reset":
			_handle_reset(data)
		"observe":
			_send(_snapshot("observe"))
		"observe_tactical":
			_send(_tactical_snapshot("observe_tactical"))
		"step":
			_handle_step(data)
		"step_tactical":
			_handle_tactical_step(data)
		"close":
			_send({"type": "closed"})
			get_tree().quit(0)
		_:
			_send({"type": "error", "message": "Unknown command: %s" % cmd})

func _handle_reset(data: Dictionary) -> void:
	get_tree().paused = false
	var config_data: Variant = data.get("config", {})
	if typeof(config_data) != TYPE_DICTIONARY:
		_send({"type": "error", "message": "reset config must be a dictionary"})
		return
	var config := MatchConfig.from_dict(config_data)
	config.headless = true
	bridge.reset_environment(config)
	pending_reset_response = true

func _handle_step(data: Dictionary) -> void:
	if bridge.arena == null:
		_send({"type": "error", "message": "Environment has not been reset"})
		return
	var actions: Variant = data.get("actions", {})
	if typeof(actions) == TYPE_DICTIONARY:
		bridge.apply_actions(actions)
	var ticks := clampi(int(data.get("ticks", 1)), 1, 600)
	for _i in range(ticks):
		bridge.step()
		if bridge.get_terminated():
			break
	_send(_snapshot("step"))

func _handle_tactical_step(data: Dictionary) -> void:
	if bridge.arena == null:
		_send({"type": "error", "message": "Environment has not been reset"})
		return
	var decisions: Variant = data.get("decisions", {})
	if typeof(decisions) != TYPE_DICTIONARY:
		_send({"type": "error", "message": "step_tactical decisions must be a dictionary"})
		return
	if not bridge.apply_tactical_decisions(decisions):
		_send({"type": "error", "message": bridge.get_last_tactical_error()})
		return
	var ticks := clampi(int(data.get("ticks", 1)), 1, 600)
	for _i in range(ticks):
		bridge.step()
		if bridge.get_terminated():
			break
	_send(_tactical_snapshot("step_tactical"))

func _snapshot(response_type: String) -> Dictionary:
	return {
		"type": response_type,
		"observations": bridge.get_observations(),
		"rewards": bridge.get_rewards(),
		"terminated": bridge.get_terminated(),
		"truncated": bridge.get_truncated(),
		"info": bridge.get_info(),
	}

func _tactical_snapshot(response_type: String) -> Dictionary:
	var snapshot := bridge.get_tactical_snapshot()
	snapshot["type"] = response_type
	return snapshot

func _send(payload: Dictionary) -> void:
	if peer == null:
		return
	var text := JSON.stringify(payload) + "\n"
	peer.put_data(text.to_utf8_buffer())

func _get_int_arg(prefix: String, fallback: int) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix + "="):
			return int(arg.get_slice("=", 1))
	return fallback
