extends RefCounted
# 出生点选择器，按地图安全性、敌人距离和弹道威胁挑选重生位置。
class_name SpawnManager

var rng := RandomNumberGenerator.new()
const SPAWN_RADIUS := 28.0
const RANDOM_CANDIDATE_COUNT := 64

func set_seed(seed_value: int) -> void:
	rng.seed = seed_value

func choose_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], projectiles: Array[ArenaProjectile], spawn_points: Array[Vector2], arena_map: Node, config: MatchConfig) -> Vector2:
	var candidates := _random_spawn_candidates(arena_map, spawn_points)
	if candidates.is_empty():
		return Vector2(800, 450)
	var best_point := candidates[0]
	var best_score := -INF
	for point in candidates:
		var score := rng.randf_range(0.0, 6.0)
		for other in players:
			if other == player or not other.is_alive:
				continue
			var d := point.distance_to(other.global_position)
			if TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id):
				score += clampf(360.0 - absf(d - 140.0), 0.0, 260.0) * 0.45
			else:
				score += clampf(d, 0.0, 900.0)
				if arena_map.has_method("is_line_blocked") and not arena_map.is_line_blocked(point, other.global_position):
					score -= 300.0
		for projectile in projectiles:
			var distance_to_path := _distance_to_projectile_path(point, projectile.global_position, projectile.velocity.normalized())
			if distance_to_path < 80.0:
				score -= 220.0
		if score > best_score:
			best_score = score
			best_point = point
	return best_point

func _random_spawn_candidates(arena_map: Node, fallback_points: Array[Vector2]) -> Array[Vector2]:
	var candidates: Array[Vector2] = []
	var map_size := Vector2(2160, 1215)
	if arena_map != null and arena_map.has_method("get_map_size"):
		map_size = arena_map.get_map_size()
	var margin := maxf(70.0, SPAWN_RADIUS + 34.0)
	var tries := RANDOM_CANDIDATE_COUNT * 5
	while candidates.size() < RANDOM_CANDIDATE_COUNT and tries > 0:
		tries -= 1
		var point := Vector2(
			rng.randf_range(margin, map_size.x - margin),
			rng.randf_range(margin, map_size.y - margin)
		)
		if _is_spawn_area_clear(arena_map, point):
			candidates.append(point)
	if candidates.is_empty():
		for point in fallback_points:
			if _is_spawn_area_clear(arena_map, point):
				candidates.append(point)
	return candidates

func _is_spawn_area_clear(arena_map: Node, point: Vector2) -> bool:
	if arena_map != null and arena_map.has_method("is_spawn_area_clear"):
		return arena_map.is_spawn_area_clear(point, SPAWN_RADIUS)
	if arena_map != null and arena_map.has_method("is_point_blocked"):
		return not arena_map.is_point_blocked(point)
	return true

func _distance_to_projectile_path(point: Vector2, origin: Vector2, direction: Vector2) -> float:
	if direction.length_squared() <= 0.001:
		return point.distance_to(origin)
	var to_point := point - origin
	var projected := maxf(0.0, to_point.dot(direction))
	return point.distance_to(origin + direction * projected)
