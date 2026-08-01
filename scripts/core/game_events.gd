extends Node
# 全局事件总线，解耦比赛流程、UI、音频和玩法系统之间的通知。
class_name GameEventsService

## Central typed gameplay event surface. Payload dictionaries use the keys documented
## here so UI, replay and RL code can subscribe without querying gameplay nodes every frame.

signal game_state_changed(new_state: int, old_state: int)
signal match_started(config: MatchConfig)
signal match_paused()
signal match_resumed()
signal match_finished(result: Dictionary)
signal player_spawned(payload: Dictionary) # player_id, team_id, position, respawn
signal player_damaged(payload: Dictionary) # victim_id, attacker_id, amount, absorbed, health
signal player_killed(payload: Dictionary) # victim_id, killer_id, position
signal player_respawned(payload: Dictionary) # player_id, position
signal projectile_fired(payload: Dictionary) # projectile_id, owner_id, position, velocity
signal shield_activated(payload: Dictionary) # player_id, duration, absorb
signal dash_started(payload: Dictionary) # player_id, position, direction
signal score_changed(payload: Dictionary) # player_id, kills, deaths, score
signal time_changed(remaining_seconds: float, ratio: float)
signal kill_feed(payload: Dictionary)
signal reward_changed(payload: Dictionary)

func emit_game_state_changed(new_state: int, old_state: int) -> void:
	game_state_changed.emit(new_state, old_state)

func emit_match_started(config: MatchConfig) -> void:
	match_started.emit(config)

func emit_match_paused() -> void:
	match_paused.emit()

func emit_match_resumed() -> void:
	match_resumed.emit()

func emit_match_finished(result: Dictionary) -> void:
	match_finished.emit(result)

func emit_player_spawned(payload: Dictionary) -> void:
	player_spawned.emit(payload)

func emit_player_damaged(payload: Dictionary) -> void:
	player_damaged.emit(payload)

func emit_player_killed(payload: Dictionary) -> void:
	player_killed.emit(payload)
	kill_feed.emit(payload)

func emit_player_respawned(payload: Dictionary) -> void:
	player_respawned.emit(payload)

func emit_projectile_fired(payload: Dictionary) -> void:
	projectile_fired.emit(payload)

func emit_shield_activated(payload: Dictionary) -> void:
	shield_activated.emit(payload)

func emit_dash_started(payload: Dictionary) -> void:
	dash_started.emit(payload)

func emit_score_changed(payload: Dictionary) -> void:
	score_changed.emit(payload)

func emit_time_changed(remaining_seconds: float, ratio: float) -> void:
	time_changed.emit(remaining_seconds, ratio)

func emit_reward_changed(payload: Dictionary) -> void:
	reward_changed.emit(payload)
