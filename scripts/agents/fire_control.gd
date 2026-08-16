extends RefCounted
# Deterministic fire gate for high-level tactical fire modes.
class_name FireControl

const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid_agent_config.gd")

var burst_remaining: int = 0
var burst_recovery_timer: float = 0.0
var last_valid_target_timer: float = 999.0
var last_fire_block_reason: String = "init"

func reset() -> void:
	burst_remaining = 0
	burst_recovery_timer = 0.0
	last_valid_target_timer = 999.0
	last_fire_block_reason = "reset"

func update(obs: AgentObservation, decision: HighLevelDecision, scripted_action: PlayerAction, aim_solution: Dictionary, threat_info: Dictionary, balance: GameBalance, config: HybridAgentConfig, delta: float) -> Dictionary:
	burst_recovery_timer = maxf(0.0, burst_recovery_timer - delta)
	last_valid_target_timer += delta
	var diag := _base_diag()
	var fire_mode := decision.fire_mode if decision != null else HighLevelDecision.FireMode.HOLD_FIRE
	if fire_mode == HighLevelDecision.FireMode.USE_SCRIPTED_FIRE_MODE and scripted_action != null:
		fire_mode = HighLevelDecision.FireMode.NORMAL if scripted_action.shoot else HighLevelDecision.FireMode.HOLD_FIRE
	diag["fire_mode"] = fire_mode
	diag["burst_state"] = _burst_state()
	if obs == null or not obs.is_alive:
		return _blocked(diag, "self_not_alive")
	diag["actionable_window"] = _has_actionable_window(obs, aim_solution, threat_info, balance, config)
	if fire_mode == HighLevelDecision.FireMode.HOLD_FIRE:
		return _blocked(diag, "hold_fire")
	if not bool(aim_solution.get("valid_target", false)):
		return _blocked(diag, "no_target")
	last_valid_target_timer = 0.0
	if not bool(aim_solution.get("has_solution", false)):
		return _blocked(diag, str(aim_solution.get("reason", "no_intercept")))
	if not bool(aim_solution.get("line_of_sight", false)):
		return _blocked(diag, "no_line_of_sight")
	if bool(aim_solution.get("wall_blocked", false)):
		return _blocked(diag, "wall_blocked")
	if not bool(aim_solution.get("within_lifetime", false)):
		return _blocked(diag, "out_of_lifetime")
	if bool(aim_solution.get("friendly_fire_risk", false)):
		return _blocked(diag, "friendly_fire_risk")
	if bool(aim_solution.get("target_invulnerable", false)):
		return _blocked(diag, "target_invulnerable")
	if obs.shoot_cooldown_ratio > 0.001:
		return _blocked(diag, "weapon_cooldown")
	var energy := obs.energy_ratio * balance.max_energy
	var reserve_info := _reserve_info(obs, aim_solution, threat_info, balance, config, fire_mode)
	var reserved := float(reserve_info.get("reserved_energy", 0.0))
	diag["reserved_energy"] = reserved
	diag["reserve_ratio"] = float(reserve_info.get("reserve_ratio", 0.0))
	diag["reserve_basis"] = str(reserve_info.get("reserve_basis", "base"))
	var projectile_cost := balance.projectile_energy_cost
	var kill_window := _kill_window(aim_solution, balance)
	if energy + 0.001 < projectile_cost + reserved:
		return _blocked(diag, "reserved_energy")
	var hit_probability := clampf(float(aim_solution.get("predicted_hit_probability", 0.0)), 0.0, 1.0)
	var aim_error := clampf(float(aim_solution.get("aim_error", PI)), 0.0, PI)
	diag["predicted_hit_probability"] = hit_probability
	diag["aim_error"] = aim_error
	if bool(threat_info.get("defense_priority", false)) and fire_mode != HighLevelDecision.FireMode.ALL_IN:
		return _blocked(diag, "defense_priority")
	var min_hit := _hit_threshold(fire_mode, config, kill_window)
	var max_error := _aim_error_threshold(fire_mode, config, kill_window)
	if hit_probability + 0.0001 < min_hit:
		return _blocked(diag, "low_hit_probability")
	if aim_error > max_error:
		return _blocked(diag, "aim_error")
	if fire_mode == HighLevelDecision.FireMode.BURST:
		if burst_recovery_timer > 0.0:
			return _blocked(diag, "burst_recovery")
		if burst_remaining <= 0:
			burst_remaining = maxi(1, config.burst_size)
		burst_remaining -= 1
		if burst_remaining <= 0:
			burst_recovery_timer = config.burst_recovery
		diag["burst_state"] = _burst_state()
	elif fire_mode == HighLevelDecision.FireMode.ALL_IN:
		if not kill_window:
			return _blocked(diag, "all_in_requires_kill_window")
	else:
		burst_remaining = 0
	diag["fire_allowed"] = true
	diag["fire_block_reason"] = ""
	last_fire_block_reason = ""
	return diag

func _base_diag() -> Dictionary:
	return {
		"fire_allowed": false,
		"actionable_window": false,
		"fire_block_reason": "init",
		"predicted_hit_probability": 0.0,
		"aim_error": PI,
		"reserved_energy": 0.0,
		"reserve_ratio": 0.0,
		"reserve_basis": "base",
		"burst_state": _burst_state(),
	}

func _blocked(diag: Dictionary, reason: String) -> Dictionary:
	diag["fire_allowed"] = false
	diag["fire_block_reason"] = reason
	last_fire_block_reason = reason
	if reason != "burst_recovery" and reason != "weapon_cooldown":
		if reason != "":
			burst_remaining = 0
	return diag

