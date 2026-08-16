extends RefCounted
# 回放管理器，记录、序列化和恢复比赛输入帧。
class_name ReplayManager

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")
const TacticalFeatureBuilder = preload("res://scripts/agents/tactical_feature_builder.gd")
const TacticalTeacher = preload("res://scripts/agents/tactical_teacher.gd")

var enabled: bool = false
var match_id: String = ""
var random_seed: int = 0
var file: FileAccess
var replay_schema: String = "raw_replay_v1"
var tactical_config := HybridAgentConfig.new()

func start(config: MatchConfig) -> void:
	enabled = config.record_replay
	random_seed = config.random_seed
	replay_schema = HybridAgentConfig.REPLAY_SCHEMA if config.agent_controller == MatchConfig.AGENT_CONTROLLER_HYBRID else "raw_replay_v1"
	tactical_config = HybridAgentConfig.for_profile(config.reward_profile_id)
	match_id = "%s_%d" % [Time.get_datetime_string_from_system().replace(":", "-"), random_seed]
	if not enabled:
		return
	var replay_dir := _resolve_replay_dir(config)
	DirAccess.make_dir_recursive_absolute(replay_dir)
	var suffix := ".hybrid_v2.jsonl" if replay_schema == HybridAgentConfig.REPLAY_SCHEMA else ".jsonl"
	var path := replay_dir.path_join("%s%s" % [match_id, suffix])
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		enabled = false
		AppLog.warn("Replay file could not be opened", {"path": path})

func _resolve_replay_dir(config: MatchConfig) -> String:
	if config.replay_output_dir.is_empty():
		return ProjectSettings.globalize_path("res://training/data/replays") if config.headless else ProjectSettings.globalize_path("user://replays")
	if config.replay_output_dir.begins_with("res://") or config.replay_output_dir.begins_with("user://"):
		return ProjectSettings.globalize_path(config.replay_output_dir)
	return ProjectSettings.globalize_path("res://").path_join(config.replay_output_dir)

func record_decision(timestamp: float, player: ArenaPlayer, observation: AgentObservation, action: PlayerAction, score: int, arena_map: Node = null) -> void:
	if not enabled or file == null:
		return
	var row: Dictionary = {
		"replay_schema": replay_schema,
		"timestamp": timestamp,
		"match_id": match_id,
		"random_seed": random_seed,
		"player_id": player.player_id,
		"observation": observation.to_dict(),
		"action": action.to_dict(),
		"position": AgentObservation.vec_to_dict(player.global_position),
		"velocity": AgentObservation.vec_to_dict(player.velocity),
		"health": player.health,
		"energy": player.energy,
		"score": score,
	}
	if replay_schema == HybridAgentConfig.REPLAY_SCHEMA:
		var builder := TacticalFeatureBuilder.new()
		var tactical := builder.build(observation, player.balance, tactical_config, null, arena_map)
		tactical["engagement_profile_id"] = tactical_config.engagement_profile_id
		var diagnostics = player.controller.get_diagnostics() if player.controller != null and player.controller.has_method("get_diagnostics") else {}
		var executed_decision: Dictionary = diagnostics.get("decision", {})
		var teacher_label := TacticalTeacher.new().build_label(observation, tactical, player.balance, diagnostics)
		row["episode_id"] = match_id
		row["map_id"] = observation.map_id
		row["mode_id"] = observation.game_mode_id
		row["observation_schema_version"] = HybridAgentConfig.OBSERVATION_SCHEMA_VERSION
		row["tactical_features"] = Array(tactical.get("features", PackedFloat32Array()))
		row["action_masks"] = tactical.get("action_masks", {})
		row["teacher_decision"] = teacher_label.get("decision", HighLevelDecision.scripted_teacher().to_dict())
		row["teacher_label_version"] = int(teacher_label.get("teacher_label_version", 0))
		row["label_source"] = str(teacher_label.get("label_source", "unknown"))
		row["label_reason"] = str(teacher_label.get("label_reason", ""))
		row["label_weight"] = float(teacher_label.get("label_weight", 1.0))
		row["label_confidence"] = float(teacher_label.get("label_confidence", 1.0))
		row["model_decision"] = executed_decision if not bool(diagnostics.get("script_fallback", false)) else {}
		row["executed_decision"] = executed_decision
		row["final_player_action"] = action.to_dict()
		row["safety_override"] = bool(diagnostics.get("safety_override", false))
		row["fallback_used"] = bool(diagnostics.get("script_fallback", false))
		row["reward_components"] = {}
		row["outcome"] = {}
		row["diagnostic_metrics"] = diagnostics
	file.store_line(JSON.stringify(row))

func stop() -> void:
	if file != null:
		file.flush()
		file.close()
	file = null
	enabled = false
