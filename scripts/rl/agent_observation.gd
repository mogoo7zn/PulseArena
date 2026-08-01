extends RefCounted
# 智能体观测数据结构，保存模型或脚本策略需要读取的状态快照。
class_name AgentObservation

const MAX_OTHER_PLAYERS := 3
const MAX_PROJECTILES := 24
const RAY_COUNT := 16

var player_id: int = -1
var team_id: int = -1
var position: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var aim_direction: Vector2 = Vector2.RIGHT
var health_ratio: float = 1.0
var energy_ratio: float = 1.0
var shoot_cooldown_ratio: float = 0.0
var dash_cooldown_ratio: float = 0.0
var shield_cooldown_ratio: float = 0.0
var is_alive: bool = true
var is_shielding: bool = false
var has_respawn_protection: bool = false
var score: int = 0
var remaining_time_ratio: float = 1.0
var other_players: Array[Dictionary] = []
var projectiles: Array[Dictionary] = []
var boundary_distances: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
var ray_results: PackedFloat32Array = PackedFloat32Array()
var nearest_resource_relative_position: Vector2 = Vector2.ZERO
var map_id: int = 0
var game_mode_id: int = 0

func _init() -> void:
	ray_results.resize(RAY_COUNT)
	for i in range(RAY_COUNT):
		ray_results[i] = 1.0

func to_dict() -> Dictionary:
	return {
		"self": {
			"player_id": player_id,
			"team_id": team_id,
			"position": vec_to_dict(position),
			"velocity": vec_to_dict(velocity),
			"aim_direction": vec_to_dict(aim_direction),
			"health_ratio": health_ratio,
			"energy_ratio": energy_ratio,
			"shoot_cooldown_ratio": shoot_cooldown_ratio,
			"dash_cooldown_ratio": dash_cooldown_ratio,
			"shield_cooldown_ratio": shield_cooldown_ratio,
			"is_alive": is_alive,
			"is_shielding": is_shielding,
			"has_respawn_protection": has_respawn_protection,
			"score": score,
			"remaining_time_ratio": remaining_time_ratio,
		},
		"other_players": other_players,
		"projectiles": projectiles,
		"map": {
			"boundary_distances": Array(boundary_distances),
			"ray_results": Array(ray_results),
			"nearest_resource_relative_position": vec_to_dict(nearest_resource_relative_position),
			"map_id": map_id,
			"game_mode_id": game_mode_id,
		},
	}

func to_flat_array() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	append_values(out, [
		float(player_id),
		float(team_id),
		position.x,
		position.y,
		velocity.x,
		velocity.y,
		aim_direction.x,
		aim_direction.y,
		health_ratio,
		energy_ratio,
		shoot_cooldown_ratio,
		dash_cooldown_ratio,
		shield_cooldown_ratio,
		1.0 if is_alive else 0.0,
		1.0 if is_shielding else 0.0,
		1.0 if has_respawn_protection else 0.0,
		float(score),
		remaining_time_ratio,
	])
	for i in range(MAX_OTHER_PLAYERS):
		var p: Dictionary = other_players[i] if i < other_players.size() else empty_player()
		append_values(out, player_to_flat(p))
	for i in range(MAX_PROJECTILES):
		var projectile: Dictionary = projectiles[i] if i < projectiles.size() else empty_projectile()
		append_values(out, projectile_to_flat(projectile))
	for value in boundary_distances:
		out.append(value)
	for value in ray_results:
		out.append(value)
	out.append(nearest_resource_relative_position.x)
	out.append(nearest_resource_relative_position.y)
	out.append(float(map_id))
	out.append(float(game_mode_id))
	return out

