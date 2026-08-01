extends Node
# 游戏流程状态机，负责主菜单、加载、倒计时、游玩、暂停和结算状态切换。
class_name GameFlowManagerService

enum GameState {
	BOOT,
	MAIN_MENU,
	MATCH_SETUP,
	LOADING,
	COUNTDOWN,
	PLAYING,
	PAUSED,
	ROUND_END,
	MATCH_RESULT,
}

signal match_requested(config: MatchConfig)
signal main_menu_requested()

var current_state: GameState = GameState.BOOT
var previous_state: GameState = GameState.BOOT
var current_match_config: MatchConfig

func _ready() -> void:
	goto_state(GameState.BOOT)

func goto_state(next_state: GameState) -> void:
	if current_state == next_state:
		return
	previous_state = current_state
	current_state = next_state
	GameEvents.emit_game_state_changed(current_state, previous_state)
	AppLog.info("Game state changed", {"from": GameState.keys()[previous_state], "to": GameState.keys()[current_state]})
	AppLog.public_info("Game state changed")

func start_match(config: MatchConfig) -> void:
	current_match_config = config.duplicate_config()
	goto_state(GameState.LOADING)
	match_requested.emit(current_match_config)

func enter_main_menu() -> void:
	current_match_config = null
	goto_state(GameState.MAIN_MENU)
	main_menu_requested.emit()

func enter_countdown() -> void:
	goto_state(GameState.COUNTDOWN)

func enter_playing() -> void:
	goto_state(GameState.PLAYING)

func pause_match() -> void:
	if current_state != GameState.PLAYING:
		return
	goto_state(GameState.PAUSED)
	get_tree().paused = true
	GameEvents.emit_match_paused()

func resume_match() -> void:
	if current_state != GameState.PAUSED:
		return
	get_tree().paused = false
	goto_state(GameState.PLAYING)
	GameEvents.emit_match_resumed()

func finish_match(result: Dictionary) -> void:
	get_tree().paused = false
	goto_state(GameState.MATCH_RESULT)
	GameEvents.emit_match_finished(result)

func is_match_active() -> bool:
	return current_state == GameState.COUNTDOWN or current_state == GameState.PLAYING or current_state == GameState.PAUSED or current_state == GameState.MATCH_RESULT
