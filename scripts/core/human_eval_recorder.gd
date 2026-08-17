extends Node
# Records human gameplay to hybrid_replay_v2 JSONL for stage 6 continual BC.
#
# Writes one line per tactical decision the local player makes, under
# training/data/replays/human_eval_continual/<YYYYMMDD>_<episode>.hybrid_v2.jsonl
# (or whatever path MatchConfig.human_eval_replay_dir points at). Schema is
# identical to the BC trainer's input so the same loader can consume both.
#
# Registered as an autoload singleton in project.godot under the name
# HumanEvalRecorder; the class_name is intentionally omitted so Godot does
# not complain about hiding the autoload of the same name.

const DEFAULT_ROOT := "training/data/replays/human_eval_continual"

var _current_path: String = ""
var _current_episode: String = ""
var _current_difficulty: String = ""
var _current_map_id: String = ""
var _step_index: int = 0
var _file: FileAccess
var _enabled: bool = false

func _ready() -> void:
	GameEvents.match_started.connect(_on_match_started)
	GameEvents.match_finished.connect(_on_match_finished)

func is_recording() -> bool:
	return _enabled

func _on_match_started(config: MatchConfig) -> void:
	if config.human_player_count <= 0:
		return
	if config.agent_controller == MatchConfig.AGENT_CONTROLLER_SCRIPTED:
		return
	var root := DEFAULT_ROOT
	if not config.human_eval_replay_dir.is_empty():
		root = config.human_eval_replay_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-").replace("T", "_").substr(0, 19)
	_current_episode = "%s_%s_s%d" % [stamp, config.map_id, int(config.random_seed)]
	_current_difficulty = config.agent_difficulty
	_current_map_id = config.map_id
	_current_path = root + "/" + _current_episode + ".hybrid_v2.jsonl"
	_step_index = 0
	var abs := ProjectSettings.globalize_path(_current_path)
	_file = FileAccess.open(abs, FileAccess.WRITE)
	if _file == null:
		push_error("HumanEvalRecorder: failed to open %s" % abs)
		_enabled = false
		return
	_enabled = true
	print("[HumanEval] recording to %s" % abs)

func record_step(observation: AgentObservation, action: PlayerAction, outcome: Dictionary = {}) -> void:
	if not _enabled or _file == null:
		return
	_step_index += 1
	var row := {
		"schema_version": 2,
		"replay_schema": "hybrid_replay_v2",
		"episode_id": _current_episode,
		"match_id": _current_episode,
		"player_id": observation.player_id if observation != null else 0,
		"map_id": _current_map_id,
		"mode_id": 0,
		"difficulty": _current_difficulty,
		"timestamp": float(Time.get_ticks_msec()) / 1000.0,
		"step_index": _step_index,
		"action": action.to_dict() if action != null else {},
		"observation_schema_version": 2,
		"observation": observation.to_dict() if observation != null else {},
		"outcome": outcome,
		"label_source": "human_playthrough",
		"teacher_label_version": "human_eval_v1",
		"label_weight": 1.0,
	}
	_file.store_line(JSON.stringify(row))

func _on_match_finished(_result: Dictionary) -> void:
	if not _enabled:
		return
	if _file != null:
		_file.close()
		print("[HumanEval] saved %d steps to %s" % [_step_index, _current_path])
	_file = null
	_enabled = false
	_step_index = 0
	_current_path = ""
	_current_episode = ""
