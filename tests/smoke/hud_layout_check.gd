extends Node
# HUD 布局 smoke 测试，检查结束菜单与状态面板不会跑出屏幕。

const HUD_SCENE: PackedScene = preload("res://scenes/ui/GameHUD.tscn")

func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	call_deferred("_run")

func _run() -> void:
	var hud := HUD_SCENE.instantiate() as GameHUD
	get_tree().root.add_child(hud)
	await get_tree().process_frame
	await get_tree().process_frame
	hud.show_result({
		"winner_player_id": 0,
		"standings": [
			{"label": "Agent 1", "team_id": 0, "kills": 1, "deaths": 0, "score": 5},
			{"label": "Agent 2", "team_id": 1, "kills": 0, "deaths": 1, "score": 0},
		],
	})
	await get_tree().process_frame
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(get_window().size))
	var panel_rect := Rect2(hud.result_panel.global_position, hud.result_panel.size)
	if not viewport_rect.encloses(panel_rect):
		_fail("result panel outside viewport: %s in %s" % [panel_rect, viewport_rect])
		return
	var main_menu_button := _find_button(hud, "Main Menu")
	if main_menu_button == null:
		_fail("Main Menu button not found")
		return
	var button_rect := Rect2(main_menu_button.global_position, main_menu_button.size)
	if not viewport_rect.encloses(button_rect):
		_fail("Main Menu button outside viewport: %s in %s" % [button_rect, viewport_rect])
		return
	print("PASS: HUD layout check")
	get_tree().quit(0)

func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null

func _fail(message: String) -> void:
	push_error("FAIL: " + message)
	get_tree().quit(1)
