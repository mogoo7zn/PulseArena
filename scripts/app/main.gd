extends Node
# 主场景控制器，负责在主菜单、竞技场和训练模式之间切换。
class_name PulseArenaMain

const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/menu/MainMenu.tscn")
const ARENA_SCENE: PackedScene = preload("res://scenes/arena/ArenaRoot.tscn")
const TRAINING_SERVER_SCRIPT = preload("res://scripts/rl/training_server.gd")

var current_scene: Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameFlowManager.match_requested.connect(_on_match_requested)
	GameFlowManager.main_menu_requested.connect(_on_main_menu_requested)
	if _has_user_arg("--training-server"):
		_start_training_server_from_args()
	elif _has_user_arg("--training"):
		_start_training_from_args()
	else:
		GameFlowManager.enter_main_menu()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if GameFlowManager.current_state == GameFlowManagerService.GameState.PLAYING:
			GameFlowManager.pause_match()
		elif GameFlowManager.current_state == GameFlowManagerService.GameState.PAUSED:
			GameFlowManager.resume_match()
	if event.is_action_pressed("return_menu") and GameFlowManager.is_match_active():
		get_tree().paused = false
		GameFlowManager.enter_main_menu()

func show_scene(scene: PackedScene) -> Node:
	if current_scene != null:
		current_scene.queue_free()
	current_scene = scene.instantiate()
	add_child(current_scene)
	return current_scene

func _on_main_menu_requested() -> void:
	show_scene(MAIN_MENU_SCENE)

func _on_match_requested(config: MatchConfig) -> void:
	var arena := show_scene(ARENA_SCENE)
	if arena.has_method("configure"):
		arena.configure(config)

func _start_training_from_args() -> void:
	if current_scene != null:
		current_scene.queue_free()
	current_scene = TrainingRunner.new()
	add_child(current_scene)

func _start_training_server_from_args() -> void:
	if current_scene != null:
		current_scene.queue_free()
	current_scene = TRAINING_SERVER_SCRIPT.new()
	add_child(current_scene)

func _has_user_arg(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)

func _get_int_arg(prefix: String, fallback: int) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix + "="):
			return int(arg.get_slice("=", 1))
	return fallback

func _get_string_arg(prefix: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix + "="):
			return arg.get_slice("=", 1)
	return fallback
