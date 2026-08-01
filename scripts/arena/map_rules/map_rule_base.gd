extends Node2D
# 地图规则基类，定义所有地图通用的生命周期、碰撞和视觉接口。
class_name MapRuleBase

var arena_map: Node
var map_size: Vector2 = Vector2(2160, 1215)
var rng := RandomNumberGenerator.new()
var visuals_enabled: bool = true

func set_visuals_enabled(enabled: bool) -> void:
	visuals_enabled = enabled
	visible = enabled

func configure(map_node: Node, size: Vector2, seed_value: int) -> void:
	arena_map = map_node
	map_size = size
	rng.seed = seed_value

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	pass

func get_blocking_rects() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	return rects

func is_point_blocked(point: Vector2) -> bool:
	for rect in get_blocking_rects():
		if rect.has_point(point):
			return true
	return false

func is_spawn_area_blocked(point: Vector2, radius: float) -> bool:
	var offsets: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(radius, 0),
		Vector2(-radius, 0),
		Vector2(0, radius),
		Vector2(0, -radius),
		Vector2(radius * 0.7, radius * 0.7),
		Vector2(-radius * 0.7, radius * 0.7),
		Vector2(radius * 0.7, -radius * 0.7),
		Vector2(-radius * 0.7, -radius * 0.7),
	]
	for offset in offsets:
		if is_point_blocked(point + offset):
			return true
	return false

func random_clear_point(radius: float, margin: float = 70.0, tries: int = 80) -> Vector2:
	for _i in range(tries):
		var point := Vector2(
			rng.randf_range(margin, map_size.x - margin),
			rng.randf_range(margin, map_size.y - margin)
		)
		if arena_map != null and arena_map.has_method("is_spawn_area_clear") and arena_map.is_spawn_area_clear(point, radius):
			return point
	return map_size * 0.5

func _contains_player(center: Vector2, radius: float, player) -> bool:
	return player != null and player.is_alive and player.global_position.distance_squared_to(center) <= radius * radius

func _shape_boundary_points(center: Vector2, lobes: Array, samples: int, phase: float = 0.0) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(samples):
		var angle := phase + TAU * float(i) / float(samples)
		var direction := Vector2.RIGHT.rotated(angle)
		var distance := 0.0
		for lobe in lobes:
			var offset := lobe["offset"] as Vector2
			var radius := float(lobe["radius"])
			var along := offset.dot(direction)
			var perpendicular_sq := maxf(0.0, offset.length_squared() - along * along)
			var radius_sq := radius * radius
			if perpendicular_sq <= radius_sq:
				distance = maxf(distance, along + sqrt(maxf(0.0, radius_sq - perpendicular_sq)))
		points.append(center + direction * maxf(distance, 1.0))
	return points

func _solid_colors(count: int, color: Color) -> PackedColorArray:
	var colors := PackedColorArray()
	for _i in range(count):
		colors.append(color)
	return colors

func _draw_closed_polyline(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 2:
		return
	for i in range(points.size()):
		draw_line(points[i], points[(i + 1) % points.size()], color, width)
