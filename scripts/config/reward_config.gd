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

static func default() -> RewardConfig:
	return RewardConfig.new()
