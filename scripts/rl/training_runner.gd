extends Node
# Headless training smoke runner for scripted baselines and staged curriculum checks.
class_name TrainingRunner

const MAPS := [
	MatchConfig.MAP_DUNGEON,
	MatchConfig.MAP_SKY_CITY,
	MatchConfig.MAP_JUNGLE,
	MatchConfig.MAP_MIST_WORLD,
]

var bridge := EnvironmentBridge.new()
var matches_to_run: int = 1
var completed: int = 0
var base_seed: int = 1234
var seconds: float = 10.0
var agents: int = 4
var mode: String = MatchConfig.MODE_FFA
var map_arg: String = MatchConfig.MAP_DUNGEON
var difficulty: String = "normal"
var agent_controller: String = MatchConfig.AGENT_CONTROLLER_SCRIPTED
var agent_model_host: String = "127.0.0.1"
var agent_model_port: int = 8766
var agent_model_timeout_ms: int = 16
var agent_model_id: String = ""
var stage_id: String = "ad_hoc"
var profile_id: String = "default"
var record_replay: bool = false
var visual_mode: bool = false
var summaries: Array[Dictionary] = []

func _ready() -> void:
	add_child(bridge)
	var args := OS.get_cmdline_user_args()
	matches_to_run = maxi(1, _get_int_arg(args, "--matches", 1))
	base_seed = _get_int_arg(args, "--seed", 1234)
	seconds = maxf(1.0, _get_float_arg(args, "--seconds", 10.0))
	agents = clampi(_get_int_arg(args, "--agents", 4), 1, 4)
	mode = _get_string_arg(args, "--mode", MatchConfig.MODE_FFA)
	map_arg = _get_string_arg(args, "--map", MatchConfig.MAP_DUNGEON)
	difficulty = _get_string_arg(args, "--difficulty", "normal")
	agent_controller = _get_string_arg(args, "--agent-controller", MatchConfig.AGENT_CONTROLLER_SCRIPTED)
	agent_model_host = _get_string_arg(args, "--agent-model-host", "127.0.0.1")
	agent_model_port = _get_int_arg(args, "--agent-model-port", 8766)
	agent_model_timeout_ms = _get_int_arg(args, "--agent-model-timeout-ms", 16)
	agent_model_id = _get_string_arg(args, "--agent-model-id", "")
	stage_id = _get_string_arg(args, "--stage", "ad_hoc")
	profile_id = _get_string_arg(args, "--profile", "default")
	record_replay = _get_bool_arg(args, "--record-replay", false)
	visual_mode = _get_bool_arg(args, "--visual", false)
	_start_next_match()

func _physics_process(delta: float) -> void:
	if not bridge.get_terminated():
		return
	summaries.append({
		"match_index": completed,
		"profile": profile_id,
		"stage": stage_id,
		"map": _map_for_match(completed),
		"seed": base_seed + completed,
		"rewards": bridge.get_rewards(),
		"info": bridge.get_info(),
	})
	completed += 1
	if completed >= matches_to_run:
		print(JSON.stringify({
			"training_runner": "finished",
			"profile": profile_id,
			"stage": stage_id,
			"matches": completed,
			"summaries": summaries,
		}))
		get_tree().quit(0)
		return
	_start_next_match()

func _start_next_match() -> void:
	var config := _make_match_config(completed)
	bridge.reset_environment(config)

func _make_match_config(match_index: int) -> MatchConfig:
	var config := MatchConfig.new()
	config.mode = mode
	config.human_player_count = 0
	config.agent_count = agents
	config.team_mode = mode == MatchConfig.MODE_TEAM_2V2
	config.friendly_fire = not config.team_mode
	config.time_limit = seconds
	config.score_limit = 0
	config.map_id = _map_for_match(match_index)
	config.agent_difficulty = difficulty
	config.agent_controller = agent_controller
	config.agent_model_host = agent_model_host
	config.agent_model_port = agent_model_port
	config.agent_model_timeout_ms = agent_model_timeout_ms
	config.agent_model_id = agent_model_id
	config.random_seed = base_seed + match_index
	config.headless = not visual_mode
	config.record_replay = record_replay
	config.training_fast_mode = not record_replay
	return config

func _map_for_match(match_index: int) -> String:
	if map_arg == "all" or map_arg == "random":
		return MAPS[(base_seed + match_index) % MAPS.size()]
	return map_arg

func _get_int_arg(args: PackedStringArray, prefix: String, fallback: int) -> int:
	for arg in args:
		if arg.begins_with(prefix + "="):
			return int(arg.get_slice("=", 1))
	return fallback

func _get_float_arg(args: PackedStringArray, prefix: String, fallback: float) -> float:
	for arg in args:
		if arg.begins_with(prefix + "="):
			return float(arg.get_slice("=", 1))
	return fallback

func _get_string_arg(args: PackedStringArray, prefix: String, fallback: String) -> String:
	for arg in args:
		if arg.begins_with(prefix + "="):
			return arg.get_slice("=", 1)
	return fallback

func _get_bool_arg(args: PackedStringArray, prefix: String, fallback: bool) -> bool:
	for arg in args:
		if arg == prefix:
			return true
		if arg.begins_with(prefix + "="):
			var value := arg.get_slice("=", 1).to_lower()
			return value == "1" or value == "true" or value == "yes" or value == "on"
	return fallback
