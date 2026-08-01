extends RefCounted
# 单局时间控制器，维护倒计时、剩余时间和比赛结束状态。
class_name MatchManager

var config: MatchConfig
var remaining_time: float = 0.0
var elapsed_time: float = 0.0
var countdown: float = 3.0
var playing: bool = false
var finished: bool = false

func configure(match_config: MatchConfig) -> void:
	config = match_config
	remaining_time = match_config.time_limit
	elapsed_time = 0.0
	countdown = 3.0
	playing = false
	finished = false

func physics_step(delta: float) -> void:
	if finished:
		return
	if countdown > 0.0:
		countdown = maxf(0.0, countdown - delta)
		if countdown <= 0.0:
			playing = true
			GameFlowManager.enter_playing()
		return
	if not playing:
		return
	elapsed_time += delta
	remaining_time = maxf(0.0, remaining_time - delta)
	GameEvents.emit_time_changed(remaining_time, get_remaining_ratio())
	if remaining_time <= 0.0:
		finished = true

func get_remaining_ratio() -> float:
	if config == null or config.time_limit <= 0.0:
		return 0.0
	return clampf(remaining_time / config.time_limit, 0.0, 1.0)

func get_countdown_number() -> int:
	return ceili(countdown)
