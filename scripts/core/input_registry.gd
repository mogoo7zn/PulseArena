extends Node
# 输入注册服务，集中创建玩家、菜单和调试操作的默认输入映射。
class_name InputRegistryService

const PLAYER_1: int = 1
const PLAYER_2: int = 2

const ACTIONS: Dictionary = {
	"pause": [],
	"return_menu": [],
	"toggle_debug_overlay": [],
	"p1_move_up": [],
	"p1_move_down": [],
	"p1_move_left": [],
	"p1_move_right": [],
	"p1_shoot": [],
	"p1_dash": [],
	"p1_shield": [],
	"p2_move_up": [],
	"p2_move_down": [],
	"p2_move_left": [],
	"p2_move_right": [],
	"p2_aim_up": [],
	"p2_aim_down": [],
	"p2_aim_left": [],
	"p2_aim_right": [],
	"p2_shoot": [],
	"p2_dash": [],
	"p2_shield": [],
}

func _ready() -> void:
	register_defaults()

func register_defaults() -> void:
	for action in ACTIONS.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		else:
			InputMap.action_erase_events(action)
	_add_key("pause", KEY_ESCAPE)
	_add_key("return_menu", KEY_BACKSPACE)
	_add_key("toggle_debug_overlay", KEY_F3)
	_add_key("p1_move_up", KEY_W)
	_add_key("p1_move_down", KEY_S)
	_add_key("p1_move_left", KEY_A)
	_add_key("p1_move_right", KEY_D)
	_add_mouse_button("p1_shoot", MOUSE_BUTTON_LEFT)
	_add_key("p1_dash", KEY_SPACE)
	_add_mouse_button("p1_shield", MOUSE_BUTTON_RIGHT)
	_add_key("p2_move_up", KEY_UP)
	_add_key("p2_move_down", KEY_DOWN)
	_add_key("p2_move_left", KEY_LEFT)
	_add_key("p2_move_right", KEY_RIGHT)
	_add_key("p2_aim_up", KEY_I)
	_add_key("p2_aim_down", KEY_K)
	_add_key("p2_aim_left", KEY_J)
	_add_key("p2_aim_right", KEY_L)
	_add_key("p2_shoot", KEY_CTRL)
	_add_key("p2_dash", KEY_SHIFT)
	_add_key("p2_shield", KEY_ENTER)
	_add_key("p2_shield", KEY_KP_0)

func build_human_action(player_slot: int, fallback_aim: Vector2, self_position: Vector2, aim_node: Node2D) -> PlayerAction:
	var action := PlayerAction.new()
	var prefix := "p%d_" % player_slot
	action.move = _vector_from_actions(prefix + "move_left", prefix + "move_right", prefix + "move_up", prefix + "move_down")
	if player_slot == PLAYER_1 and aim_node != null:
		var mouse_direction := aim_node.get_global_mouse_position() - self_position
		action.aim = mouse_direction.normalized() if mouse_direction.length_squared() > 0.001 else fallback_aim
	else:
		action.aim = _vector_from_actions(prefix + "aim_left", prefix + "aim_right", prefix + "aim_up", prefix + "aim_down")
		if action.aim.length_squared() <= 0.001:
			action.aim = fallback_aim
	action.shoot = Input.is_action_pressed(prefix + "shoot")
	action.dash = Input.is_action_just_pressed(prefix + "dash")
	action.shield = Input.is_action_just_pressed(prefix + "shield")
	action.normalize_vectors(fallback_aim)
	return action

func pause_pressed() -> bool:
	return Input.is_action_just_pressed("pause")

func return_menu_pressed() -> bool:
	return Input.is_action_just_pressed("return_menu")

func _vector_from_actions(left: String, right: String, up: String, down: String) -> Vector2:
	var x := Input.get_action_strength(right) - Input.get_action_strength(left)
	var y := Input.get_action_strength(down) - Input.get_action_strength(up)
	var v := Vector2(x, y)
	return v.normalized() if v.length_squared() > 1.0 else v

func _add_key(action: String, keycode: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)

func _add_mouse_button(action: String, button: MouseButton) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	InputMap.action_add_event(action, event)
