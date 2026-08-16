extends Resource
# 训练奖励配置，定义强化学习/脚本评估时的奖励项权重。
class_name RewardConfig

@export_group("Free For All")
@export var ffa_damage_dealt: float = 0.02
@export var ffa_damage_taken: float = -0.01
@export var ffa_kill: float = 3.0
@export var ffa_death: float = -2.0
@export var ffa_win: float = 5.0
@export var ffa_rank_step: float = 1.0

@export_group("2v2")
@export var team_damage_dealt: float = 0.015
@export var team_damage_taken: float = -0.008
@export var team_kill: float = 2.5
@export var team_death: float = -1.5
@export var team_win: float = 6.0
@export var ally_damage_bonus: float = 0.005

@export_group("Map Risk")
@export var environment_damage_taken: float = -0.012
@export var environment_death: float = -0.75

@export_group("Tactical Profiles")
@export var profile_id: String = "baseline"
@export var legal_window_damage: float = 0.0
@export var legal_window_commitment: float = 0.0
@export var actionable_window_entry: float = 0.0
@export var authorized_projectile_cost: float = 0.0
@export var missed_legal_window: float = 0.0
@export var avoidable_override: float = 0.0
@export var avoidable_pressure_retreat: float = 0.0
@export var pressure_retreat_threat_ceiling: float = 0.25
@export var efficient_damage: float = 0.0
@export var unfavorable_exchange: float = 0.0
@export var positive_score_margin: float = 0.0

@export_group("Resource Value")
@export var contested_pickup_capture: float = 0.0
@export var resource_contest_radius: float = 260.0
@export var pickup_health_value_per_hp: float = 0.0
@export var pickup_shield_absorb_value_per_hp: float = 0.0
@export var pickup_haste_damage_value_per_hp: float = 0.0
@export var pickup_overcharge_damage_value_per_hp: float = 0.0

static func default() -> RewardConfig:
	return RewardConfig.new()

func for_profile(profile_id_value: String) -> RewardConfig:
	var resolved := duplicate(true) as RewardConfig
	var requested := profile_id_value.strip_edges().to_lower()
	if requested.is_empty() or requested == "baseline":
		resolved.profile_id = "baseline"
		return resolved
	if requested == "legal_window_pressure":
		resolved.profile_id = requested
		resolved.legal_window_damage = 0.03
		resolved.legal_window_commitment = 0.05
		resolved.actionable_window_entry = 0.02
		resolved.authorized_projectile_cost = -0.01
		resolved.missed_legal_window = -0.02
		resolved.avoidable_override = -0.03
		resolved.avoidable_pressure_retreat = -0.015
		resolved.contested_pickup_capture = 0.015
		resolved.pickup_health_value_per_hp = 0.004
		resolved.pickup_shield_absorb_value_per_hp = 0.003
		resolved.pickup_haste_damage_value_per_hp = 0.002
		resolved.pickup_overcharge_damage_value_per_hp = 0.002
		return resolved
	if requested == "score_margin_discipline":
		resolved.profile_id = requested
		resolved.efficient_damage = 0.02
		resolved.unfavorable_exchange = -0.02
		resolved.avoidable_override = -0.02
		resolved.positive_score_margin = 0.25
		return resolved
	push_warning("Unknown reward profile '%s'; using baseline" % profile_id_value)
	resolved.profile_id = "baseline"
	return resolved
