extends RefCounted
# Computes projectile collision risk and candidate evasive directions.
class_name ProjectileThreatAnalyzer

const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")

const EPS := 0.00001

func analyze(obs: AgentObservation, balance: GameBalance, config: HybridAgentConfig) -> Dictionary:
	var result := {
		"has_threat": false,
		"defense_priority": false,
		"threat_level": 0.0,
		"time_to_hit": 999.0,
		"closest_distance": INF,
		"primary_threat": {},
		"recommended_direction": Vector2.ZERO,
		"candidate_directions": [],
		"risk_by_direction": {},
		"bullet_density": 0.0,
	}
	if obs == null:
		return result
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var projectile_speed := balance.projectile_speed if balance != null else 850.0
	var projectile_lifetime := balance.projectile_lifetime if balance != null else 1.4
	var player_radius := balance.player_radius if balance != null else 22.0
	var projectile_radius := balance.projectile_radius if balance != null else 7.0
	var hit_radius := player_radius + projectile_radius + (config.projectile_prediction_margin if config != null else 18.0)
	var threats: Array[Dictionary] = []
	var nearby_count := 0
	for projectile in obs.projectiles:
		if not bool(projectile.get("valid", false)):
			continue
		if bool(projectile.get("is_own", false)) or bool(projectile.get("is_teammate", false)):
			continue
		var rel := AgentObservation.dict_to_vec(projectile.get("relative_position", {})) * map_size
		var vel := AgentObservation.dict_to_vec(projectile.get("relative_velocity", {})) * projectile_speed
		if not _valid_vector(rel) or not _valid_vector(vel):
			continue
		var speed_sq := vel.length_squared()
		if speed_sq <= EPS:
			continue
		var lifetime_left := clampf(float(projectile.get("lifetime_ratio", 0.0)), 0.0, 1.0) * projectile_lifetime
		var tca := clampf(-rel.dot(vel) / speed_sq, 0.0, lifetime_left)
		var closest := rel + vel * tca
		var closest_distance := closest.length()
		var current_distance := rel.length()
		if current_distance < 360.0:
			nearby_count += 1
		var approaching := vel.dot(-rel) > 0.0
		var predicted_hit := approaching and lifetime_left > 0.0 and closest_distance <= hit_radius and tca <= lifetime_left
		var level := _threat_level(predicted_hit, tca, closest_distance, current_distance, hit_radius, lifetime_left)
		if level <= 0.02:
			continue
		var incoming_dir := vel.normalized()
		var away := (-rel).normalized() if rel.length_squared() > EPS else -incoming_dir
		var left := incoming_dir.orthogonal()
		var right := -left
		var threat := {
			"relative_position": rel,
			"relative_velocity": vel,
			"time_to_closest": tca,
			"closest_distance": closest_distance,
			"predicted_hit": predicted_hit,
			"lifetime_left": lifetime_left,
			"threat_level": level,
			"incoming_direction": incoming_dir,
			"left_evasion": left,
			"right_evasion": right,
			"away_evasion": away,
		}
		threats.append(threat)
	threats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("threat_level", 0.0)) > float(b.get("threat_level", 0.0))
	)
	result["bullet_density"] = clampf(float(nearby_count) / 8.0, 0.0, 1.0)
	if threats.is_empty():
		return result
	var primary := threats[0]
	result["has_threat"] = true
	result["primary_threat"] = primary
	result["threat_level"] = float(primary.get("threat_level", 0.0))
	result["time_to_hit"] = float(primary.get("time_to_closest", 999.0))
	result["closest_distance"] = float(primary.get("closest_distance", INF))
	result["defense_priority"] = float(result["threat_level"]) >= (config.high_threat_threshold if config != null else 0.72)
	var candidates := _candidate_directions(primary)
	result["candidate_directions"] = candidates
	var risks := {}
	var best_dir := Vector2.ZERO
	var best_score := INF
	for direction in candidates:
		var d: Vector2 = direction
		if d.length_squared() <= EPS:
			continue
		var risk := score_direction(obs, d.normalized(), threats, balance)
		risks[_dir_key(d)] = risk
		if risk < best_score:
			best_score = risk
			best_dir = d.normalized()
	result["risk_by_direction"] = risks
	result["recommended_direction"] = best_dir
	return result

func score_direction(obs: AgentObservation, direction: Vector2, threats: Array, balance: GameBalance) -> float:
	if obs == null or direction.length_squared() <= EPS:
		return 1.0
	var map_size := balance.map_size if balance != null else Vector2(2160, 1215)
	var step_distance := (balance.move_speed if balance != null else 260.0) * 0.28
	var future_offset := direction.normalized() * step_distance
	var risk := 0.0
	for threat in threats:
		var rel: Vector2 = threat.get("relative_position", Vector2.ZERO)
		var vel: Vector2 = threat.get("relative_velocity", Vector2.ZERO)
		var speed_sq := vel.length_squared()
		if speed_sq <= EPS:
			continue
		var future_rel := rel - future_offset
		var tca := clampf(-future_rel.dot(vel) / speed_sq, 0.0, float(threat.get("lifetime_left", 1.0)))
		var closest := (future_rel + vel * tca).length()
		var base_level := float(threat.get("threat_level", 0.0))
		risk += base_level * (1.0 - clampf(closest / 140.0, 0.0, 1.0))
	var future_pos := obs.position + future_offset
	var margin := balance.player_radius if balance != null else 22.0
	var boundary := minf(minf(future_pos.x, map_size.x - future_pos.x), minf(future_pos.y, map_size.y - future_pos.y))
	if boundary < margin * 2.0:
		risk += 0.55
	return clampf(risk, 0.0, 2.0)

static func _candidate_directions(primary: Dictionary) -> Array[Vector2]:
	var incoming: Vector2 = primary.get("incoming_direction", Vector2.RIGHT)
	var left: Vector2 = primary.get("left_evasion", incoming.orthogonal())
	var right: Vector2 = primary.get("right_evasion", -incoming.orthogonal())
	var away: Vector2 = primary.get("away_evasion", -incoming)
	return [
		left.normalized(),
		right.normalized(),
		away.normalized(),
		(left + away * 0.35).normalized(),
		(right + away * 0.35).normalized(),
		Vector2.ZERO,
	]

static func _threat_level(predicted_hit: bool, tca: float, closest_distance: float, current_distance: float, hit_radius: float, lifetime_left: float) -> float:
	if lifetime_left <= 0.0:
		return 0.0
	var time_score := 1.0 - clampf(tca / 1.2, 0.0, 1.0)
	var distance_score := 1.0 - clampf((closest_distance - hit_radius) / 160.0, 0.0, 1.0)
	var proximity_score := 1.0 - clampf(current_distance / 520.0, 0.0, 1.0)
	var hit_bonus := 0.36 if predicted_hit else 0.0
	return clampf(time_score * 0.44 + distance_score * 0.36 + proximity_score * 0.20 + hit_bonus, 0.0, 1.0)

static func _dir_key(direction: Vector2) -> String:
	if direction.length_squared() <= EPS:
		return "ignore"
	var angle := roundi(rad_to_deg(direction.angle()))
	return str(angle)

static func _valid_vector(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
