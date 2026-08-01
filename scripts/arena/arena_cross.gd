extends Node2D
# 地图容器与规则桥接层，生成地图外观并转发地图特有交互。
class_name ArenaCross

const DungeonRuleScript = preload("res://scripts/arena/map_rules/dungeon_rule.gd")
const SkyCityRuleScript = preload("res://scripts/arena/map_rules/sky_city_rule.gd")
const JungleRuleScript = preload("res://scripts/arena/map_rules/jungle_rule.gd")
const MistWorldRuleScript = preload("res://scripts/arena/map_rules/mist_world_rule.gd")
const DESIGN_MAP_SIZE := Vector2(1600, 900)

var map_size: Vector2 = Vector2(2160, 1215)
var map_id: String = MatchConfig.MAP_DUNGEON
var wall_rects: Array[Rect2] = []
var spawn_points: Array[Vector2] = []
var accent_color: Color = Color("#63D7C4")
var secondary_color: Color = Color("#6EA8FE")
var floor_color: Color = Color("#10192C")
var wall_color: Color = Color("#1B263D")
var deco_rects: Array[Rect2] = []
var map_rule
var layout_rng := RandomNumberGenerator.new()
var visuals_enabled: bool = true

func set_visuals_enabled(enabled: bool) -> void:
	visuals_enabled = enabled
	visible = enabled
	if map_rule != null and map_rule.has_method("set_visuals_enabled"):
		map_rule.set_visuals_enabled(enabled)

func build_map(balance: GameBalance, selected_map_id: String = "arena_cross", seed_value: int = 0) -> void:
	map_size = balance.map_size
	map_id = selected_map_id
	layout_rng.seed = int(seed_value) + _layout_seed_offset()
	_clear_walls()
	map_rule = null
	deco_rects.clear()
	_apply_palette()
	wall_rects = _border_walls()
	match _theme_id():
		"sky_city":
			_build_sky_city()
		"jungle":
			_build_jungle()
		"mist_world":
			_build_mist_world()
		_:
			_build_dungeon()
	for rect in wall_rects:
		_add_wall(rect)
	_create_map_rule(seed_value)
	if visuals_enabled:
		queue_redraw()

func get_spawn_points() -> Array[Vector2]:
	return spawn_points.duplicate()

func get_wall_rects() -> Array[Rect2]:
	return wall_rects.duplicate()

func get_map_size() -> Vector2:
	return map_size

func is_point_blocked(point: Vector2) -> bool:
	if point.x < 0.0 or point.y < 0.0 or point.x > map_size.x or point.y > map_size.y:
		return true
	for rect in wall_rects:
		if rect.has_point(point):
			return true
	if map_rule != null and map_rule.has_method("is_point_blocked") and map_rule.is_point_blocked(point):
		return true
	return false

func is_spawn_area_clear(point: Vector2, radius: float) -> bool:
	if point.x < radius or point.y < radius or point.x > map_size.x - radius or point.y > map_size.y - radius:
		return false
	var offsets: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(radius, 0),
		Vector2(-radius, 0),
		Vector2(0, radius),
		Vector2(0, -radius),
		Vector2(radius * 0.72, radius * 0.72),
		Vector2(-radius * 0.72, radius * 0.72),
		Vector2(radius * 0.72, -radius * 0.72),
		Vector2(-radius * 0.72, -radius * 0.72),
	]
	for offset in offsets:
		if is_point_blocked(point + offset):
			return false
	if map_rule != null and map_rule.has_method("is_spawn_area_blocked") and map_rule.is_spawn_area_blocked(point, radius):
		return false
	return true

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	if map_rule != null and map_rule.has_method("rule_step"):
		map_rule.rule_step(delta, players, projectiles, match_time, playing)

func handle_projectile_hit(projectile) -> bool:
	if map_rule != null and map_rule.has_method("handle_projectile_hit"):
		return bool(map_rule.handle_projectile_hit(projectile))
	return false

func apply_pulse_hit(center: Vector2, radius: float, damage: float, source_id: int) -> void:
	if map_rule != null and map_rule.has_method("apply_pulse_hit"):
		map_rule.apply_pulse_hit(center, radius, damage, source_id)

func is_line_blocked(a: Vector2, b: Vector2) -> bool:
	var steps := 36
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		if is_point_blocked(a.lerp(b, t)):
			return true
	return false

func ray_distance(origin: Vector2, direction: Vector2, max_distance: float) -> float:
	var steps := 48
	var dir := direction.normalized()
	for i in range(1, steps + 1):
		var d := max_distance * float(i) / float(steps)
		if is_point_blocked(origin + dir * d):
			return d
	return max_distance

