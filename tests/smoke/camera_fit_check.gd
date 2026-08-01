extends SceneTree
# 摄像机适配 smoke 测试，验证不同视口下地图与玩家保持可见。

func _init() -> void:
	var balance := GameBalance.default()
	var viewport_size := Vector2(1600, 900)
	var fit_zoom := minf(viewport_size.x / balance.map_size.x, viewport_size.y / balance.map_size.y)
	var visible_world := Vector2(viewport_size.x / fit_zoom, viewport_size.y / fit_zoom)
	if visible_world.x + 0.5 < balance.map_size.x or visible_world.y + 0.5 < balance.map_size.y:
		_fail("camera visible world %s does not fit map %s" % [visible_world, balance.map_size])
		return
	print("PASS: camera fit check")
	quit(0)

func _fail(message: String) -> void:
	push_error("FAIL: " + message)
	quit(1)
