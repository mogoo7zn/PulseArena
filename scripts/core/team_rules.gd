extends RefCounted
# 队伍规则工具类，封装队友判断和伤害许可逻辑。
class_name TeamRules

static func are_teammates(config: MatchConfig, a_team: int, b_team: int, a_id: int = -1, b_id: int = -2) -> bool:
	if a_id == b_id:
		return true
	if not config.team_mode:
		return false
	return a_team == b_team

static func can_damage(config: MatchConfig, attacker_team: int, victim_team: int, attacker_id: int, victim_id: int) -> bool:
	if attacker_id == victim_id:
		return false
	if not config.team_mode:
		return true
	if attacker_team != victim_team:
		return true
	return config.friendly_fire

static func team_for_player(config: MatchConfig, player_index: int, is_human: bool) -> int:
	if config.team_mode:
		if config.human_player_count == 0:
			return player_index % 2
		return 0 if is_human else 1
	return player_index