func _add_wall(rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.name = "Wall"
	body.add_to_group("walls")
	body.position = rect.position + rect.size * 0.5
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	var collision := CollisionShape2D.new()
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func _clear_walls() -> void:
	for child in get_children():
		child.queue_free()

func _create_map_rule(seed_value: int) -> void:
	var script: GDScript
	match _theme_id():
		"sky_city":
			script = SkyCityRuleScript
		"jungle":
			script = JungleRuleScript
		"mist_world":
			script = MistWorldRuleScript
		_:
			script = DungeonRuleScript
	map_rule = script.new()
	map_rule.name = "MapRule_%s" % _theme_id()
	add_child(map_rule)
	if map_rule.has_method("set_visuals_enabled"):
		map_rule.set_visuals_enabled(visuals_enabled)
	map_rule.configure(self, map_size, seed_value)

func _draw() -> void:
	if not visuals_enabled:
		return
	var arena_rect := Rect2(Vector2.ZERO, map_size)
	draw_rect(arena_rect, Color("#040712"))
	draw_rect(Rect2(Vector2(34, 34), map_size - Vector2(68, 68)), floor_color)
	_draw_floor_panels()
	_draw_lane_markings()
	for rect in deco_rects:
		_draw_deco_plate(rect)
	for point in spawn_points:
		_draw_spawn_pad(point)
	for rect in wall_rects:
		_draw_wall(rect)
	draw_rect(arena_rect.grow(-29.0), Color(accent_color.r, accent_color.g, accent_color.b, 0.18), false, 2.0)

func _border_walls() -> Array[Rect2]:
	return [
		Rect2(0, 0, map_size.x, 24),
		Rect2(0, map_size.y - 24, map_size.x, 24),
		Rect2(0, 0, 24, map_size.y),
		Rect2(map_size.x - 24, 0, 24, map_size.y),
	]

func _theme_id() -> String:
	match map_id:
		"arena_cross", MatchConfig.MAP_DUNGEON:
			return "dungeon"
		"neon_docks", MatchConfig.MAP_SKY_CITY:
			return "sky_city"
		"reactor_ring", MatchConfig.MAP_JUNGLE:
			return "jungle"
		"skyline_yard", MatchConfig.MAP_MIST_WORLD:
			return "mist_world"
	return "dungeon"

func _layout_seed_offset() -> int:
	match _theme_id():
		"sky_city":
			return 21101
		"jungle":
			return 31991
		"mist_world":
			return 42737
	return 11243

func _layout_scale() -> Vector2:
	return Vector2(map_size.x / DESIGN_MAP_SIZE.x, map_size.y / DESIGN_MAP_SIZE.y)

func _uniform_layout_scale() -> float:
	var scale := _layout_scale()
	return minf(scale.x, scale.y)

func _scale_design_point(point: Vector2) -> Vector2:
	var scale := _layout_scale()
	return Vector2(point.x * scale.x, point.y * scale.y)

func _scale_deco_rect(base: Rect2) -> Rect2:
	var center := _scale_design_point(base.position + base.size * 0.5)
	var size := base.size * clampf(_uniform_layout_scale(), 1.0, 1.18)
	return Rect2(center - size * 0.5, size)

func _scale_deco_rects(rects: Array) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for rect in rects:
		out.append(_scale_deco_rect(rect as Rect2))
	return out

func _scale_points(points: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for point in points:
		out.append(_scale_design_point(point as Vector2))
	return out

func _randomize_wall_rects(templates: Array[Dictionary]) -> Array[Rect2]:
	var placed: Array[Rect2] = []
	for template in templates:
		var base := template["rect"] as Rect2
		var jitter := Vector2.ZERO
		var size_jitter := Vector2.ZERO
		if template.has("jitter"):
			jitter = template["jitter"] as Vector2
		if template.has("size_jitter"):
			size_jitter = template["size_jitter"] as Vector2
		var rect := base
		for _attempt in range(18):
			rect = _randomized_wall_rect(base, jitter, size_jitter)
			if _layout_rect_fits(rect, placed):
				break
		placed.append(rect)
	return placed

func _randomized_wall_rect(base: Rect2, jitter: Vector2, size_jitter: Vector2) -> Rect2:
	var design_size := Vector2(
		maxf(44.0, base.size.x + layout_rng.randf_range(-size_jitter.x, size_jitter.x)),
		maxf(44.0, base.size.y + layout_rng.randf_range(-size_jitter.y, size_jitter.y))
	)
	var size := _thin_wall_size(design_size)
	var design_center := base.position + base.size * 0.5 + Vector2(
		layout_rng.randf_range(-jitter.x, jitter.x),
		layout_rng.randf_range(-jitter.y, jitter.y)
	)
	var center := _scale_design_point(design_center)
	var pos := center - size * 0.5
	pos.x = clampf(pos.x, 46.0, map_size.x - 46.0 - size.x)
	pos.y = clampf(pos.y, 46.0, map_size.y - 46.0 - size.y)
	return Rect2(pos, size)

func _thin_wall_size(design_size: Vector2) -> Vector2:
	var long_side := maxf(design_size.x, design_size.y)
	var short_side := maxf(1.0, minf(design_size.x, design_size.y))
	var ratio := long_side / short_side
	if ratio < 1.35:
		return Vector2(
			maxf(54.0, design_size.x * 0.70),
			maxf(34.0, design_size.y * 0.56)
		)
	if design_size.x >= design_size.y:
		return Vector2(
			maxf(70.0, design_size.x * 0.92),
			clampf(design_size.y * 0.54, 24.0, 44.0)
		)
	return Vector2(
		clampf(design_size.x * 0.54, 24.0, 44.0),
		maxf(70.0, design_size.y * 0.92)
	)

func _layout_rect_fits(rect: Rect2, placed: Array[Rect2]) -> bool:
	if rect.position.x < 42.0 or rect.position.y < 42.0 or rect.end.x > map_size.x - 42.0 or rect.end.y > map_size.y - 42.0:
		return false
	for other in placed:
		if rect.grow(18.0).intersects(other.grow(10.0)):
			return false
	return true

func _build_dungeon() -> void:
	wall_rects.append_array(_randomize_wall_rects([
		{"rect": Rect2(740, 248, 120, 84), "jitter": Vector2(64, 44), "size_jitter": Vector2(22, 14)},
		{"rect": Rect2(740, 568, 120, 84), "jitter": Vector2(64, 44), "size_jitter": Vector2(22, 14)},
		{"rect": Rect2(532, 404, 180, 74), "jitter": Vector2(84, 48), "size_jitter": Vector2(28, 14)},
		{"rect": Rect2(888, 404, 180, 74), "jitter": Vector2(84, 48), "size_jitter": Vector2(28, 14)},
		{"rect": Rect2(220, 160, 190, 54), "jitter": Vector2(86, 52), "size_jitter": Vector2(32, 10)},
		{"rect": Rect2(220, 686, 190, 54), "jitter": Vector2(86, 52), "size_jitter": Vector2(32, 10)},
		{"rect": Rect2(1190, 160, 190, 54), "jitter": Vector2(86, 52), "size_jitter": Vector2(32, 10)},
		{"rect": Rect2(1190, 686, 190, 54), "jitter": Vector2(86, 52), "size_jitter": Vector2(32, 10)},
		{"rect": Rect2(424, 278, 60, 180), "jitter": Vector2(72, 56), "size_jitter": Vector2(10, 26)},
		{"rect": Rect2(1116, 442, 60, 180), "jitter": Vector2(72, 56), "size_jitter": Vector2(10, 26)},
	]))
	deco_rects.append_array(_scale_deco_rects([
		Rect2(622, 134, 356, 54),
		Rect2(622, 712, 356, 54),
		Rect2(128, 386, 190, 72),
		Rect2(1282, 386, 190, 72),
	]))
	spawn_points = _scale_points([Vector2(150, 450), Vector2(1450, 450), Vector2(800, 130), Vector2(800, 770), Vector2(310, 250), Vector2(1290, 250), Vector2(310, 650), Vector2(1290, 650)])

func _build_sky_city() -> void:
	wall_rects.append_array(_randomize_wall_rects([
		{"rect": Rect2(256, 188, 252, 58), "jitter": Vector2(112, 58), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1092, 188, 252, 58), "jitter": Vector2(112, 58), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(256, 654, 252, 58), "jitter": Vector2(112, 58), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1092, 654, 252, 58), "jitter": Vector2(112, 58), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(620, 292, 72, 230), "jitter": Vector2(86, 74), "size_jitter": Vector2(14, 38)},
		{"rect": Rect2(908, 378, 72, 230), "jitter": Vector2(86, 74), "size_jitter": Vector2(14, 38)},
		{"rect": Rect2(734, 210, 132, 52), "jitter": Vector2(96, 54), "size_jitter": Vector2(26, 10)},
		{"rect": Rect2(734, 638, 132, 52), "jitter": Vector2(96, 54), "size_jitter": Vector2(26, 10)},
		{"rect": Rect2(748, 406, 104, 88), "jitter": Vector2(100, 64), "size_jitter": Vector2(26, 20)},
	]))
	deco_rects.append_array(_scale_deco_rects([
		Rect2(76, 302, 252, 62),
		Rect2(1272, 536, 252, 62),
		Rect2(632, 88, 336, 46),
		Rect2(632, 766, 336, 46),
	]))
	spawn_points = _scale_points([Vector2(150, 180), Vector2(1450, 720), Vector2(150, 720), Vector2(1450, 180), Vector2(800, 165), Vector2(800, 735), Vector2(410, 450), Vector2(1190, 450)])

