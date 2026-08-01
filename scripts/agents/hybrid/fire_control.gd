extends RefCounted
# Deterministic fire gate for high-level tactical fire modes.
class_name FireControl

const HighLevelDecision = preload("res://scripts/agents/hybrid/tactical_decision.gd")
const HybridAgentConfig = preload("res://scripts/agents/hybrid/hybrid_agent_config.gd")

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
	var reserved := _reserved_energy(obs, aim_solution, threat_info, balance, config, fire_mode)
	diag["reserved_energy"] = reserved
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
		"fire_block_reason": "init",
		"predicted_hit_probability": 0.0,
		"aim_error": PI,
		"reserved_energy": 0.0,
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

func _reserved_energy(obs: AgentObservation, aim_solution: Dictionary, threat_info: Dictionary, balance: GameBalance, config: HybridAgentConfig, fire_mode: int) -> float:
	var reserve_ratio := config.base_reserved_energy_ratio
	if obs.health_ratio < 0.36:
		reserve_ratio = maxf(reserve_ratio, config.defensive_reserved_energy_ratio)
	if obs.dash_cooldown_ratio <= 0.01:
		reserve_ratio = maxf(reserve_ratio, 0.26)
	if obs.shield_cooldown_ratio <= 0.01:
		reserve_ratio = maxf(reserve_ratio, 0.24)
	if bool(threat_info.get("has_threat", false)):
		reserve_ratio = maxf(reserve_ratio, lerpf(0.26, config.defensive_reserved_energy_ratio, clampf(float(threat_info.get("threat_level", 0.0)), 0.0, 1.0)))
	if fire_mode == HighLevelDecision.FireMode.CONSERVATIVE:
		reserve_ratio = maxf(reserve_ratio, 0.40)
	elif fire_mode == HighLevelDecision.FireMode.ALL_IN and _kill_window(aim_solution, balance):
		reserve_ratio = minf(reserve_ratio, config.all_in_reserved_energy_ratio)
	elif fire_mode == HighLevelDecision.FireMode.BURST:
		reserve_ratio = maxf(reserve_ratio, 0.18)
	return clampf(reserve_ratio, 0.0, 0.80) * balance.max_energy

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
