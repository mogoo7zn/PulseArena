extends PlayerController
# 本地玩家控制器，将键盘与手柄输入转换为角色动作。
class_name HumanController

var player_slot: int = 1
var last_aim: Vector2 = Vector2.RIGHT

func _init(slot: int = 1) -> void:
	player_slot = slot

func reset() -> void:
	last_aim = Vector2.RIGHT

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	if observation == null:
		var fallback := PlayerAction.new()
		fallback.aim = last_aim
		fallback.normalize_vectors(last_aim)
		return fallback
	var action := InputRegistry.build_human_action(player_slot, last_aim, observation.position, controlled_player)
	if action == null:
		action = PlayerAction.new()
		action.aim = last_aim
		action.normalize_vectors(last_aim)
	last_aim = action.aim
	# Best-effort human_eval recording (only when an agent is in the match).
	if HumanEvalRecorder != null and HumanEvalRecorder.is_recording():
		HumanEvalRecorder.record_step(observation, action)
	return action

func get_label() -> String:
	return "HUMAN"
