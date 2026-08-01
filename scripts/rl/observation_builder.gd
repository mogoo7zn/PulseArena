extends RefCounted
# 观测构建器，将玩家、地图、子弹和道具状态编码为 AI 输入。
class_name ObservationBuilder

const RAY_DISTANCE := 620.0

static func build(player: ArenaPlayer, players: Array[ArenaPlayer], projectiles: Array[ArenaProjectile], balance: GameBalance, config: MatchConfig, arena_map: ArenaCross, remaining_ratio: float, score: int, validate_private_fields: bool = false, pickups: Array = []) -> AgentObservation:
	var obs := AgentObservation.new()
	obs.player_id = player.player_id
	obs.team_id = player.team_id
	obs.position = player.global_position
	obs.velocity = player.velocity
	obs.aim_direction = player.aim_direction
	obs.health_ratio = player.get_health_ratio()
	obs.energy_ratio = player.get_energy_ratio()
	obs.shoot_cooldown_ratio = player.get_shoot_cooldown_ratio()
	obs.dash_cooldown_ratio = player.get_dash_cooldown_ratio()
	obs.shield_cooldown_ratio = player.get_shield_cooldown_ratio()
	obs.is_alive = player.is_alive
	obs.is_shielding = player.is_shielding()
	obs.has_respawn_protection = player.has_respawn_protection()
	obs.score = score
	obs.remaining_time_ratio = remaining_ratio
	obs.boundary_distances = _boundary_distances(player.global_position, balance.map_size)
	obs.ray_results = _ray_results(player.global_position, arena_map)
	obs.nearest_resource_relative_position = _nearest_pickup_relative_position(player, pickups, balance)
	obs.map_id = _map_id(config)
	obs.game_mode_id = 1 if config.team_mode else 0
	obs.other_players = _other_players(player, players, balance, config)
	if validate_private_fields and _contains_private_fields(obs.other_players):
		push_error("ObservationBuilder leaked private opponent fields")
	obs.projectiles = _projectiles(player, projectiles, balance, config)
	return obs

static func build_observation_for_actor(player: ArenaPlayer, players: Array[ArenaPlayer], projectiles: Array[ArenaProjectile], balance: GameBalance, config: MatchConfig, arena_map: ArenaCross, remaining_ratio: float, score: int, pickups: Array = []) -> AgentObservation:
	return build(player, players, projectiles, balance, config, arena_map, remaining_ratio, score, false, pickups)

static func _other_players(player: ArenaPlayer, players: Array[ArenaPlayer], balance: GameBalance, config: MatchConfig) -> Array[Dictionary]:
	var candidates: Array[ArenaPlayer] = []
	for other in players:
		if other == player:
			continue
		candidates.append(other)
	candidates.sort_custom(func(a: ArenaPlayer, b: ArenaPlayer) -> bool:
		return player.global_position.distance_squared_to(a.global_position) < player.global_position.distance_squared_to(b.global_position)
	)
	var out: Array[Dictionary] = []
	for i in range(mini(AgentObservation.MAX_OTHER_PLAYERS, candidates.size())):
		var other := candidates[i]
		out.append({
			"relative_position": AgentObservation.vec_to_dict((other.global_position - player.global_position) / balance.map_size),
			"relative_velocity": AgentObservation.vec_to_dict(other.velocity / balance.projectile_speed),
			"aim_direction": AgentObservation.vec_to_dict(other.aim_direction),
			"health_ratio": other.get_health_ratio(),
			"is_teammate": TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id),
			"is_alive": other.is_alive,
			"is_shielding": other.is_shielding(),
			"is_dashing": other.is_dashing(),
			"has_respawn_protection": other.has_respawn_protection(),
			"valid": true,
		})
	while out.size() < AgentObservation.MAX_OTHER_PLAYERS:
		out.append(AgentObservation.empty_player())
	return out