func _build_jungle() -> void:
	wall_rects.append_array(_randomize_wall_rects([
		{"rect": Rect2(710, 232, 180, 62), "jitter": Vector2(100, 60), "size_jitter": Vector2(34, 12)},
		{"rect": Rect2(710, 606, 180, 62), "jitter": Vector2(100, 60), "size_jitter": Vector2(34, 12)},
		{"rect": Rect2(520, 366, 62, 168), "jitter": Vector2(80, 76), "size_jitter": Vector2(12, 34)},
		{"rect": Rect2(1018, 366, 62, 168), "jitter": Vector2(80, 76), "size_jitter": Vector2(12, 34)},
		{"rect": Rect2(326, 198, 208, 58), "jitter": Vector2(112, 70), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1066, 198, 208, 58), "jitter": Vector2(112, 70), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(326, 644, 208, 58), "jitter": Vector2(112, 70), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1066, 644, 208, 58), "jitter": Vector2(112, 70), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(704, 406, 192, 88), "jitter": Vector2(112, 64), "size_jitter": Vector2(38, 22)},
	]))
	deco_rects.append_array(_scale_deco_rects([
		Rect2(618, 316, 364, 270),
		Rect2(70, 400, 236, 78),
		Rect2(1294, 400, 236, 78),
		Rect2(642, 86, 316, 44),
		Rect2(642, 770, 316, 44),
	]))
	spawn_points = _scale_points([Vector2(800, 145), Vector2(800, 755), Vector2(145, 450), Vector2(1455, 450), Vector2(360, 320), Vector2(1240, 580), Vector2(360, 580), Vector2(1240, 320)])

