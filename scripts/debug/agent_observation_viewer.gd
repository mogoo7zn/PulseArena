extends Control
# 智能体观测查看器，用于检查训练观测向量和调试 AI 输入。
class_name AgentObservationViewer

var text: TextEdit

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	text = TextEdit.new()
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.editable = false
	text.text = "Agent observation viewer placeholder.\nRun a match and attach observations through EnvironmentBridge."
	add_child(text)
