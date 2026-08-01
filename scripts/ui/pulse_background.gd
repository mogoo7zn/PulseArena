extends Control
# 菜单动态背景，绘制脉冲网格和能量流动效果。
class_name PulseBackground

var particles: Array[Vector2] = []
var speeds: Array[float] = []
var phases: Array[float] = []
var anim_time: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = 4128
	for i in range(120):
		particles.append(Vector2(rng.randf(), rng.randf()))
		speeds.append(rng.randf_range(0.01, 0.035))
		phases.append(rng.randf_range(0.0, TAU))
	set_process(true)

func _process(delta: float) -> void:
	anim_time += delta
	for i in range(particles.size()):
		particles[i].y += speeds[i] * delta
		particles[i].x += sin(anim_time * 0.45 + phases[i]) * delta * 0.004
		particles[i].x = fposmod(particles[i].x, 1.0)
		if particles[i].y > 1.0:
			particles[i].y = 0.0
	queue_redraw()

func _draw() -> void:
	var full := Rect2(Vector2.ZERO, size)
	_draw_gradient_rect(full, Color("#050914"), Color("#111827"), Color("#071A22"), Color("#17101F"))
	_draw_energy_bands()
	var arena := Rect2(size * Vector2(0.08, 0.13), size * Vector2(0.84, 0.72))
	var floor := _arena_plane(arena)
	var floor_shadow := PackedVector2Array()
	for p in floor:
		floor_shadow.append(p + Vector2(0, 22))
	draw_polygon(floor_shadow, _fill_colors(floor_shadow.size(), Color("#000000", 0.28)))
	draw_polygon(floor, _fill_colors(floor.size(), Color("#0D1A27", 0.92)))
	_draw_closed_polyline(floor, Color("#68D9D0", 0.28), 2.0)
	_draw_closed_polyline(floor, Color("#F2D36B", 0.12), 5.0)
	var grid := Color("#7DDCD2", 0.10)
	for i in range(1, 8):
		var t := float(i) / 8.0
		draw_line(floor[0].lerp(floor[3], t), floor[1].lerp(floor[2], t), grid, 1)
	for i in range(1, 6):
		var t := float(i) / 6.0
		draw_line(floor[0].lerp(floor[1], t), floor[3].lerp(floor[2], t), grid, 1)
	_draw_menu_pulses(arena)
	_draw_preview_wall(arena, Vector2(0.45, 0.40), Vector2(0.06, 0.29), Color("#5B4A39"))
	_draw_preview_wall(arena, Vector2(0.34, 0.50), Vector2(0.25, 0.045), Color("#5B4A39"))
	_draw_preview_wall(arena, Vector2(0.12, 0.18), Vector2(0.14, 0.04), Color("#E9F8FF"))
	_draw_preview_wall(arena, Vector2(0.72, 0.76), Vector2(0.16, 0.04), Color("#466038"))
	_draw_preview_actor(_project(arena, Vector2(0.25, 0.56)), Color("#6EA8FE"))
	_draw_preview_actor(_project(arena, Vector2(0.72, 0.36)), Color("#63D7C4"))
	_draw_preview_actor(_project(arena, Vector2(0.56, 0.70)), Color("#A78BFA"))
	draw_line(_project(arena, Vector2(0.28, 0.55)), _project(arena, Vector2(0.65, 0.39)), Color("#63D7C4", 0.22), 2.5)
	draw_circle(_project(arena, Vector2(0.66, 0.39)), 4.5, Color("#F1F5FA", 0.58))
	for i in range(particles.size()):
		var p := particles[i] * size
		var twinkle := 0.5 + 0.5 * sin(anim_time * (1.2 + speeds[i] * 12.0) + phases[i])
		draw_circle(p, 0.9 + twinkle * 1.4, Color("#D7F1FF", 0.08 + twinkle * 0.18))

func _draw_gradient_rect(rect: Rect2, top_left: Color, top_right: Color, bottom_right: Color, bottom_left: Color) -> void:
	var points := PackedVector2Array([rect.position, rect.position + Vector2(rect.size.x, 0.0), rect.end, rect.position + Vector2(0.0, rect.size.y)])
	draw_polygon(points, PackedColorArray([top_left, top_right, bottom_right, bottom_left]))

func _draw_energy_bands() -> void:
	for i in range(6):
		var y := size.y * (0.12 + float(i) * 0.14) + sin(anim_time * 0.35 + float(i)) * 22.0
		var offset := fposmod(anim_time * (32.0 + i * 8.0), size.x + 280.0) - 140.0
		var color := Color("#63D7C4").lerp(Color("#A78BFA"), float(i) / 5.0)
		draw_line(Vector2(-160.0 + offset, y), Vector2(size.x + 160.0 + offset, y + 42.0), Color(color.r, color.g, color.b, 0.055), 18.0)
		draw_line(Vector2(-240.0 - offset * 0.35, y + 36.0), Vector2(size.x + 120.0 - offset * 0.35, y - 18.0), Color("#F2D36B", 0.030), 10.0)
	var scan_y := fposmod(anim_time * 72.0, size.y + 80.0) - 40.0
	draw_rect(Rect2(Vector2(0.0, scan_y), Vector2(size.x, 2.0)), Color("#D7F1FF", 0.13))
	draw_rect(Rect2(Vector2(0.0, scan_y + 2.0), Vector2(size.x, 18.0)), Color("#63D7C4", 0.025))