func _build_mist_world() -> void:
	wall_rects.append_array(_randomize_wall_rects([
		{"rect": Rect2(238, 244, 226, 60), "jitter": Vector2(116, 72), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(238, 596, 226, 60), "jitter": Vector2(116, 72), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1136, 244, 226, 60), "jitter": Vector2(116, 72), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(1136, 596, 226, 60), "jitter": Vector2(116, 72), "size_jitter": Vector2(44, 12)},
		{"rect": Rect2(604, 150, 72, 226), "jitter": Vector2(90, 86), "size_jitter": Vector2(14, 38)},
		{"rect": Rect2(924, 524, 72, 226), "jitter": Vector2(90, 86), "size_jitter": Vector2(14, 38)},
		{"rect": Rect2(696, 402, 208, 96), "jitter": Vector2(116, 74), "size_jitter": Vector2(42, 26)},
		{"rect": Rect2(84, 414, 268, 64), "jitter": Vector2(92, 76), "size_jitter": Vector2(46, 12)},
		{"rect": Rect2(1248, 414, 268, 64), "jitter": Vector2(92, 76), "size_jitter": Vector2(46, 12)},
	]))
	deco_rects.append_array(_scale_deco_rects([
		Rect2(512, 496, 100, 238),
		Rect2(988, 166, 100, 238),
		Rect2(668, 76, 264, 42),
		Rect2(668, 782, 264, 42),
		Rect2(642, 330, 316, 240),
	]))
	spawn_points = _scale_points([Vector2(160, 160), Vector2(1440, 740), Vector2(160, 740), Vector2(1440, 160), Vector2(800, 220), Vector2(800, 680), Vector2(455, 450), Vector2(1145, 450)])

func _apply_palette() -> void:
	match _theme_id():
		"sky_city":
			accent_color = Color("#8DD7FF")
			secondary_color = Color("#F2D36B")
			floor_color = Color("#D7F1FF")
			wall_color = Color("#E9F8FF")
		"jungle":
			accent_color = Color("#8DFF7A")
			secondary_color = Color("#D8B56E")
			floor_color = Color("#15331E")
			wall_color = Color("#466038")
		"mist_world":
			accent_color = Color("#B7A7FF")
			secondary_color = Color("#77D9D8")
			floor_color = Color("#131728")
			wall_color = Color("#30324D")
		_:
			accent_color = Color("#D7A765")
			secondary_color = Color("#76808E")
			floor_color = Color("#1B1714")
			wall_color = Color("#5B4A39")

func _draw_floor_panels() -> void:
	match _theme_id():
		"sky_city":
			_draw_sky_floor()
		"jungle":
			_draw_jungle_floor()
		"mist_world":
			_draw_mist_floor()
		_:
			_draw_dungeon_floor()