static func from_dict(data: Dictionary) -> AgentObservation:
	var obs := AgentObservation.new()
	var self_data: Dictionary = data.get("self", {})
	obs.player_id = int(self_data.get("player_id", -1))
	obs.team_id = int(self_data.get("team_id", -1))
	obs.position = dict_to_vec(self_data.get("position", {}))
	obs.velocity = dict_to_vec(self_data.get("velocity", {}))
	obs.aim_direction = dict_to_vec(self_data.get("aim_direction", {"x": 1.0, "y": 0.0}))
	obs.health_ratio = float(self_data.get("health_ratio", 1.0))
	obs.energy_ratio = float(self_data.get("energy_ratio", 1.0))
	obs.shoot_cooldown_ratio = float(self_data.get("shoot_cooldown_ratio", 0.0))
	obs.dash_cooldown_ratio = float(self_data.get("dash_cooldown_ratio", 0.0))
	obs.shield_cooldown_ratio = float(self_data.get("shield_cooldown_ratio", 0.0))
	obs.is_alive = bool(self_data.get("is_alive", true))
	obs.is_shielding = bool(self_data.get("is_shielding", false))
	obs.has_respawn_protection = bool(self_data.get("has_respawn_protection", false))
	obs.score = int(self_data.get("score", 0))
	obs.remaining_time_ratio = float(self_data.get("remaining_time_ratio", 1.0))
	obs.other_players = data.get("other_players", [])
	obs.projectiles = data.get("projectiles", [])
	var map_data: Dictionary = data.get("map", {})
	obs.boundary_distances = PackedFloat32Array(map_data.get("boundary_distances", [1.0, 1.0, 1.0, 1.0]))
	obs.ray_results = PackedFloat32Array(map_data.get("ray_results", []))
	obs.nearest_resource_relative_position = dict_to_vec(map_data.get("nearest_resource_relative_position", {}))
	obs.map_id = int(map_data.get("map_id", 0))
	obs.game_mode_id = int(map_data.get("game_mode_id", 0))
	return obs

static func vec_to_dict(v: Vector2) -> Dictionary:
	return {"x": v.x, "y": v.y}

static func dict_to_vec(data: Variant) -> Vector2:
	if data is Dictionary:
		return Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	return Vector2.ZERO

static func empty_player() -> Dictionary:
	return {
		"relative_position": {"x": 0.0, "y": 0.0},
		"relative_velocity": {"x": 0.0, "y": 0.0},
		"aim_direction": {"x": 1.0, "y": 0.0},
		"health_ratio": 0.0,
		"is_teammate": false,
		"is_alive": false,
		"is_shielding": false,
		"is_dashing": false,
		"has_respawn_protection": false,
		"valid": false,
	}

static func empty_projectile() -> Dictionary:
	return {
		"relative_position": {"x": 0.0, "y": 0.0},
		"relative_velocity": {"x": 0.0, "y": 0.0},
		"is_own": false,
		"is_teammate": false,
		"lifetime_ratio": 0.0,
		"damage_ratio": 0.0,
		"valid": false,
	}

static func player_to_flat(data: Dictionary) -> Array[float]:
	var rel := dict_to_vec(data.get("relative_position", {}))
	var vel := dict_to_vec(data.get("relative_velocity", {}))
	var aim := dict_to_vec(data.get("aim_direction", {"x": 1.0, "y": 0.0}))
	return [
		rel.x,
		rel.y,
		vel.x,
		vel.y,
		aim.x,
		aim.y,
		float(data.get("health_ratio", 0.0)),
		1.0 if bool(data.get("is_teammate", false)) else 0.0,
		1.0 if bool(data.get("is_alive", false)) else 0.0,
		1.0 if bool(data.get("is_shielding", false)) else 0.0,
		1.0 if bool(data.get("is_dashing", false)) else 0.0,
		1.0 if bool(data.get("has_respawn_protection", false)) else 0.0,
		1.0 if bool(data.get("valid", false)) else 0.0,
	]

static func projectile_to_flat(data: Dictionary) -> Array[float]:
	var rel := dict_to_vec(data.get("relative_position", {}))
	var vel := dict_to_vec(data.get("relative_velocity", {}))
	return [
		rel.x,
		rel.y,
		vel.x,
		vel.y,
		1.0 if bool(data.get("is_own", false)) else 0.0,
		1.0 if bool(data.get("is_teammate", false)) else 0.0,
		float(data.get("lifetime_ratio", 0.0)),
		float(data.get("damage_ratio", 0.0)),
		1.0 if bool(data.get("valid", false)) else 0.0,
	]

static func append_values(out: PackedFloat32Array, values: Array) -> void:
	for value in values:
		out.append(float(value))
