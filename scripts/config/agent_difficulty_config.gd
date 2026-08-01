extends Resource
# AI 难度配置资源，描述脚本智能体的反应、精度和战术倾向。
class_name AgentDifficultyConfig

@export var name: String = "normal"
@export var reaction_delay: float = 0.1
@export var aim_noise: float = 0.08
@export var decision_rate: float = 15.0
@export var aggression: float = 0.6
@export var preferred_distance: float = 360.0
@export var shield_probability: float = 0.2
@export var dash_probability: float = 0.25

static func make(difficulty: String) -> AgentDifficultyConfig:
	var cfg := AgentDifficultyConfig.new()
	cfg.name = difficulty
	match difficulty:
		"easy":
			cfg.reaction_delay = 0.35
			cfg.aim_noise = 0.28
			cfg.decision_rate = 8.0
			cfg.aggression = 0.35
			cfg.preferred_distance = 420.0
			cfg.shield_probability = 0.06
			cfg.dash_probability = 0.08
		"hard":
			cfg.reaction_delay = 0.04
			cfg.aim_noise = 0.025
			cfg.decision_rate = 20.0
			cfg.aggression = 0.82
			cfg.preferred_distance = 330.0
			cfg.shield_probability = 0.38
			cfg.dash_probability = 0.42
		_:
			cfg.reaction_delay = 0.12
			cfg.aim_noise = 0.09
			cfg.decision_rate = 15.0
			cfg.aggression = 0.6
			cfg.preferred_distance = 360.0
			cfg.shield_probability = 0.2
			cfg.dash_probability = 0.25
	return cfg
