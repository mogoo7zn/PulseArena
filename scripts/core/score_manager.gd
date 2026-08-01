extends RefCounted
# 计分管理器，记录击杀、死亡、个人分数和队伍分数。
class_name ScoreManager

var stats: Dictionary = {}

func reset() -> void:
	stats.clear()

func register_player(player_id: int, team_id: int, label: String) -> void:
	stats[player_id] = {
		"player_id": player_id,
		"team_id": team_id,
		"label": label,
		"kills": 0,
		"deaths": 0,
		"score": 0,
	}

func record_kill(killer_id: int, victim_id: int) -> void:
	if stats.has(victim_id):
		stats[victim_id]["deaths"] = int(stats[victim_id]["deaths"]) + 1
		stats[victim_id]["score"] = int(stats[victim_id]["score"]) - 1
		GameEvents.emit_score_changed(stats[victim_id].duplicate())
	if killer_id >= 0 and killer_id != victim_id and stats.has(killer_id):
		stats[killer_id]["kills"] = int(stats[killer_id]["kills"]) + 1
		stats[killer_id]["score"] = int(stats[killer_id]["score"]) + 2
		GameEvents.emit_score_changed(stats[killer_id].duplicate())

func get_player_score(player_id: int) -> int:
	return int(stats.get(player_id, {}).get("score", 0))

func get_player_kills(player_id: int) -> int:
	return int(stats.get(player_id, {}).get("kills", 0))

func get_player_deaths(player_id: int) -> int:
	return int(stats.get(player_id, {}).get("deaths", 0))

func get_team_scores() -> Dictionary:
	var teams: Dictionary = {}
	for player_id in stats.keys():
		var data: Dictionary = stats[player_id]
		var team := int(data["team_id"])
		teams[team] = int(teams.get(team, 0)) + int(data["score"])
	return teams

func get_sorted_standings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for player_id in stats.keys():
		out.append(stats[player_id].duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) == int(b["score"]):
			return int(a["kills"]) > int(b["kills"])
		return int(a["score"]) > int(b["score"])
	)
	return out

func build_result(config: MatchConfig) -> Dictionary:
	var standings := get_sorted_standings()
	return {
		"mode": config.mode,
		"team_mode": config.team_mode,
		"standings": standings,
		"team_scores": get_team_scores(),
		"winner_player_id": int(standings[0]["player_id"]) if not standings.is_empty() else -1,
	}