static func _projectiles(player: ArenaPlayer, projectiles: Array[ArenaProjectile], balance: GameBalance, config: MatchConfig) -> Array[Dictionary]:
	var candidates: Array[ArenaProjectile] = []
	var distances: Array[float] = []
	for projectile in projectiles:
		_insert_projectile_candidate(candidates, distances, projectile, player.global_position.distance_squared_to(projectile.global_position))
	var out: Array[Dictionary] = []
	for i in range(mini(AgentObservation.MAX_PROJECTILES, candidates.size())):
		var projectile: ArenaProjectile = candidates[i]
		var is_own := projectile.owner_id == player.player_id
		var is_teammate := TeamRules.are_teammates(config, player.team_id, projectile.owner_team_id, player.player_id, projectile.owner_id)
		out.append({
			"relative_position": AgentObservation.vec_to_dict((projectile.global_position - player.global_position) / balance.map_size),
			"relative_velocity": AgentObservation.vec_to_dict(projectile.velocity / balance.projectile_speed),
			"is_own": is_own,
			"is_teammate": is_teammate,
			"lifetime_ratio": projectile.get_lifetime_ratio(),
			"damage_ratio": clampf(projectile.damage / balance.max_health, 0.0, 1.0),
			"valid": true,
		})
	while out.size() < AgentObservation.MAX_PROJECTILES:
		out.append(AgentObservation.empty_projectile())
	return out

static func _insert_projectile_candidate(candidates: Array[ArenaProjectile], distances: Array[float], projectile: ArenaProjectile, distance_sq: float) -> void:
	if projectile == null:
		return
	var insert_at := candidates.size()
	for i in range(distances.size()):
		if distance_sq < distances[i]:
			insert_at = i
			break
	if insert_at >= AgentObservation.MAX_PROJECTILES:
		return
	candidates.insert(insert_at, projectile)
	distances.insert(insert_at, distance_sq)
	if candidates.size() > AgentObservation.MAX_PROJECTILES:
		candidates.pop_back()
		distances.pop_back()

static func _boundary_distances(position: Vector2, map_size: Vector2) -> PackedFloat32Array:
	return PackedFloat32Array([
		clampf(position.x / map_size.x, 0.0, 1.0),
		clampf((map_size.x - position.x) / map_size.x, 0.0, 1.0),
		clampf(position.y / map_size.y, 0.0, 1.0),
		clampf((map_size.y - position.y) / map_size.y, 0.0, 1.0),
	])

static func _nearest_pickup_relative_position(player: ArenaPlayer, pickups: Array, balance: GameBalance) -> Vector2:
	var best_distance_sq := INF
	var best_position := Vector2.ZERO
	for pickup in pickups:
		if pickup == null or not is_instance_valid(pickup):
			continue
		var distance_sq: float = player.global_position.distance_squared_to(pickup.global_position)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_position = pickup.global_position
	if best_distance_sq == INF:
		return Vector2.ZERO
	return (best_position - player.global_position) / balance.map_size

static func _map_id(config: MatchConfig) -> int:
	match config.map_id:
		MatchConfig.MAP_SKY_CITY, "neon_docks":
			return 1
		MatchConfig.MAP_JUNGLE, "reactor_ring":
			return 2
		MatchConfig.MAP_MIST_WORLD, "skyline_yard":
			return 3
	return 0

static func _ray_results(position: Vector2, arena_map: ArenaCross) -> PackedFloat32Array:
	var rays := PackedFloat32Array()
	rays.resize(AgentObservation.RAY_COUNT)
	for i in range(AgentObservation.RAY_COUNT):
		var dir := Vector2.RIGHT.rotated(TAU * float(i) / float(AgentObservation.RAY_COUNT))
		var distance := arena_map.ray_distance(position, dir, RAY_DISTANCE)
		rays[i] = clampf(distance / RAY_DISTANCE, 0.0, 1.0)
	return rays

static func _contains_private_fields(data: Variant) -> bool:
	if data is Dictionary:
		for key in data.keys():
			if _is_private_key(str(key)):
				return true
			if _contains_private_fields(data[key]):
				return true
	elif data is Array:
		for item in data:
			if _contains_private_fields(item):
				return true
	return false

static func _is_private_key(key: String) -> bool:
	var normalized := key.to_lower().replace("-", "_")
	var compact := normalized.replace("_", "")
	var private_tokens := PackedStringArray([
		"ammo",
		"reserve",
		"magazine",
		"reloadremaining",
		"reload_remaining",
		"reloadtimer",
		"reload_timer",
		"weaponcooldown",
		"weapon_cooldown",
		"shootcooldown",
		"shoot_cooldown",
		"energy",
	])
	for token in private_tokens:
		var t := String(token).to_lower()
		if normalized == t or compact == t.replace("_", ""):
			return true
		if normalized.find(t) >= 0 or compact.find(t.replace("_", "")) >= 0:
			return true
	return false
