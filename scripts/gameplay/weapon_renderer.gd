extends RefCounted
# 武器绘制器，根据角色朝向与武器状态渲染枪口和持枪姿态。
class_name WeaponRenderer

func draw_weapon(canvas: CanvasItem, hand_position: Vector2, aim: Vector2, team_color: Color, recoil: float, muzzle_flash: float, empty_flash: float, alpha: float) -> void:
	var dir := aim.normalized() if aim.length_squared() > 0.001 else Vector2.RIGHT
	var side := dir.orthogonal()
	var recoil_offset := clampf(recoil, 0.0, 1.0) * 6.0
	var stock := hand_position - dir * (7.0 + recoil_offset)
	var barrel := hand_position + dir * (28.0 - recoil_offset)
	var accent := team_color.lightened(0.2)
	_draw_capsule(canvas, stock - side * 1.5, barrel, 5.5, Color("#111827", alpha), Color("#DCE7F7", 0.18 * alpha))
	_draw_capsule(canvas, hand_position + side * 3.0, barrel + dir * 5.0, 2.0, accent, Color.TRANSPARENT)
	canvas.draw_line(stock - side * 6.0, stock + side * 6.0, Color("#263248", alpha), 4.0)
	if muzzle_flash > 0.0:
		var flash_alpha := clampf(muzzle_flash / 0.09, 0.0, 1.0) * alpha
		var tip := barrel + dir * 7.0
		canvas.draw_polygon(PackedVector2Array([
			barrel + side * 5.0,
			tip + dir * 12.0,
			barrel - side * 5.0,
		]), PackedColorArray([
			Color("#FFE7A3", flash_alpha),
			Color("#63D7C4", flash_alpha * 0.75),
			Color("#FFFFFF", flash_alpha * 0.85),
		]))
		canvas.draw_circle(tip, 4.5, Color("#F1F5FA", flash_alpha * 0.85))
	elif empty_flash > 0.0:
		var click_alpha := clampf(empty_flash / 0.16, 0.0, 1.0) * alpha
		canvas.draw_arc(barrel + dir * 4.0, 6.0, -0.65, 0.65, 10, Color("#F07178", click_alpha), 1.6)

func _draw_capsule(canvas: CanvasItem, a: Vector2, b: Vector2, width: float, fill: Color, outline: Color) -> void:
	if outline.a > 0.0:
		canvas.draw_line(a, b, outline, width + 2.0)
		canvas.draw_circle(a, width * 0.5 + 1.0, outline)
		canvas.draw_circle(b, width * 0.5 + 1.0, outline)
	canvas.draw_line(a, b, fill, width)
	canvas.draw_circle(a, width * 0.5, fill)
	canvas.draw_circle(b, width * 0.5, fill)
