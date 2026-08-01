extends "res://scripts/controllers/model_agent_controller.gd"
# Compatibility alias for older references. Runtime inference now uses ModelAgentController.
class_name ONNXAgentController

var model_path: String = ""

func get_label() -> String:
	return "MODEL"
