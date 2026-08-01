extends RefCounted
# 角色动画状态机，平滑处理移动、受击表情和短时姿态变化。
class_name CharacterAnimationController

enum AnimState {
	IDLE,
	MOVE,
	STRAFE,
	SHOOT,
	RECHARGE,
	HIT,
	DEATH,
	SPAWN,
	VICTORY,
}

var state: AnimState = AnimState.SPAWN
var walk_cycle: float = 0.0
var upper_angle: float = 0.0
var lower_angle: float = 0.0
var move_speed_ratio: float = 0.0
var strafe_amount: float = 0.0
var recoil: float = 0.0
var muzzle_flash: float = 0.0
var empty_flash: float = 0.0
var hit_flash: float = 0.0
var spawn_timer: float = 0.45
var death_timer: float = 0.0
var recharge_timer: float = 0.0
var breathing: float = 0.0
var last_move_direction: Vector2 = Vector2.RIGHT

func reset_spawn(aim: Vector2) -> void:
	var safe_aim := aim.normalized() if aim.length_squared() > 0.001 else Vector2.RIGHT
	state = AnimState.SPAWN
	upper_angle = safe_aim.angle()
	lower_angle = safe_aim.angle()
	move_speed_ratio = 0.0
	strafe_amount = 0.0
	recoil = 0.0
	muzzle_flash = 0.0
	empty_flash = 0.0
	hit_flash = 0.0
	spawn_timer = 0.45
	death_timer = 0.0
	recharge_timer = 0.0
	last_move_direction = safe_aim

func on_shoot() -> void:
	recoil = 1.0
	muzzle_flash = 0.09
	state = AnimState.SHOOT

func on_empty_fire() -> void:
	empty_flash = 0.16
	recharge_timer = 0.34
	state = AnimState.RECHARGE

func on_hit() -> void:
	hit_flash = 0.16
	state = AnimState.HIT

func on_death() -> void:
	death_timer = 0.55
	state = AnimState.DEATH

func on_victory() -> void:
	state = AnimState.VICTORY

func update(delta: float, player, desired_move: Vector2) -> void:
	breathing = fposmod(breathing + delta * 2.2, TAU)
	recoil = maxf(0.0, recoil - delta * 8.5)
	muzzle_flash = maxf(0.0, muzzle_flash - delta)
	empty_flash = maxf(0.0, empty_flash - delta)
	hit_flash = maxf(0.0, hit_flash - delta)
	spawn_timer = maxf(0.0, spawn_timer - delta)
	death_timer = maxf(0.0, death_timer - delta)
	recharge_timer = maxf(0.0, recharge_timer - delta)

	var aim := player.aim_direction.normalized() if player.aim_direction.length_squared() > 0.001 else Vector2.RIGHT
	upper_angle = lerp_angle(upper_angle, aim.angle(), clampf(delta * 18.0, 0.0, 1.0))

	var move_dir := desired_move.normalized() if desired_move.length_squared() > 0.001 else Vector2.ZERO
	if move_dir.length_squared() <= 0.001 and player.velocity.length_squared() > 1.0:
		move_dir = player.velocity.normalized()
	if move_dir.length_squared() > 0.001:
		last_move_direction = move_dir
	var lower_target := last_move_direction if move_dir.length_squared() > 0.001 else aim
	lower_angle = lerp_angle(lower_angle, lower_target.angle(), clampf(delta * 12.0, 0.0, 1.0))

	var base_speed := maxf(player.balance.move_speed, 1.0)
	move_speed_ratio = clampf(player.velocity.length() / base_speed, 0.0, 1.45)
	if move_speed_ratio > 0.03:
		walk_cycle = fposmod(walk_cycle + delta * lerpf(5.0, 12.0, clampf(move_speed_ratio, 0.0, 1.0)), TAU)
	else:
		walk_cycle = fposmod(walk_cycle + delta * 1.8, TAU)
	strafe_amount = 0.0
	if move_dir.length_squared() > 0.001:
		strafe_amount = clampf(absf(move_dir.dot(aim.orthogonal())), 0.0, 1.0)

	if not player.is_alive:
		state = AnimState.DEATH
	elif spawn_timer > 0.0:
		state = AnimState.SPAWN
	elif hit_flash > 0.0:
		state = AnimState.HIT
	elif recoil > 0.08 or muzzle_flash > 0.0:
		state = AnimState.SHOOT
	elif recharge_timer > 0.0 or empty_flash > 0.0:
		state = AnimState.RECHARGE
	elif move_speed_ratio > 0.08:
		state = AnimState.STRAFE if strafe_amount > 0.55 else AnimState.MOVE
	else:
		state = AnimState.IDLE

func get_spawn_alpha() -> float:
	if spawn_timer <= 0.0:
		return 1.0
	return clampf(1.0 - spawn_timer / 0.45, 0.15, 1.0)

func get_state_name() -> String:
	match state:
		AnimState.IDLE:
			return "idle"
		AnimState.MOVE:
			return "move"
		AnimState.STRAFE:
			return "strafe"
		AnimState.SHOOT:
			return "shoot"
		AnimState.RECHARGE:
			return "recharge"
		AnimState.HIT:
			return "hit"
		AnimState.DEATH:
			return "death"
		AnimState.SPAWN:
			return "spawn"
		AnimState.VICTORY:
			return "victory"
	return "idle"
