extends Node
# 全局配置数据库，提供平衡表、奖励表和难度配置的默认实例。
class_name ConfigDBService

var balance: GameBalance = GameBalance.default()
var reward_config: RewardConfig = RewardConfig.default()
var difficulties: Dictionary = {}
var match_presets: Dictionary = {}

func _ready() -> void:
	load_defaults()

func load_defaults() -> void:
	balance = GameBalance.default()
	reward_config = RewardConfig.default()
	difficulties = {
		"easy": AgentDifficultyConfig.make("easy"),
		"normal": AgentDifficultyConfig.make("normal"),
		"hard": AgentDifficultyConfig.make("hard"),
	}
	match_presets = {
		"human_vs_1_agent": MatchConfig.preset_human_vs_agent(1),
		"human_vs_2_agents": MatchConfig.preset_human_vs_agent(2),
		"human_vs_3_agents": MatchConfig.preset_human_vs_agent(3),
		"two_humans_vs_two_agents": MatchConfig.preset_2_humans_vs_2_agents(),
		"training_4_agents": MatchConfig.preset_training_ffa_agents(4),
	}

func get_balance() -> GameBalance:
	return balance

func get_reward_config() -> RewardConfig:
	return reward_config

func get_difficulty(name: String) -> AgentDifficultyConfig:
	return difficulties.get(name, difficulties["normal"])

func get_preset(key: String) -> MatchConfig:
	if not match_presets.has(key):
		AppLog.warn("Unknown match preset requested", {"preset": key})
		return MatchConfig.preset_human_vs_agent(1)
	return match_presets[key].duplicate_config()