func _has_actionable_window(obs: AgentObservation, aim_solution: Dictionary, threat_info: Dictionary, balance: GameBalance, config: HybridAgentConfig) -> bool:
	if obs == null or not obs.is_alive:
		return false
	if not bool(aim_solution.get("valid_target", false)) or not bool(aim_solution.get("has_solution", false)):
		return false
	if not bool(aim_solution.get("line_of_sight", false)) or bool(aim_solution.get("wall_blocked", false)):
		return false
	if not bool(aim_solution.get("within_lifetime", false)) or bool(aim_solution.get("friendly_fire_risk", false)) or bool(aim_solution.get("target_invulnerable", false)):
		return false
	if obs.shoot_cooldown_ratio > 0.001 or bool(threat_info.get("defense_priority", false)):
		return false
	var reserved := float(_reserve_info(obs, aim_solution, threat_info, balance, config, HighLevelDecision.FireMode.NORMAL).get("reserved_energy", 0.0))
	if obs.energy_ratio * balance.max_energy + 0.001 < balance.projectile_energy_cost + reserved:
		return false
	var hit_probability := clampf(float(aim_solution.get("predicted_hit_probability", 0.0)), 0.0, 1.0)
	var aim_error := clampf(float(aim_solution.get("aim_error", PI)), 0.0, PI)
	var kill_window := _kill_window(aim_solution, balance)
	return hit_probability + 0.0001 >= _hit_threshold(HighLevelDecision.FireMode.NORMAL, config, kill_window) and aim_error <= _aim_error_threshold(HighLevelDecision.FireMode.NORMAL, config, kill_window)

func _reserve_info(obs: AgentObservation, aim_solution: Dictionary, threat_info: Dictionary, balance: GameBalance, config: HybridAgentConfig, fire_mode: int) -> Dictionary:
	var reserve_ratio := config.base_reserved_energy_ratio
	var reserve_basis := "base"
	if obs.health_ratio < 0.36 and config.defensive_reserved_energy_ratio > reserve_ratio:
		reserve_ratio = maxf(reserve_ratio, config.defensive_reserved_energy_ratio)
		reserve_basis = "low_health"
	if obs.dash_cooldown_ratio <= 0.01 and config.dash_ready_reserved_energy_ratio >= reserve_ratio:
		reserve_ratio = maxf(reserve_ratio, config.dash_ready_reserved_energy_ratio)
		reserve_basis = "dash_ready"
	if obs.shield_cooldown_ratio <= 0.01 and config.shield_ready_reserved_energy_ratio >= reserve_ratio:
		reserve_ratio = maxf(reserve_ratio, config.shield_ready_reserved_energy_ratio)
		reserve_basis = "shield_ready"
	if bool(threat_info.get("has_threat", false)):
		var threat_reserve := lerpf(config.threat_reserved_energy_floor, config.defensive_reserved_energy_ratio, clampf(float(threat_info.get("threat_level", 0.0)), 0.0, 1.0))
		if threat_reserve >= reserve_ratio:
			reserve_ratio = threat_reserve
			reserve_basis = "projectile_threat"
	if fire_mode == HighLevelDecision.FireMode.CONSERVATIVE:
		if config.conservative_reserved_energy_ratio >= reserve_ratio:
			reserve_ratio = config.conservative_reserved_energy_ratio
			reserve_basis = "conservative"
	elif fire_mode == HighLevelDecision.FireMode.ALL_IN and _kill_window(aim_solution, balance):
		if config.all_in_reserved_energy_ratio < reserve_ratio:
			reserve_ratio = config.all_in_reserved_energy_ratio
			reserve_basis = "all_in_kill_window"
	elif fire_mode == HighLevelDecision.FireMode.BURST:
		if config.burst_reserved_energy_ratio >= reserve_ratio:
			reserve_ratio = config.burst_reserved_energy_ratio
			reserve_basis = "burst"
	reserve_ratio = clampf(reserve_ratio, 0.0, 0.80)
	return {
		"reserved_energy": reserve_ratio * balance.max_energy,
		"reserve_ratio": reserve_ratio,
		"reserve_basis": reserve_basis,
	}

func _hit_threshold(fire_mode: int, config: HybridAgentConfig, kill_window: bool) -> float:
	var value := config.normal_hit_probability
	match fire_mode:
		HighLevelDecision.FireMode.CONSERVATIVE:
			value = config.conservative_hit_probability
		HighLevelDecision.FireMode.BURST:
			value = config.burst_hit_probability
		HighLevelDecision.FireMode.ALL_IN:
			value = config.all_in_hit_probability
	if kill_window:
		value -= 0.08
	return clampf(value, 0.0, 1.0)

func _aim_error_threshold(fire_mode: int, config: HybridAgentConfig, kill_window: bool) -> float:
	var value := config.normal_max_aim_error
	match fire_mode:
		HighLevelDecision.FireMode.CONSERVATIVE:
			value = config.conservative_max_aim_error
		HighLevelDecision.FireMode.BURST:
			value = config.burst_max_aim_error
		HighLevelDecision.FireMode.ALL_IN:
			value = config.all_in_max_aim_error
	if kill_window:
		value += 0.06
	return clampf(value, 0.02, PI)

func _kill_window(aim_solution: Dictionary, balance: GameBalance) -> bool:
	var target_health := float(aim_solution.get("target_health_ratio", 1.0))
	var damage_ratio := balance.projectile_damage / maxf(balance.max_health, 1.0)
	return target_health <= damage_ratio + 0.08

func _burst_state() -> Dictionary:
	return {
		"remaining": burst_remaining,
		"recovery_timer": burst_recovery_timer,
	}
