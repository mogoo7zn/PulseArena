extends Resource
# 核心数值平衡表，集中维护玩家、弹道、道具和比赛参数。
class_name GameBalance

@export_group("Match")
@export var map_size: Vector2 = Vector2(2160, 1215)
@export var time_limit: float = 90.0
@export var max_players: int = 4
@export var physics_hz: int = 60
@export var agent_decision_hz: int = 15
@export var agent_action_hold_frames: int = 4
@export var respawn_delay: float = 1.5
@export var respawn_protection: float = 1.0

@export_group("Player")
@export var max_health: float = 100.0
@export var max_energy: float = 100.0
@export var move_speed: float = 260.0
@export var player_radius: float = 22.0
@export var energy_regen_per_second: float = 14.0

@export_group("Projectile")
@export var projectile_damage: float = 20.0
@export var projectile_energy_cost: float = 12.0
@export var shoot_cooldown: float = 0.25
@export var projectile_speed: float = 850.0
@export var projectile_lifetime: float = 1.4
@export var projectile_radius: float = 7.0

@export_group("Dash")
@export var dash_distance: float = 130.0
@export var dash_duration: float = 0.16
@export var dash_cooldown: float = 2.5
@export var dash_energy_cost: float = 30.0
@export var dash_invincible_time: float = 0.08

@export_group("Shield")
@export var shield_duration: float = 0.5
@export var shield_absorb: float = 40.0
@export var shield_cooldown: float = 3.5
@export var shield_energy_cost: float = 25.0
@export var shield_move_slow: float = 0.25

@export_group("Pickups")
@export var pickup_spawn_interval_min: float = 5.0
@export var pickup_spawn_interval_max: float = 8.0
@export var pickup_lifetime: float = 15.0
@export var pickup_max_active: int = 4
@export var pickup_spawn_radius: float = 32.0
@export var pickup_collect_radius: float = 44.0
@export var pickup_health_restore_ratio: float = 0.22
@export var pickup_shield_duration: float = 5.0
@export var pickup_shield_absorb: float = 45.0
@export var pickup_haste_duration: float = 4.0
@export var pickup_haste_speed_multiplier: float = 1.35
@export var pickup_haste_fire_rate_multiplier: float = 1.2
@export var pickup_pulse_radius: float = 330.0
@export var pickup_pulse_damage: float = 14.0
@export var pickup_pulse_count: int = 3
@export var pickup_pulse_interval: float = 0.5
@export var pickup_pulse_knockback: float = 210.0
@export var pickup_overcharge_duration: float = 5.0
@export var pickup_overcharge_damage_multiplier: float = 1.35
@export var pickup_overcharge_projectile_speed_multiplier: float = 1.1
@export var pickup_magnet_duration: float = 6.0
@export var pickup_magnet_radius: float = 280.0
@export var pickup_magnet_pull_speed: float = 520.0

static func default() -> GameBalance:
	return GameBalance.new()
