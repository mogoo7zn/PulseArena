extends PlayerController
# 脚本 AI 控制器，为非训练模式提供可配置难度的机器人行为。
class_name ScriptedAgentController

var difficulty: AgentDifficultyConfig = AgentDifficultyConfig.make("normal")
var rng := RandomNumberGenerator.new()
var decision_timer: float = 0.0
var current_action := PlayerAction.new()
var wander_direction: Vector2 = Vector2.RIGHT

func _init(config: AgentDifficultyConfig = null, seed: int = 0) -> void:
	if config != null:
		difficulty = config
	rng.seed = seed if seed != 0 else 1
	_pick_wander()

func reset() -> void:
	decision_timer = 0.0
	current_action = PlayerAction.new()
	_pick_wander()

func get_action(observation: AgentObservation, delta: float) -> PlayerAction:
	decision_timer -= delta
	if decision_timer <= 0.0:
		decision_timer = 1.0 / maxf(difficulty.decision_rate, 1.0)
		current_action = _decide(observation)
	if current_action == null:
		current_action = PlayerAction.new()
	return current_action.copy()

func get_label() -> String:
	return "AI " + difficulty.name.to_upper()

func _decide(obs: AgentObservation) -> PlayerAction:
	var action := PlayerAction.new()
	if obs == null:
		action.aim = Vector2.RIGHT
		return action
	var target := _select_target(obs)
	var threat := _nearest_dangerous_projectile(obs)
	if target.is_empty():
		if rng.randf() < 0.08:
			_pick_wander()
		action.move = wander_direction
		action.aim = obs.aim_direction
		action.dash = rng.randf() < difficulty.dash_probability * 0.02
		action.normalize_vectors(obs.aim_direction)
		return action
	var target_pos := AgentObservation.dict_to_vec(target.get("relative_position", {}))
	var target_vel := AgentObservation.dict_to_vec(target.get("relative_velocity", {}))
	var distance := maxf(target_pos.length(), 1.0)
	var lead_scale := 0.11
	if difficulty.name == "hard":
		lead_scale = 0.18
	elif difficulty.name == "easy":
		lead_scale = 0.02
	var aim := (target_pos + target_vel * lead_scale).normalized()
	aim = aim.rotated(rng.randfn(0.0, difficulty.aim_noise))
	action.aim = aim
	var desired_move := Vector2.ZERO
	if distance > difficulty.preferred_distance * 1.12:
		desired_move += target_pos.normalized()
	elif distance < difficulty.preferred_distance * 0.72:
		desired_move -= target_pos.normalized()
	else:
		desired_move += target_pos.normalized().orthogonal() * (1.0 if rng.randf() > 0.5 else -1.0)
	if not threat.is_empty():
		var projectile_rel := AgentObservation.dict_to_vec(threat.get("relative_position", {}))
		desired_move += projectile_rel.normalized().orthogonal() * (1.6 if difficulty.name != "easy" else 0.45)
		action.shield = rng.randf() < difficulty.shield_probability
		action.dash = rng.randf() < difficulty.dash_probability
	else:
		action.shield = rng.randf() < difficulty.shield_probability * 0.03 and obs.health_ratio < 0.45
		action.dash = rng.randf() < difficulty.dash_probability * 0.035 and distance < difficulty.preferred_distance * 0.55
	action.move = desired_move.normalized() if desired_move.length_squared() > 0.001 else Vector2.ZERO
	var shoot_chance := difficulty.aggression
	if difficulty.name == "hard" and float(target.get("health_ratio", 1.0)) < 0.35:
		shoot_chance += 0.25
	action.shoot = distance < 760.0 and rng.randf() < shoot_chance
	action.normalize_vectors(obs.aim_direction)
	return action

func _select_target(obs: AgentObservation) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for candidate in obs.other_players:
		if not bool(candidate.get("valid", false)):
			continue
		if bool(candidate.get("is_teammate", false)):
			continue
		if not bool(candidate.get("is_alive", false)):
			continue
		var rel := AgentObservation.dict_to_vec(candidate.get("relative_position", {}))
		var score_value := rel.length()
		if difficulty.name == "hard":
			score_value *= lerpf(0.55, 1.25, float(candidate.get("health_ratio", 1.0)))
		if score_value < best_score:
			best_score = score_value
			best = candidate
	return best

func _nearest_dangerous_projectile(obs: AgentObservation) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := 999999.0
	for projectile in obs.projectiles:
		if not bool(projectile.get("valid", false)):
			continue
		if bool(projectile.get("is_own", false)) or bool(projectile.get("is_teammate", false)):
			continue
		var rel := AgentObservation.dict_to_vec(projectile.get("relative_position", {}))
		var vel := AgentObservation.dict_to_vec(projectile.get("relative_velocity", {}))
		var approaching := vel.dot(-rel) > 0.0
		var dist := rel.length()
		if approaching and dist < 180.0 and dist < best_dist:
			best_dist = dist
			best = projectile
	return best

func _pick_wander() -> void:
	wander_direction = Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))