func _draw_lane_markings() -> void:
	var c := Color(accent_color.r, accent_color.g, accent_color.b, 0.16)
	match _theme_id():
		"sky_city":
			draw_line(Vector2(map_size.x * 0.5, 64), Vector2(map_size.x * 0.5, map_size.y - 64), Color("#F2D36B", 0.10), 2.0)
			draw_line(Vector2(76, map_size.y * 0.5), Vector2(map_size.x - 76, map_size.y * 0.5), Color("#F2D36B", 0.08), 1.4)
			draw_arc(map_size * 0.5, 176.0, 0, TAU, 72, Color("#FFFFFF", 0.09), 1.5)
		"jungle":
			draw_line(Vector2(map_size.x * 0.5, 58), Vector2(map_size.x * 0.5, map_size.y - 58), Color("#6A5430", 0.12), 6.0)
			draw_line(Vector2(58, map_size.y * 0.5), Vector2(map_size.x - 58, map_size.y * 0.5), Color("#6A5430", 0.10), 5.0)
			draw_arc(map_size * 0.5, 180.0, 0, TAU, 72, Color("#203B20", 0.20), 4.0)
		"mist_world":
			draw_arc(map_size * 0.5, 132.0, 0, TAU, 64, Color("#D7D9FF", 0.06), 1.5)
			draw_arc(map_size * 0.5, 228.0, 0, TAU, 80, Color(accent_color.r, accent_color.g, accent_color.b, 0.06), 1.5)
			draw_line(Vector2(map_size.x * 0.5, 64), Vector2(map_size.x * 0.5, map_size.y - 64), Color("#FFFFFF", 0.025), 1.2)
		_:
			draw_line(Vector2(map_size.x * 0.5, 56), Vector2(map_size.x * 0.5, map_size.y - 56), Color(c.r, c.g, c.b, 0.08), 1.5)
			draw_line(Vector2(56, map_size.y * 0.5), Vector2(map_size.x - 56, map_size.y * 0.5), Color(c.r, c.g, c.b, 0.08), 1.5)
			draw_arc(map_size * 0.5, 148.0, 0, TAU, 64, Color("#C78D52", 0.07), 1.5)

func _draw_deco_plate(rect: Rect2) -> void:
	match _theme_id():
		"sky_city":
			draw_rect(rect.grow(8.0), Color("#FFFFFF", 0.08))
			draw_rect(rect, Color("#FFFFFF", 0.24))
			draw_rect(rect, Color("#F2D36B", 0.36), false, 2.0)
			for x in range(int(rect.position.x) + 18, int(rect.end.x), 54):
				draw_circle(Vector2(x, rect.position.y + rect.size.y * 0.5), 10.0, Color("#BEEBFF", 0.22))
		"jungle":
			draw_rect(rect, Color("#1B4628", 0.36))
			for x in range(int(rect.position.x) + 12, int(rect.end.x), 28):
				draw_circle(Vector2(x, rect.position.y + 16), 9.0, Color("#356A32", 0.36))
				draw_line(Vector2(x - 6, rect.end.y - 8), Vector2(x + 14, rect.position.y + 8), Color("#8DFF7A", 0.16), 2.0)
			draw_rect(rect, Color("#B7A15C", 0.16), false, 1.5)
		"mist_world":
			draw_rect(rect.grow(10.0), Color("#C9C6FF", 0.035))
			draw_rect(rect, Color("#FFFFFF", 0.045))
			draw_arc(rect.position + rect.size * 0.5, minf(rect.size.x, rect.size.y) * 0.42, 0, TAU, 40, Color("#B7A7FF", 0.18), 1.8)
			draw_line(rect.position + Vector2(12, rect.size.y * 0.5), rect.position + Vector2(rect.size.x - 12, rect.size.y * 0.5), Color("#77D9D8", 0.12), 1.5)
		_:
			draw_rect(rect, Color("#2A211B", 0.72))
			draw_rect(rect, Color("#C78D52", 0.18), false, 1.8)
			for x in range(int(rect.position.x) + 18, int(rect.end.x), 44):
				draw_line(Vector2(x, rect.position.y + 8), Vector2(x + 18, rect.end.y - 8), Color("#BFA17D", 0.12), 1.2)

