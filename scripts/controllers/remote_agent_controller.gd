extends PlayerController
# Receives actions supplied by an external trainer or environment bridge.
class_name RemoteAgentController

var current_action := PlayerAction.new()

func reset() -> void:
	current_action = PlayerAction.new()

func set_action(action: PlayerAction) -> void:
	current_action = action.copy() if action != null else PlayerAction.new()

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	return current_action.copy()

func get_label() -> String:
	return "REMOTE"
