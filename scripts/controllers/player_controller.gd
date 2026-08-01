extends RefCounted
# 玩家控制器基类，定义人类、AI、回放和远程控制器的统一输入接口。
class_name PlayerController

var controlled_player: Node2D

func set_controlled_player(player_node: Node2D) -> void:
	controlled_player = player_node

func reset() -> void:
	pass

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	return PlayerAction.new()

func get_label() -> String:
	return "CTRL"
