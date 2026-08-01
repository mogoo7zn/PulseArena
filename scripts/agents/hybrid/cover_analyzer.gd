extends RefCounted
# Cover and local safety helpers based on public map geometry rays.
class_name CoverAnalyzer

const HybridAgentConfig = preload("res://scripts/agents/hybrid/hybrid_agent_config.gd")

const EPS := 0.00001

func analyze(obs: AgentObservation, target: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig) -> Dictionary:
	var result := {
		"nearest_wall_distance_ratio": 1.0,
		"nearest_wall_direction": Vector2.ZERO,
		"corner_score": 0.0,
		"cover_direction": Vector2.ZERO,
		"safe_space_direction": Vector2.ZERO,
		"has_cover_target": false,
	}
	if obs == null:
		return result
	var nearest := _nearest_ray(obs)
	result["nearest_wall_distance_ratio"] = nearest.get("distance_ratio", 1.0)
	result["nearest_wall_direction"] = nearest.get("direction", Vector2.ZERO)
	result["corner_score"] = _corner_score(obs)
	var safe_dir := _safe_space_from_rays(obs)
	result["safe_space_direction"] = safe_dir
	var cover_dir := _cover_direction(obs, target, arena_map, balance, config)
	result["cover_direction"] = cover_dir
	result["has_cover_target"] = cover_dir.length_squared() > EPS
	return result

func would_hit_wall(obs: AgentObservation, direction: Vector2, arena_map: Node, balance: GameBalance, distance: float) -> bool:
	if obs == null or direction.length_squared() <= EPS:
		return false
	var map := arena_map
	if map != null and map.has_method("ray_distance"):
		return float(map.ray_distance(obs.position, direction.normalized(), distance)) < distance - 4.0
	if map != null and map.has_method("is_spawn_area_clear"):
		var point := obs.position + direction.normalized() * distance
		return not bool(map.is_spawn_area_clear(point, balance.player_radius if balance != null else 22.0))
	return false

func candidate_is_safe(obs: AgentObservation, direction: Vector2, arena_map: Node, balance: GameBalance, distance: float = 88.0) -> bool:
	if obs == null or direction.length_squared() <= EPS:
		return false
	if would_hit_wall(obs, direction, arena_map, balance, distance):
		return false
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var margin := (balance.player_radius if balance != null else 22.0) * 1.25
	var point := obs.position + direction.normalized() * distance
	return point.x >= margin and point.y >= margin and point.x <= map_size.x - margin and point.y <= map_size.y - margin

func _cover_direction(obs: AgentObservation, target: Dictionary, arena_map: Node, balance: GameBalance, config: HybridAgentConfig) -> Vector2:
	if target.is_empty() or not bool(target.get("valid", false)):
		return _safe_space_from_rays(obs)
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var target_world := obs.position + AgentObservation.dict_to_vec(target.get("relative_position", {})) * map_size
	var to_target := target_world - obs.position
	var best_dir := Vector2.ZERO
	var best_score := -INF
	var probe := config.cover_probe_distance if config != null else 220.0
	for i in range(16):
		var dir := Vector2.RIGHT.rotated(TAU * float(i) / 16.0)
		if not candidate_is_safe(obs, dir, arena_map, balance, probe * 0.34):
			continue
		var candidate := obs.position + dir * probe * 0.45
		var breaks_los := false
		if arena_map != null and arena_map.has_method("is_line_blocked"):
			breaks_los = bool(arena_map.is_line_blocked(candidate, target_world))
		var distance_to_target := candidate.distance_to(target_world)
		var wall_distance := float(arena_map.ray_distance(candidate, -to_target.normalized(), probe)) if arena_map != null and arena_map.has_method("ray_distance") and to_target.length_squared() > EPS else probe
		var score := 0.0
		score += 0.65 if breaks_los else 0.0
		score += 0.25 * (1.0 - clampf(wall_distance / probe, 0.0, 1.0))
		score += 0.18 * (1.0 - clampf(absf(distance_to_target - 420.0) / 420.0, 0.0, 1.0))
		score += 0.08 * dir.dot(_safe_space_from_rays(obs))
		if score > best_score:
			best_score = score
			best_dir = dir
	return best_dir.normalized() if best_dir.length_squared() > EPS else Vector2.ZERO

func _nearest_ray(obs: AgentObservation) -> Dictionary:
	var best_distance := 1.0
	var best_dir := Vector2.ZERO
	for i in range(obs.ray_results.size()):
		var value := clampf(obs.ray_results[i], 0.0, 1.0)
		if value < best_distance:
			best_distance = value
			best_dir = Vector2.RIGHT.rotated(TAU * float(i) / float(maxi(obs.ray_results.size(), 1)))
	for i in range(obs.boundary_distances.size()):
		var value := clampf(obs.boundary_distances[i], 0.0, 1.0)
		if value < best_distance:
			best_distance = value
			match i:
				0:
					best_dir = Vector2.LEFT
				1:
					best_dir = Vector2.RIGHT
				2:
					best_dir = Vector2.UP
				3:
					best_dir = Vector2.DOWN
	return {"distance_ratio": best_distance, "direction": best_dir}

func _safe_space_from_rays(obs: AgentObservation) -> Vector2:
	var dir := Vector2.ZERO
	for i in range(obs.ray_results.size()):
		var ray_dir := Vector2.RIGHT.rotated(TAU * float(i) / float(maxi(obs.ray_results.size(), 1)))
		var value := clampf(obs.ray_results[i], 0.0, 1.0)
		dir += ray_dir * (value - 0.35)
	if obs.boundary_distances.size() >= 4:
		dir += Vector2.RIGHT * (obs.boundary_distances[0] - obs.boundary_distances[1])
		dir += Vector2.DOWN * (obs.boundary_distances[2] - obs.boundary_distances[3])
	return dir.normalized() if dir.length_squared() > EPS else Vector2.ZERO

func _corner_score(obs: AgentObservation) -> float:
	var low_boundaries := 0
	for value in obs.boundary_distances:
		if value < 0.065:
			low_boundaries += 1
	var low_rays := 0
	for value in obs.ray_results:
		if value < 0.14:
			low_rays += 1
	return clampf(float(low_boundaries) * 0.35 + float(low_rays) / float(maxi(obs.ray_results.size(), 1)), 0.0, 1.0)