func _draw_wall(rect: Rect2) -> void:
	var depth := clampf(minf(rect.size.x, rect.size.y) * 0.82, 18.0, 34.0)
	var slant := Vector2(9.0, depth)
	var shadow_points := PackedVector2Array([
		rect.position + Vector2(8, 11),
		rect.position + Vector2(rect.size.x, 8) + slant,
		rect.end + slant + Vector2(8, 10),
		rect.position + Vector2(0, rect.size.y) + Vector2(10, depth + 13),
	])
	draw_polygon(shadow_points, _solid_colors(shadow_points.size(), Color("#000000", 0.24)))
	var front_face := PackedVector2Array([
		rect.position + Vector2(0, rect.size.y),
		rect.position + Vector2(rect.size.x, rect.size.y),
		rect.position + Vector2(rect.size.x, rect.size.y) + slant,
		rect.position + Vector2(0, rect.size.y) + slant,
	])
	var right_face := PackedVector2Array([
		rect.position + Vector2(rect.size.x, 0),
		rect.position + Vector2(rect.size.x, rect.size.y),
		rect.position + Vector2(rect.size.x, rect.size.y) + slant,
		rect.position + Vector2(rect.size.x, 0) + slant,
	])
	draw_polygon(front_face, _solid_colors(front_face.size(), _wall_side_color()))
	draw_polygon(right_face, _solid_colors(right_face.size(), _wall_side_color().darkened(0.16)))
	draw_line(rect.position + Vector2(0, rect.size.y), rect.position + Vector2(rect.size.x, rect.size.y), Color("#000000", 0.20), 3.0)
	draw_rect(rect, wall_color)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 4.0)), wall_color.lightened(0.26))
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y - 4.0), Vector2(rect.size.x, 4.0)), Color("#000000", 0.16))
	match _theme_id():
		"sky_city":
			_draw_sky_wall_texture(rect)
		"jungle":
			_draw_jungle_wall_texture(rect)
		"mist_world":
			_draw_mist_wall_texture(rect)
		_:
			_draw_dungeon_wall_texture(rect)
	draw_rect(rect, Color(accent_color.r, accent_color.g, accent_color.b, 0.18), false, 2.0)
	draw_rect(rect.grow(-5.0), Color("#FFFFFF", 0.06), false, 1.0)

func _draw_spawn_pad(point: Vector2) -> void:
	draw_circle(point + Vector2(4, 8), 34.0, Color("#000000", 0.18))
	draw_circle(point, 31.0, Color(accent_color.r, accent_color.g, accent_color.b, 0.10))
	draw_arc(point, 25.0, 0, TAU, 36, Color(accent_color.r, accent_color.g, accent_color.b, 0.34), 1.8)
	match _theme_id():
		"sky_city":
			draw_arc(point, 15.0, 0, TAU, 30, Color("#FFFFFF", 0.25), 1.3)
			draw_line(point + Vector2(-14, 0), point + Vector2(14, 0), Color("#F2D36B", 0.30), 1.5)
		"jungle":
			for i in range(6):
				var a := TAU * float(i) / 6.0
				draw_line(point, point + Vector2.RIGHT.rotated(a) * 18.0, Color("#8DFF7A", 0.22), 1.5)
			draw_circle(point, 8.0, Color("#102817", 0.45))
		"mist_world":
			draw_arc(point, 17.0, 0.3, TAU + 0.3, 36, Color("#D7D9FF", 0.28), 1.5)
			draw_circle(point, 7.0, Color("#B7A7FF", 0.18))
		_:
			draw_rect(Rect2(point - Vector2(12, 12), Vector2(24, 24)), Color("#3B2A1D", 0.42))
			draw_arc(point, 14.0, 0, TAU, 28, Color("#E6A85C", 0.22), 1.2)

func _draw_dungeon_floor() -> void:
	for x in range(34, int(map_size.x) - 34, 72):
		for y in range(34, int(map_size.y) - 34, 72):
			var noise := _noise_unit(float(x), float(y))
			var tile := Rect2(Vector2(x, y), Vector2(72, 72))
			var tint := Color("#211A16", lerpf(0.10, 0.28, noise))
			draw_rect(tile, tint)
			if noise > 0.66:
				var chip := Vector2(x + 14.0 + _noise_unit(float(y), float(x)) * 38.0, y + 12.0 + noise * 34.0)
				draw_line(chip, chip + Vector2(10.0 + noise * 12.0, -5.0 + noise * 8.0), Color("#0A0705", 0.16), 1.2)
				draw_circle(chip + Vector2(28.0, 24.0), 2.2, Color("#C78D52", 0.09))
	for x in range(34, int(map_size.x) - 34, 72):
		draw_line(Vector2(x, 34), Vector2(x, map_size.y - 34), Color("#6E5A48", 0.12), 1.0)
	for y in range(34, int(map_size.y) - 34, 72):
		draw_line(Vector2(34, y), Vector2(map_size.x - 34, y), Color("#6E5A48", 0.12), 1.0)
	for x in range(124, int(map_size.x), 330):
		var base := Vector2(x, 142 + _noise_unit(float(x), 4.0) * 90.0)
		draw_line(base, base + Vector2(22, 18), Color("#000000", 0.12), 1.1)
		draw_line(base + Vector2(14, 12), base + Vector2(38, 6), Color("#C78D52", 0.06), 1.0)

