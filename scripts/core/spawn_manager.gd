extends RefCounted
# 出生点选择器，按地图安全性、敌人距离和弹道威胁挑选重生位置。
class_name SpawnManager

var rng := RandomNumberGenerator.new()
const SPAWN_RADIUS := 28.0
const RANDOM_CANDIDATE_COUNT := 64
const TRAINING_ENGAGEMENT_WINDOW := "engagement_window"
const TRAINING_PRESSURE_CURRICULUM := "pressure_curriculum"
const TRAINING_RESOURCE_CONTEST := "resource_contest"
const ENGAGEMENT_MIN_DISTANCE := 360.0
const ENGAGEMENT_PREFERRED_DISTANCE := 520.0
const ENGAGEMENT_MAX_DISTANCE := 680.0
const APPROACH_MIN_DISTANCE := 760.0
const APPROACH_PREFERRED_DISTANCE := 920.0
const APPROACH_MAX_DISTANCE := 1080.0
const RESOURCE_CONTEST_MIN_DISTANCE := 360.0
const RESOURCE_CONTEST_PREFERRED_DISTANCE := 440.0
const RESOURCE_CONTEST_MAX_DISTANCE := 500.0

func set_seed(seed_value: int) -> void:
	rng.seed = seed_value

func choose_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], projectiles: Array[ArenaProjectile], spawn_points: Array[Vector2], arena_map: Node, config: MatchConfig) -> Vector2:
	var candidates := _random_spawn_candidates(arena_map, spawn_points)
	if candidates.is_empty():
		return Vector2(800, 450)
	if config != null and config.training_spawn_policy == TRAINING_ENGAGEMENT_WINDOW:
		var engagement_spawn := _choose_training_engagement_spawn(player, players, candidates, arena_map, config)
		if not engagement_spawn.is_equal_approx(Vector2.INF):
			return engagement_spawn
	if config != null and config.training_spawn_policy == TRAINING_PRESSURE_CURRICULUM:
		var curriculum_spawn := _choose_training_pressure_curriculum_spawn(player, players, candidates, arena_map, config)
		if not curriculum_spawn.is_equal_approx(Vector2.INF):
			return curriculum_spawn
	if config != null and config.training_spawn_policy == TRAINING_RESOURCE_CONTEST:
		var resource_contest_spawn := _choose_training_resource_contest_spawn(player, players, candidates, arena_map, config)
		if not resource_contest_spawn.is_equal_approx(Vector2.INF):
			return resource_contest_spawn
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

func _choose_training_engagement_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], candidates: Array[Vector2], arena_map: Node, config: MatchConfig) -> Vector2:
	var best_point := Vector2.INF
	var best_score := -INF
	for point in candidates:
		for other in players:
			if other == player or not other.is_alive:
				continue
			if TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id):
				continue
			var distance := point.distance_to(other.global_position)
			if distance < ENGAGEMENT_MIN_DISTANCE or distance > ENGAGEMENT_MAX_DISTANCE:
				continue
			if arena_map != null and arena_map.has_method("is_line_blocked") and arena_map.is_line_blocked(point, other.global_position):
				continue
			# The initial curriculum guarantees a legal firing lane while retaining
			# enough separation for strafe, chase, and cover behavior to matter.
			var score := 1000.0 - absf(distance - ENGAGEMENT_PREFERRED_DISTANCE) + rng.randf_range(0.0, 1.0)
			if score > best_score:
				best_score = score
				best_point = point
	return best_point

func _choose_training_pressure_curriculum_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], candidates: Array[Vector2], arena_map: Node, config: MatchConfig) -> Vector2:
	# Each respawn samples one of three complementary contexts.  Contact teaches
	# conversion, visible range teaches closing before shooting, and a blocked
	# lane teaches lateral route selection.  The fallback order prevents maps
	# without a usable blocked lane from silently returning to a safe far spawn.
	var roll := rng.randf()
	if roll < 0.35:
		var contact := _choose_training_engagement_spawn(player, players, candidates, arena_map, config)
		if not contact.is_equal_approx(Vector2.INF):
			return contact
	if roll < 0.80:
		var visible_approach := _choose_training_approach_spawn(player, players, candidates, arena_map, config, true)
		if not visible_approach.is_equal_approx(Vector2.INF):
			return visible_approach
	else:
		var blocked_vantage := _choose_training_approach_spawn(player, players, candidates, arena_map, config, false)
		if not blocked_vantage.is_equal_approx(Vector2.INF):
			return blocked_vantage
	var fallback_approach := _choose_training_approach_spawn(player, players, candidates, arena_map, config, true)
	if not fallback_approach.is_equal_approx(Vector2.INF):
		return fallback_approach
	return _choose_training_engagement_spawn(player, players, candidates, arena_map, config)

func _choose_training_resource_contest_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], candidates: Array[Vector2], arena_map: Node, config: MatchConfig) -> Vector2:
	# This training-only policy keeps both agents close enough that a pickup at
	# their midpoint is inside the shared resource-contest radius. It preserves a
	# visible combat lane, so resource pursuit competes with firing rather than
	# replacing it with a separate navigation task.
	var best_point := Vector2.INF
	var best_score := -INF
	for point in candidates:
		for other in players:
			if other == player or not other.is_alive:
				continue
			if TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id):
				continue
			var distance := point.distance_to(other.global_position)
			if distance < RESOURCE_CONTEST_MIN_DISTANCE or distance > RESOURCE_CONTEST_MAX_DISTANCE:
				continue
			if arena_map != null and arena_map.has_method("is_line_blocked") and arena_map.is_line_blocked(point, other.global_position):
				continue
			var score := 1000.0 - absf(distance - RESOURCE_CONTEST_PREFERRED_DISTANCE) + rng.randf_range(0.0, 1.0)
			if score > best_score:
				best_score = score
				best_point = point
	return best_point

func _choose_training_approach_spawn(player: ArenaPlayer, players: Array[ArenaPlayer], candidates: Array[Vector2], arena_map: Node, config: MatchConfig, require_line_of_sight: bool) -> Vector2:
	var best_point := Vector2.INF
	var best_score := -INF
	for point in candidates:
		for other in players:
			if other == player or not other.is_alive:
				continue
			if TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id):
				continue
			var distance := point.distance_to(other.global_position)
			if distance < APPROACH_MIN_DISTANCE or distance > APPROACH_MAX_DISTANCE:
				continue
			var blocked := arena_map != null and arena_map.has_method("is_line_blocked") and bool(arena_map.is_line_blocked(point, other.global_position))
			if blocked == require_line_of_sight:
				continue
			var score := 1000.0 - absf(distance - APPROACH_PREFERRED_DISTANCE) + rng.randf_range(0.0, 1.0)
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
