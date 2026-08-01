extends PlayerController
# 回放控制器，根据录制帧重放玩家动作。
class_name ReplayController

var frames: Array[Dictionary] = []
var cursor: int = 0

func load_frames(frame_data: Array[Dictionary]) -> void:
	frames = frame_data
	cursor = 0

func reset() -> void:
	cursor = 0

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	if cursor >= frames.size():
		return PlayerAction.new()
	var frame: Dictionary = frames[cursor]
	cursor += 1
	return PlayerAction.from_dict(frame.get("action", {}), observation.aim_direction)

func get_label() -> String:
	return "REPLAY"