func _draw_sky_floor() -> void:
	draw_rect(Rect2(Vector2(34, 34), map_size - Vector2(68, 68)), Color("#BFE9FF", 0.34))
	for x in range(60, int(map_size.x), 230):
		_draw_soft_cloud(Vector2(x, 98 + 18.0 * _noise_unit(float(x), 1.0)), 0.92 + _noise_unit(float(x), 2.0) * 0.36, 0.24)
		_draw_soft_cloud(Vector2(x + 72, map_size.y - 150 + 20.0 * _noise_unit(float(x), 3.0)), 0.72 + _noise_unit(float(x), 4.0) * 0.32, 0.18)
	for x in range(54, int(map_size.x) - 54, 96):
		draw_line(Vector2(x, 46), Vector2(x, map_size.y - 46), Color("#FFFFFF", 0.08), 1.0)
	for y in range(54, int(map_size.y) - 54, 96):
		draw_line(Vector2(46, y), Vector2(map_size.x - 46, y), Color("#72BFE7", 0.09), 1.0)
	for x in range(90, int(map_size.x), 250):
		var start := Vector2(x, 120 + _noise_unit(float(x), 8.0) * (map_size.y - 240.0))
		draw_line(start, start + Vector2(78, 18), Color("#FFFFFF", 0.09), 1.2)
		draw_line(start + Vector2(16, 8), start + Vector2(104, 2), Color("#83B9D6", 0.07), 1.0)

func _draw_jungle_floor() -> void:
	for x in range(48, int(map_size.x), 74):
		for y in range(48, int(map_size.y), 74):
			var n := _noise_unit(float(x), float(y))
			var p := Vector2(x + lerpf(-12.0, 14.0, n), y + lerpf(-10.0, 12.0, _noise_unit(float(y), float(x))))
			draw_circle(p, 10.0 + n * 11.0, Color("#214C2A", 0.18 + n * 0.16))
			if n > 0.42:
				_draw_leaf(p + Vector2(18.0, 9.0), n * TAU, 0.75 + n * 0.35, Color("#4F8A37", 0.22))
			if n > 0.70:
				draw_circle(p + Vector2(26, 22), 4.0, Color("#C7E36F", 0.12))
	for x in range(70, int(map_size.x), 220):
		var wiggle := _noise_unit(float(x), 12.0) * 34.0
		draw_line(Vector2(x, 62), Vector2(x + 70 + wiggle, map_size.y - 80), Color("#6E5A2E", 0.08), 4.0)
		draw_line(Vector2(x + 8, 68), Vector2(x + 96 + wiggle, map_size.y - 96), Color("#2F6A35", 0.06), 2.0)
	for y in range(70, int(map_size.y), 95):
		draw_line(Vector2(42, y), Vector2(map_size.x - 42, y + sin(float(y) * 0.055) * 14.0), Color("#8DFF7A", 0.045), 1.6)

func _draw_mist_floor() -> void:
	for y in range(70, int(map_size.y), 86):
		var offset := sin(float(y) * 0.033) * 38.0
		var alpha := 0.026 + _noise_unit(float(y), 7.0) * 0.026
		draw_line(Vector2(40 + offset, y), Vector2(map_size.x - 40 - offset * 0.25, y + 26), Color("#D7D9FF", alpha), 13.0)
	for x in range(80, int(map_size.x), 190):
		var center := Vector2(x, 150 + fposmod(float(x) * 1.37, map_size.y - 300.0))
		_draw_flat_ellipse(center, Vector2(90, 36), Color("#B7A7FF", 0.025))
		draw_arc(center, 46.0, 0, TAU, 36, Color("#77D9D8", 0.035), 1.2)
	draw_circle(map_size * 0.5, 250.0, Color("#77D9D8", 0.025))
	draw_arc(map_size * 0.5, 312.0, 0, TAU, 86, Color("#FFFFFF", 0.026), 1.5)

func _wall_side_color() -> Color:
	match _theme_id():
		"sky_city":
			return Color("#9AC8E3")
		"jungle":
			return Color("#24381F")
		"mist_world":
			return Color("#1A1A2C")
	return Color("#2C2119")

func _solid_colors(count: int, color: Color) -> PackedColorArray:
	var colors := PackedColorArray()
	for _i in range(count):
		colors.append(color)
	return colors