func _draw_menu_pulses(arena: Rect2) -> void:
	var center := _project(arena, Vector2(0.50, 0.50))
	for i in range(4):
		var t := fposmod(anim_time * 0.32 + float(i) * 0.25, 1.0)
		var radius := lerpf(26.0, 190.0, t)
		var alpha := (1.0 - t) * 0.18
		draw_arc(center, radius, 0, TAU, 72, Color("#63D7C4", alpha), 2.0)
		draw_arc(center + Vector2(0.0, radius * 0.10), radius * 1.22, 0.15, TAU - 0.15, 72, Color("#A78BFA", alpha * 0.65), 1.2)

func _arena_plane(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position + Vector2(rect.size.x * 0.10, rect.size.y * 0.14),
		rect.position + Vector2(rect.size.x * 0.90, rect.size.y * 0.14),
		rect.position + Vector2(rect.size.x, rect.size.y * 0.78),
		rect.position + Vector2(0, rect.size.y * 0.78),
	])

func _project(rect: Rect2, uv: Vector2) -> Vector2:
	var plane := _arena_plane(rect)
	var top := plane[0].lerp(plane[1], uv.x)
	var bottom := plane[3].lerp(plane[2], uv.x)
	return top.lerp(bottom, uv.y)

func _draw_preview_wall(rect: Rect2, center_uv: Vector2, size_uv: Vector2, color: Color) -> void:
	var a := _project(rect, center_uv - size_uv * 0.5)
	var b := _project(rect, center_uv + Vector2(size_uv.x, -size_uv.y) * 0.5)
	var c := _project(rect, center_uv + size_uv * 0.5)
	var d := _project(rect, center_uv + Vector2(-size_uv.x, size_uv.y) * 0.5)
	var top := PackedVector2Array([a, b, c, d])
	var lift := Vector2(0, -18)
	var side := Vector2(8, 16)
	var top_lifted := PackedVector2Array([a + lift, b + lift, c + lift, d + lift])
	var front := PackedVector2Array([d + lift, c + lift, c + side, d + side])
	var right := PackedVector2Array([b + lift, c + lift, c + side, b + side])
	var shadow := PackedVector2Array([a + Vector2(12, 14), b + Vector2(18, 12), c + Vector2(20, 28), d + Vector2(10, 30)])
	draw_polygon(shadow, _fill_colors(shadow.size(), Color("#000000", 0.22)))
	draw_polygon(front, _fill_colors(front.size(), color.darkened(0.34)))
	draw_polygon(right, _fill_colors(right.size(), color.darkened(0.20)))
	draw_polygon(top_lifted, _fill_colors(top_lifted.size(), color))
	_draw_closed_polyline(top_lifted, Color("#F1F5FA", 0.22), 1.6)

func _draw_preview_actor(pos: Vector2, color: Color) -> void:
	draw_set_transform(pos + Vector2(0, 13), 0.0, Vector2(1.25, 0.42))
	draw_circle(Vector2.ZERO, 17.0, Color("#000000", 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var body := PackedVector2Array([
		pos + Vector2(0, -21),
		pos + Vector2(15, -13),
		pos + Vector2(17, 9),
		pos + Vector2(10, 19),
		pos + Vector2(3, 12),
		pos + Vector2(-4, 20),
		pos + Vector2(-10, 12),
		pos + Vector2(-17, 9),
		pos + Vector2(-15, -13),
	])
	draw_polygon(body, _fill_colors(body.size(), Color(color.r, color.g, color.b, 0.90)))
	_draw_closed_polyline(body, Color("#03101E", 0.78), 1.8)
	draw_circle(pos + Vector2(-6, -8), 4.6, Color("#F6FBFF", 0.96))
	draw_circle(pos + Vector2(6, -8), 4.6, Color("#F6FBFF", 0.96))
	draw_circle(pos + Vector2(-4, -8), 1.8, Color("#07101D", 0.94))
	draw_circle(pos + Vector2(8, -8), 1.8, Color("#07101D", 0.94))
	draw_circle(pos + Vector2(0, 4), 5.4, Color("#030712", 0.80))

func _fill_colors(count: int, color: Color) -> PackedColorArray:
	var colors := PackedColorArray()
	for _i in range(count):
		colors.append(color)
	return colors

func _draw_closed_polyline(points: PackedVector2Array, color: Color, width: float) -> void:
	for i in range(points.size()):
		draw_line(points[i], points[(i + 1) % points.size()], color, width)
