extends Node
# 应用启动占位节点，负责承载项目级初始化入口。
class_name PulseArenaBootstrap

func _ready() -> void:
	GameFlowManager.enter_main_menu()