func _noise_unit(a: float, b: float = 0.0) -> float:
	return fposmod(sin(a * 12.9898 + b * 78.233) * 43758.5453, 1.0)

func _draw_flat_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(maxf(radii.x, 1.0), maxf(radii.y, 1.0)))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_soft_cloud(center: Vector2, scale: float, alpha: float) -> void:
	_draw_flat_ellipse(center + Vector2(8, 18) * scale, Vector2(92, 25) * scale, Color("#6EA8FE", 0.08 * alpha))
	_draw_flat_ellipse(center, Vector2(68, 24) * scale, Color("#FFFFFF", 0.58 * alpha))
	_draw_flat_ellipse(center + Vector2(-38, 5) * scale, Vector2(42, 18) * scale, Color("#FFFFFF", 0.40 * alpha))
	_draw_flat_ellipse(center + Vector2(38, 2) * scale, Vector2(52, 20) * scale, Color("#E9F8FF", 0.36 * alpha))
	_draw_flat_ellipse(center + Vector2(4, -11) * scale, Vector2(40, 20) * scale, Color("#FFFFFF", 0.44 * alpha))
	_draw_flat_ellipse(center + Vector2(22, 14) * scale, Vector2(64, 12) * scale, Color("#72BFE7", 0.14 * alpha))

func _draw_leaf(center: Vector2, angle: float, scale: float, color: Color) -> void:
	var dir := Vector2.RIGHT.rotated(angle)
	var side := dir.orthogonal()
	var points := PackedVector2Array([
		center + dir * 16.0 * scale,
		center + side * 6.0 * scale,
		center - dir * 12.0 * scale,
		center - side * 6.0 * scale,
	])
	draw_polygon(points, _solid_colors(points.size(), color))
	draw_line(center - dir * 11.0 * scale, center + dir * 13.0 * scale, Color("#C7E36F", color.a * 0.45), 1.0)

func _draw_dungeon_wall_texture(rect: Rect2) -> void:
	for y in range(int(rect.position.y) + 16, int(rect.end.y), 20):
		draw_line(Vector2(rect.position.x + 6, y), Vector2(rect.end.x - 6, y), Color("#2A211B", 0.34), 1.1)
	for y in range(int(rect.position.y) + 10, int(rect.end.y), 40):
		var offset := 0 if int(y / 40) % 2 == 0 else 23
		for x in range(int(rect.position.x) + 16 + offset, int(rect.end.x), 46):
			draw_line(Vector2(x, y), Vector2(x, minf(y + 20, rect.end.y - 5)), Color("#2A211B", 0.32), 1.0)
	for x in range(int(rect.position.x) + 22, int(rect.end.x), 78):
		draw_line(Vector2(x, rect.position.y + 10), Vector2(x + 18, rect.end.y - 12), Color("#D7A765", 0.10), 1.2)

func _draw_sky_wall_texture(rect: Rect2) -> void:
	draw_rect(rect.grow(-7.0), Color("#FFFFFF", 0.18), false, 1.4)
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y - 8), Vector2(rect.size.x, 8)), Color("#F2D36B", 0.22))
	for x in range(int(rect.position.x) + 20, int(rect.end.x), 52):
		draw_line(Vector2(x, rect.position.y + 8), Vector2(x + 24, rect.end.y - 12), Color("#83B9D6", 0.18), 1.2)
		draw_circle(Vector2(x + 8, rect.position.y + rect.size.y * 0.5), 5.0, Color("#FFFFFF", 0.22))

func _draw_jungle_wall_texture(rect: Rect2) -> void:
	for x in range(int(rect.position.x) + 12, int(rect.end.x), 34):
		draw_circle(Vector2(x, rect.position.y + 12), 8.0, Color("#2F6A35", 0.42))
		draw_circle(Vector2(x + 11, rect.end.y - 10), 7.0, Color("#1D4C25", 0.38))
		draw_line(Vector2(x, rect.position.y + 4), Vector2(x + 20, rect.end.y - 5), Color("#91D56B", 0.20), 2.0)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 6.0)), Color("#A78952", 0.22))

func _draw_mist_wall_texture(rect: Rect2) -> void:
	for x in range(int(rect.position.x) + 18, int(rect.end.x), 58):
		draw_line(Vector2(x, rect.position.y + 8), Vector2(x + 16, rect.end.y - 10), Color("#D7D9FF", 0.12), 1.1)
		draw_arc(Vector2(x + 12, rect.position.y + rect.size.y * 0.5), 8.0, 0, TAU, 18, Color("#77D9D8", 0.13), 1.0)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 5.0)), Color("#B7A7FF", 0.18))
