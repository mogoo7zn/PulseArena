extends RefCounted
# 奖励计算器，根据伤害、击杀、生存和战术事件生成训练奖励。
class_name RewardCalculator

var config: MatchConfig
var reward_config: RewardConfig
var totals: Dictionary = {}
var components: Dictionary = {}

func configure(match_config: MatchConfig, rewards: RewardConfig) -> void:
	config = match_config
	reward_config = rewards
	totals.clear()
	components.clear()

func register_player(player_id: int) -> void:
	totals[player_id] = 0.0
	components[player_id] = {}

func on_damage(attacker_id: int, victim_id: int, amount: float) -> void:
	if attacker_id < 0 or attacker_id == victim_id:
		return
	var dealt_weight := reward_config.team_damage_dealt if config.team_mode else reward_config.ffa_damage_dealt
	var taken_weight := reward_config.team_damage_taken if config.team_mode else reward_config.ffa_damage_taken
	_add(attacker_id, "damage_dealt", amount * dealt_weight)
	_add(victim_id, "damage_taken", amount * taken_weight)

func on_kill(killer_id: int, victim_id: int) -> void:
	if killer_id >= 0 and killer_id != victim_id:
		_add(killer_id, "kill", reward_config.team_kill if config.team_mode else reward_config.ffa_kill)
	_add(victim_id, "death", reward_config.team_death if config.team_mode else reward_config.ffa_death)

func on_environment_damage(victim_id: int, amount: float, hazard: String = "environment") -> void:
	if victim_id < 0:
		return
	_add(victim_id, "%s_damage_taken" % hazard, amount * reward_config.environment_damage_taken)

func on_environment_death(victim_id: int, hazard: String = "environment") -> void:
	if victim_id < 0:
		return
	_add(victim_id, "%s_death" % hazard, reward_config.environment_death)

func on_match_finished(result: Dictionary) -> void:
	var winner := int(result.get("winner_player_id", -1))
	for player_id in totals.keys():
		if int(player_id) == winner:
			_add(int(player_id), "win", reward_config.team_win if config.team_mode else reward_config.ffa_win)

func get_total(player_id: int) -> float:
	return float(totals.get(player_id, 0.0))

func get_components(player_id: int) -> Dictionary:
	return components.get(player_id, {}).duplicate()

func _add(player_id: int, component: String, value: float) -> void:
	if not totals.has(player_id):
		register_player(player_id)
	totals[player_id] = float(totals[player_id]) + value
	var data: Dictionary = components[player_id]
	data[component] = float(data.get(component, 0.0)) + value
	GameEvents.emit_reward_changed({"player_id": player_id, "total": totals[player_id], "components": data.duplicate()})
