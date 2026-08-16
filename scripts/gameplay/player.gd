extends CharacterBody2D
# 玩家实体，整合移动、受击、表情、射击、技能增益和死亡流程。
class_name ArenaPlayer

signal projectile_requested(player: ArenaPlayer, origin: Vector2, direction: Vector2)
signal pickup_effect_expired(player: ArenaPlayer, pickup_type: String, source_id: int, realized: bool)

const HURT_EXPRESSION_DURATION := 2.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var id_label: Label = $IdLabel
@onready var type_label: Label = $TypeLabel

var player_id: int = 0
var team_id: int = 0
var display_name: String = "Player"
var is_human: bool = true
var controller: PlayerController
var balance: GameBalance = GameBalance.default()
var body_color: Color = Color("#6EA8FE")
var controller_label: String = "HUMAN"

var health: float = 100.0
var energy: float = 100.0
var aim_direction: Vector2 = Vector2.RIGHT
var is_alive: bool = true
var respawn_timer: float = 0.0
var protection_timer: float = 0.0
var shoot_cooldown_timer: float = 0.0
var dash_cooldown_timer: float = 0.0
var shield_cooldown_timer: float = 0.0
var shield_timer: float = 0.0
var shield_absorb_remaining: float = 0.0
var dash_timer: float = 0.0
var dash_invincible_timer: float = 0.0
var dash_direction: Vector2 = Vector2.RIGHT
var hit_flash_timer: float = 0.0
var last_killer_id: int = -1
var empty_feedback_timer: float = 0.0
var last_requested_move: Vector2 = Vector2.ZERO
var visual_walk_cycle: float = 0.0
var visual_upper_angle: float = 0.0
var visual_lower_angle: float = 0.0
var visual_recoil: float = 0.0
var visual_muzzle_flash: float = 0.0
var visual_empty_flash: float = 0.0
var visual_spawn_timer: float = 0.0
var visual_death_timer: float = 0.0
var visual_void_fall_timer: float = 0.0
var visual_void_fall_duration: float = 0.75
var visual_last_move_direction: Vector2 = Vector2.RIGHT
var map_speed_multiplier: float = 1.0
var movement_lock_timer: float = 0.0
var hurt_expression_timer: float = 0.0
var pickup_speed_timer: float = 0.0
var pickup_speed_multiplier: float = 1.0
var pickup_fire_rate_timer: float = 0.0
var pickup_fire_rate_multiplier: float = 1.0
var pickup_overcharge_timer: float = 0.0
var pickup_damage_multiplier: float = 1.0
var pickup_projectile_speed_multiplier: float = 1.0
var pickup_magnet_timer: float = 0.0
var pickup_flash_timer: float = 0.0
var pickup_flash_color: Color = Color("#63D7C4")
var pickup_shield_source_id: int = -1
var pickup_haste_source_id: int = -1
var pickup_overcharge_source_id: int = -1
var pickup_shield_realized: bool = false
var pickup_haste_realized: bool = false
var pickup_overcharge_realized: bool = false
var camouflage_intensity: float = 0.0
var mist_visibility: float = 1.0
var visuals_enabled: bool = true

func configure(id: int, team: int, name: String, human: bool, player_controller: PlayerController, color: Color, match_balance: GameBalance) -> void:
	player_id = id
	team_id = team
	display_name = name
	is_human = human
	controller = player_controller
	body_color = color
	balance = match_balance
	controller_label = controller.get_label() if controller != null else "CTRL"
	if controller != null:
		controller.set_controlled_player(self)
	_update_labels()

func set_visuals_enabled(enabled: bool) -> void:
	visuals_enabled = enabled
	visible = enabled
	if id_label != null:
		id_label.visible = enabled
	if type_label != null:
		type_label.visible = enabled

func _request_visual_redraw() -> void:
	if visuals_enabled:
		queue_redraw()

func _ready() -> void:
	add_to_group("players")
	var circle := CircleShape2D.new()
	circle.radius = balance.player_radius
	collision_shape.shape = circle
	_reset_visual_spawn()
	_update_labels()

func spawn_at(spawn_position: Vector2, respawn: bool = false) -> void:
	global_position = spawn_position
	velocity = Vector2.ZERO
	health = balance.max_health
	energy = balance.max_energy
	is_alive = true
	respawn_timer = 0.0
	protection_timer = balance.respawn_protection
	shield_timer = 0.0
	shield_absorb_remaining = 0.0
	dash_timer = 0.0
	dash_invincible_timer = 0.0
	last_killer_id = -1
	empty_feedback_timer = 0.0
	movement_lock_timer = 0.0
	map_speed_multiplier = 1.0
	hurt_expression_timer = 0.0
	pickup_speed_timer = 0.0
	pickup_speed_multiplier = 1.0
	pickup_fire_rate_timer = 0.0
	pickup_fire_rate_multiplier = 1.0
	pickup_overcharge_timer = 0.0
	pickup_damage_multiplier = 1.0
	pickup_projectile_speed_multiplier = 1.0
	pickup_magnet_timer = 0.0
	pickup_flash_timer = 0.0
	pickup_shield_source_id = -1
	pickup_haste_source_id = -1
	pickup_overcharge_source_id = -1
	pickup_shield_realized = false
	pickup_haste_realized = false
	pickup_overcharge_realized = false
	camouflage_intensity = 0.0
	mist_visibility = 1.0
	modulate = Color(modulate.r, modulate.g, modulate.b, 1.0)
	visual_void_fall_timer = 0.0
	collision_shape.disabled = false
	visible = visuals_enabled
	_reset_visual_spawn()
	GameEvents.emit_player_spawned({"player_id": player_id, "team_id": team_id, "position": global_position, "respawn": respawn})
	if respawn:
		GameEvents.emit_player_respawned({"player_id": player_id, "position": global_position})
	_request_visual_redraw()

func status_step(delta: float) -> void:
	var needs_visual_redraw := (
		visual_spawn_timer > 0.0
		or visual_death_timer > 0.0
		or hit_flash_timer > 0.0
		or empty_feedback_timer > 0.0
		or hurt_expression_timer > 0.0
		or shield_timer > 0.0
		or dash_timer > 0.0
		or protection_timer > 0.0
		or pickup_speed_timer > 0.0
		or pickup_fire_rate_timer > 0.0
		or pickup_overcharge_timer > 0.0
		or pickup_magnet_timer > 0.0
		or pickup_flash_timer > 0.0
	)
	shoot_cooldown_timer = maxf(0.0, shoot_cooldown_timer - delta)
	dash_cooldown_timer = maxf(0.0, dash_cooldown_timer - delta)
	shield_cooldown_timer = maxf(0.0, shield_cooldown_timer - delta)
	var prior_pickup_shield_timer := shield_timer
	var prior_pickup_haste_timer := pickup_fire_rate_timer
	var prior_pickup_overcharge_timer := pickup_overcharge_timer
	shield_timer = maxf(0.0, shield_timer - delta)
	dash_invincible_timer = maxf(0.0, dash_invincible_timer - delta)
	protection_timer = maxf(0.0, protection_timer - delta)
	hit_flash_timer = maxf(0.0, hit_flash_timer - delta)
	empty_feedback_timer = maxf(0.0, empty_feedback_timer - delta)
	movement_lock_timer = maxf(0.0, movement_lock_timer - delta)
	hurt_expression_timer = maxf(0.0, hurt_expression_timer - delta)
	pickup_speed_timer = maxf(0.0, pickup_speed_timer - delta)
	pickup_fire_rate_timer = maxf(0.0, pickup_fire_rate_timer - delta)
	pickup_overcharge_timer = maxf(0.0, pickup_overcharge_timer - delta)
	pickup_magnet_timer = maxf(0.0, pickup_magnet_timer - delta)
	pickup_flash_timer = maxf(0.0, pickup_flash_timer - delta)
	if prior_pickup_shield_timer > 0.0 and shield_timer <= 0.0 and pickup_shield_source_id >= 0:
		pickup_effect_expired.emit(self, "shield", pickup_shield_source_id, pickup_shield_realized)
		pickup_shield_source_id = -1
		pickup_shield_realized = false
	if prior_pickup_haste_timer > 0.0 and pickup_fire_rate_timer <= 0.0 and pickup_haste_source_id >= 0:
		pickup_effect_expired.emit(self, "haste", pickup_haste_source_id, pickup_haste_realized)
		pickup_haste_source_id = -1
		pickup_haste_realized = false
	if prior_pickup_overcharge_timer > 0.0 and pickup_overcharge_timer <= 0.0 and pickup_overcharge_source_id >= 0:
		pickup_effect_expired.emit(self, "overcharge", pickup_overcharge_source_id, pickup_overcharge_realized)
		pickup_overcharge_source_id = -1
		pickup_overcharge_realized = false
	map_speed_multiplier = 1.0
	if not is_alive:
		respawn_timer = maxf(0.0, respawn_timer - delta)
		if visual_void_fall_timer > 0.0:
			visual_void_fall_timer = maxf(0.0, visual_void_fall_timer - delta)
			if visual_void_fall_timer <= 0.0:
				visible = false
		if visuals_enabled:
			_update_visual(delta, Vector2.ZERO)
			_request_visual_redraw()
		return
	energy = minf(balance.max_energy, energy + balance.energy_regen_per_second * delta)
	if needs_visual_redraw:
		_request_visual_redraw()

func apply_action(action: PlayerAction, delta: float, map_size: Vector2) -> void:
	if not is_alive:
		velocity = Vector2.ZERO
		return
	last_requested_move = action.move
	if action.aim.length_squared() > 0.001:
		aim_direction = action.aim.normalized()
	_try_shield(action)
	_try_dash(action)
	_try_shoot(action)
	var speed := balance.move_speed
	if shield_timer > 0.0:
		speed *= 1.0 - balance.shield_move_slow
	if pickup_speed_timer > 0.0:
		speed *= pickup_speed_multiplier
	speed *= map_speed_multiplier
	if dash_timer > 0.0:
		dash_timer = maxf(0.0, dash_timer - delta)
		velocity = Vector2.ZERO if movement_lock_timer > 0.0 else dash_direction * (balance.dash_distance / balance.dash_duration)
	else:
		velocity = Vector2.ZERO if movement_lock_timer > 0.0 else action.move * speed
	move_and_slide()
	global_position.x = clampf(global_position.x, balance.player_radius, map_size.x - balance.player_radius)
	global_position.y = clampf(global_position.y, balance.player_radius, map_size.y - balance.player_radius)
	if visuals_enabled:
		_update_visual(delta, action.move)
		_request_visual_redraw()

func take_damage(amount: float, attacker_id: int) -> Dictionary:
	var absorbed := 0.0
	var dealt := 0.0
	var killed := false
	if not is_alive or protection_timer > 0.0 or dash_invincible_timer > 0.0:
		absorbed = amount
		return {"dealt": dealt, "absorbed": absorbed, "killed": killed}
	if shield_timer > 0.0 and shield_absorb_remaining > 0.0:
		absorbed = minf(amount, shield_absorb_remaining)
		shield_absorb_remaining -= absorbed
	var remaining := maxf(0.0, amount - absorbed)
	if remaining > 0.0:
		health = maxf(0.0, health - remaining)
		dealt = remaining
		hit_flash_timer = 0.12
		hurt_expression_timer = HURT_EXPRESSION_DURATION
	if health <= 0.0:
		_die(attacker_id)
		killed = true
	GameEvents.emit_player_damaged({
		"victim_id": player_id,
		"attacker_id": attacker_id,
		"amount": dealt,
		"absorbed": absorbed,
		"health": health,
	})
	_request_visual_redraw()
	return {"dealt": dealt, "absorbed": absorbed, "killed": killed, "pickup_shield_source_id": pickup_shield_source_id if absorbed > 0.0 else -1}

func kill_by_environment() -> Dictionary:
	if not is_alive:
		return {"killed": false}
	health = 0.0
	hit_flash_timer = 0.12
	hurt_expression_timer = HURT_EXPRESSION_DURATION
	_die(-1)
	GameEvents.emit_player_damaged({
		"victim_id": player_id,
		"attacker_id": -1,
		"amount": balance.max_health,
		"absorbed": 0.0,
		"health": health,
	})
	GameEvents.emit_player_killed({"victim_id": player_id, "killer_id": -1, "position": global_position})
	_request_visual_redraw()
	return {"killed": true}

func kill_by_void() -> Dictionary:
	if not is_alive:
		return {"killed": false}
	health = 0.0
	hurt_expression_timer = HURT_EXPRESSION_DURATION
	is_alive = false
	respawn_timer = balance.respawn_delay
	last_killer_id = -1
	velocity = Vector2.ZERO
	collision_shape.disabled = true
	visual_void_fall_timer = visual_void_fall_duration
	visible = visuals_enabled
	AudioManager.play_event("death", global_position)
	GameEvents.emit_player_damaged({
		"victim_id": player_id,
		"attacker_id": -1,
		"amount": balance.max_health,
		"absorbed": 0.0,
		"health": health,
	})
	GameEvents.emit_player_killed({"victim_id": player_id, "killer_id": -1, "position": global_position})
	_request_visual_redraw()
	return {"killed": true}

func get_health_ratio() -> float:
	return clampf(health / balance.max_health, 0.0, 1.0)

func get_energy_ratio() -> float:
	return clampf(energy / balance.max_energy, 0.0, 1.0)

func get_shoot_cooldown_ratio() -> float:
	return clampf(shoot_cooldown_timer / _current_shoot_cooldown(), 0.0, 1.0)

func get_dash_cooldown_ratio() -> float:
	return clampf(dash_cooldown_timer / balance.dash_cooldown, 0.0, 1.0)

func get_shield_cooldown_ratio() -> float:
	return clampf(shield_cooldown_timer / balance.shield_cooldown, 0.0, 1.0)

func is_shielding() -> bool:
	return shield_timer > 0.0 and shield_absorb_remaining > 0.0

func is_dashing() -> bool:
	return dash_timer > 0.0

func has_respawn_protection() -> bool:
	return protection_timer > 0.0

func get_projectile_damage_multiplier() -> float:
	return pickup_damage_multiplier if pickup_overcharge_timer > 0.0 else 1.0

func get_projectile_speed_multiplier() -> float:
	return pickup_projectile_speed_multiplier if pickup_overcharge_timer > 0.0 else 1.0

func has_pickup_magnet() -> bool:
	return pickup_magnet_timer > 0.0

func restore_health(amount: float) -> float:
	if not is_alive:
		return 0.0
	var before := health
	health = minf(balance.max_health, health + maxf(0.0, amount))
	var restored := health - before
	if restored > 0.0:
		_trigger_pickup_flash(Color("#F07178"))
		_request_visual_redraw()
	return restored

func apply_pickup_shield(duration: float, absorb: float, source_id: int = -1) -> void:
	if not is_alive:
		return
	shield_timer = maxf(shield_timer, duration)
	shield_absorb_remaining = maxf(shield_absorb_remaining, absorb)
	pickup_shield_source_id = source_id
	pickup_shield_realized = false
	_trigger_pickup_flash(Color("#6EA8FE"))
	GameEvents.emit_shield_activated({"player_id": player_id, "duration": shield_timer, "absorb": shield_absorb_remaining})
	_request_visual_redraw()

func apply_haste(duration: float, speed_multiplier: float, fire_rate_multiplier: float, source_id: int = -1) -> void:
	if not is_alive:
		return
	pickup_speed_timer = maxf(pickup_speed_timer, duration)
	pickup_speed_multiplier = maxf(pickup_speed_multiplier, maxf(1.0, speed_multiplier))
	pickup_fire_rate_timer = maxf(pickup_fire_rate_timer, duration)
	pickup_fire_rate_multiplier = maxf(pickup_fire_rate_multiplier, maxf(1.0, fire_rate_multiplier))
	pickup_haste_source_id = source_id
	pickup_haste_realized = false
	_trigger_pickup_flash(Color("#E6A85C"))
	_request_visual_redraw()

func apply_overcharge(duration: float, damage_multiplier: float, projectile_speed_multiplier: float, source_id: int = -1) -> void:
	if not is_alive:
		return
	pickup_overcharge_timer = maxf(pickup_overcharge_timer, duration)
	pickup_damage_multiplier = maxf(pickup_damage_multiplier, maxf(1.0, damage_multiplier))
	pickup_projectile_speed_multiplier = maxf(pickup_projectile_speed_multiplier, maxf(1.0, projectile_speed_multiplier))
	pickup_overcharge_source_id = source_id
	pickup_overcharge_realized = false
	_trigger_pickup_flash(Color("#FF6B6B"))
	_request_visual_redraw()

func apply_magnet(duration: float) -> void:
	if not is_alive:
		return
	pickup_magnet_timer = maxf(pickup_magnet_timer, duration)
	_trigger_pickup_flash(Color("#63D7C4"))
	_request_visual_redraw()

func get_pickup_haste_source_id() -> int:
	return pickup_haste_source_id if pickup_fire_rate_timer > 0.0 else -1

func get_pickup_overcharge_source_id() -> int:
	return pickup_overcharge_source_id if pickup_overcharge_timer > 0.0 else -1

func mark_pickup_shield_realized() -> void:
	pickup_shield_realized = true

func mark_pickup_haste_realized() -> void:
	pickup_haste_realized = true

func mark_pickup_overcharge_realized() -> void:
	pickup_overcharge_realized = true

func apply_pulse_flash() -> void:
	if not is_alive:
		return
	_trigger_pickup_flash(Color("#A78BFA"))
	_request_visual_redraw()

func set_camouflage_intensity(intensity: float) -> void:
	var next_intensity := clampf(intensity, 0.0, 1.0)
	if absf(next_intensity - camouflage_intensity) <= 0.01:
		return
	camouflage_intensity = next_intensity
	_request_visual_redraw()

func set_mist_visibility(visibility_ratio: float) -> void:
	var next_visibility := clampf(visibility_ratio, 0.0, 1.0)
	if absf(next_visibility - mist_visibility) <= 0.01:
		return
	mist_visibility = next_visibility
	modulate = Color(modulate.r, modulate.g, modulate.b, mist_visibility)
	_request_visual_redraw()

func displace_by_pickup(push: Vector2, map_size: Vector2, arena_map: Node) -> void:
	if not is_alive or push.length_squared() <= 0.001:
		return
	var steps := 8
	var accepted := global_position
	for i in range(1, steps + 1):
		var candidate := global_position + push * (float(i) / float(steps))
		candidate.x = clampf(candidate.x, balance.player_radius, map_size.x - balance.player_radius)
		candidate.y = clampf(candidate.y, balance.player_radius, map_size.y - balance.player_radius)
		if arena_map != null and arena_map.has_method("is_spawn_area_clear"):
			if not arena_map.is_spawn_area_clear(candidate, balance.player_radius * 0.85):
				break
		accepted = candidate
	global_position = accepted
	_request_visual_redraw()

func _try_shoot(action: PlayerAction) -> void:
	if not action.shoot:
		return
	if shoot_cooldown_timer > 0.0:
		return
	if energy < balance.projectile_energy_cost:
		if empty_feedback_timer <= 0.0:
			empty_feedback_timer = 0.28
			visual_empty_flash = 0.16
			AudioManager.play_event("empty", global_position)
		return
	energy -= balance.projectile_energy_cost
	shoot_cooldown_timer = _current_shoot_cooldown()
	var origin := global_position
	visual_recoil = 1.0
	visual_muzzle_flash = 0.14
	projectile_requested.emit(self, origin, aim_direction)
	AudioManager.play_event("shoot", origin)

func _try_dash(action: PlayerAction) -> void:
	if movement_lock_timer > 0.0 or not action.dash or dash_cooldown_timer > 0.0 or energy < balance.dash_energy_cost:
		return
	energy -= balance.dash_energy_cost
	dash_cooldown_timer = balance.dash_cooldown
	dash_timer = balance.dash_duration
	dash_invincible_timer = balance.dash_invincible_time
	dash_direction = action.move.normalized() if action.move.length_squared() > 0.001 else aim_direction
	GameEvents.emit_dash_started({"player_id": player_id, "position": global_position, "direction": dash_direction})
	AudioManager.play_event("dash", global_position)

func _try_shield(action: PlayerAction) -> void:
	if not action.shield or shield_cooldown_timer > 0.0 or energy < balance.shield_energy_cost:
		return
	energy -= balance.shield_energy_cost
	shield_cooldown_timer = balance.shield_cooldown
	shield_timer = balance.shield_duration
	shield_absorb_remaining = balance.shield_absorb
	GameEvents.emit_shield_activated({"player_id": player_id, "duration": shield_timer, "absorb": shield_absorb_remaining})
	AudioManager.play_event("shield", global_position)

func _die(killer_id: int) -> void:
	is_alive = false
	respawn_timer = balance.respawn_delay
	last_killer_id = killer_id
	velocity = Vector2.ZERO
	collision_shape.disabled = true
	visual_death_timer = 0.55
	AudioManager.play_event("death", global_position)

func add_movement_lock(duration: float) -> void:
	movement_lock_timer = maxf(movement_lock_timer, duration)

func apply_map_speed_multiplier(multiplier: float) -> void:
	map_speed_multiplier = minf(map_speed_multiplier, clampf(multiplier, 0.0, 1.0))

func _trigger_pickup_flash(color: Color) -> void:
	pickup_flash_timer = 0.42
	pickup_flash_color = color

func _current_shoot_cooldown() -> float:
	var cooldown := balance.shoot_cooldown
	if pickup_fire_rate_timer > 0.0:
		cooldown /= maxf(1.0, pickup_fire_rate_multiplier)
	return maxf(0.04, cooldown)

func _update_labels() -> void:
	if id_label == null or type_label == null:
		return
	id_label.text = display_name
	type_label.text = "AGENT" if not is_human else "HUMAN"
	id_label.position = Vector2(-42, -72)
	type_label.position = Vector2(-24, -58)
	id_label.add_theme_color_override("font_color", Color("#F1F5FA"))
	type_label.add_theme_color_override("font_color", Color("#A78BFA") if not is_human else Color("#63D7C4"))
	id_label.add_theme_font_size_override("font_size", 11)
	type_label.add_theme_font_size_override("font_size", 10)
	type_label.modulate = Color("#A78BFA") if not is_human else Color("#F1F5FA")

func _draw() -> void:
	if visual_void_fall_timer > 0.0:
		var fall_t := 1.0 - clampf(visual_void_fall_timer / maxf(visual_void_fall_duration, 0.001), 0.0, 1.0)
		var fall_scale := maxf(0.28, 1.0 - fall_t * 0.72)
		draw_set_transform(Vector2(0.0, fall_t * 24.0), fall_t * 0.24, Vector2(fall_scale, fall_scale))
		_draw_character()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	_draw_character()

func _reset_visual_spawn() -> void:
	visual_upper_angle = Vector2.UP.angle()
	visual_lower_angle = Vector2.UP.angle()
	visual_recoil = 0.0
	visual_muzzle_flash = 0.0
	visual_empty_flash = 0.0
	visual_spawn_timer = 0.45
	visual_death_timer = 0.0
	visual_void_fall_timer = 0.0
	visual_last_move_direction = Vector2.UP

func _update_visual(delta: float, desired_move: Vector2) -> void:
	visual_recoil = maxf(0.0, visual_recoil - delta * 8.5)
	visual_muzzle_flash = maxf(0.0, visual_muzzle_flash - delta)
	visual_empty_flash = maxf(0.0, visual_empty_flash - delta)
	visual_spawn_timer = maxf(0.0, visual_spawn_timer - delta)
	visual_death_timer = maxf(0.0, visual_death_timer - delta)
	visual_upper_angle = Vector2.UP.angle()
	var move_dir := desired_move.normalized() if desired_move.length_squared() > 0.001 else Vector2.ZERO
	if move_dir.length_squared() <= 0.001 and velocity.length_squared() > 1.0:
		move_dir = velocity.normalized()
	if move_dir.length_squared() > 0.001:
		visual_last_move_direction = move_dir
	var lower_target := visual_last_move_direction if move_dir.length_squared() > 0.001 else Vector2.UP
	visual_lower_angle = lerp_angle(visual_lower_angle, lower_target.angle(), clampf(delta * 12.0, 0.0, 1.0))
	var speed_ratio := clampf(velocity.length() / maxf(balance.move_speed, 1.0), 0.0, 1.45)
	visual_walk_cycle = fposmod(visual_walk_cycle + delta * (lerpf(5.0, 12.0, clampf(speed_ratio, 0.0, 1.0)) if speed_ratio > 0.03 else 1.8), TAU)

func _draw_character() -> void:
	var spawn_alpha := 1.0 if visual_spawn_timer <= 0.0 else clampf(1.0 - visual_spawn_timer / 0.45, 0.15, 1.0)
	var alpha := (1.0 if is_alive else 0.38) * spawn_alpha
	if visual_void_fall_timer > 0.0:
		alpha *= clampf(visual_void_fall_timer / maxf(visual_void_fall_duration, 0.001), 0.0, 1.0)
	var body_alpha := alpha * lerpf(1.0, 0.18, camouflage_intensity)
	var team := body_color
	var facing := Vector2.UP
	var move_dir := Vector2.RIGHT.rotated(visual_lower_angle)
	var speed_ratio := clampf(velocity.length() / maxf(balance.move_speed, 1.0), 0.0, 1.0)
	var core := Vector2(0, -12.0) + facing * clampf(visual_recoil, 0.0, 1.0) * -1.5
	if bool(SettingsManager.get_value("video", "shadows", true)):
		var shadow_scale := 1.0 + sin(visual_walk_cycle * 1.7) * 0.025
		draw_set_transform(Vector2(0, 19), 0.0, Vector2(2.18 * shadow_scale, 0.42 * shadow_scale))
		draw_circle(Vector2.ZERO, 20.0, Color("#000000", 0.34 * body_alpha))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_arc(Vector2.ZERO, balance.player_radius + 5.0, 0, TAU, 32, Color(team.r, team.g, team.b, 0.58 * alpha), 2.2)
	if pickup_speed_timer > 0.0 or pickup_fire_rate_timer > 0.0:
		var spin := Time.get_ticks_msec() * 0.006
		draw_arc(Vector2.ZERO, balance.player_radius + 9.0, spin, spin + PI * 1.35, 28, Color("#E6A85C", 0.58 * alpha), 2.8)
	if pickup_overcharge_timer > 0.0:
		var over_spin := -Time.get_ticks_msec() * 0.005
		draw_arc(Vector2.ZERO, balance.player_radius + 14.0, over_spin, over_spin + PI * 1.18, 28, Color("#FF6B6B", 0.58 * alpha), 2.8)
	if pickup_magnet_timer > 0.0:
		var magnet_spin := Time.get_ticks_msec() * 0.004
		draw_arc(Vector2.ZERO, balance.player_radius + 18.0, magnet_spin, magnet_spin + PI * 0.82, 24, Color("#63D7C4", 0.42 * alpha), 2.4)
		draw_arc(Vector2.ZERO, balance.player_radius + 18.0, magnet_spin + PI, magnet_spin + PI * 1.82, 24, Color("#63D7C4", 0.42 * alpha), 2.4)
	if pickup_flash_timer > 0.0:
		var flash_t := clampf(pickup_flash_timer / 0.42, 0.0, 1.0)
		draw_arc(Vector2.ZERO, balance.player_radius + 20.0 * (1.0 - flash_t), 0, TAU, 32, Color(pickup_flash_color.r, pickup_flash_color.g, pickup_flash_color.b, 0.45 * flash_t * alpha), 2.6)
	if is_dashing():
		draw_line(-move_dir * 44.0, -move_dir * 12.0, Color("#63D7C4", 0.26 * alpha), 13.0)
	_draw_ghost_sprite(core, facing, team, speed_ratio, alpha, body_alpha, aim_direction)
	if is_shielding():
		draw_arc(Vector2.ZERO, balance.player_radius + 11.0, 0, TAU, 36, Color("#6EA8FE", 0.58 * alpha), 3.0)
	if has_respawn_protection():
		var t := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.01)
		draw_arc(Vector2.ZERO, balance.player_radius + 16.0, 0, TAU, 36, Color("#E6A85C", 0.48 * t * alpha), 2.0)
	if visual_spawn_timer > 0.0:
		var spawn_t := 1.0 - spawn_alpha
		draw_arc(Vector2.ZERO, 22.0 + spawn_t * 18.0, 0, TAU, 32, Color("#63D7C4", 0.55 * alpha), 2.0)
	_draw_world_health(alpha * lerpf(1.0, 0.28, camouflage_intensity))

func _draw_ghost_sprite(origin: Vector2, dir: Vector2, team: Color, speed_ratio: float, alpha: float, body_alpha: float, shot_direction: Vector2) -> void:
	var body_fill := team.lightened(0.18)
	if hit_flash_timer > 0.0 and bool(SettingsManager.get_value("video", "hit_flash", true)):
		body_fill = Color.WHITE
	var hurt_expression := _hurt_expression_intensity()
	var mouth_open := clampf(maxf(visual_muzzle_flash / 0.14, visual_empty_flash / 0.16 * 0.65), 0.0, 1.0)
	var mouth_center := origin + Vector2(0, 8.0)
	var shot_dir := shot_direction.normalized() if shot_direction.length_squared() > 0.001 else Vector2.UP
	var idle_wave := 0.55 + speed_ratio * 0.75
	var wave := sin(visual_walk_cycle * 2.0) * 2.4 * idle_wave
	var breathe := 0.5 + 0.5 * sin(visual_walk_cycle * 1.35)
	var outline := Color("#04111F", 0.82 * alpha)
	var deep_shadow := Color("#020713", 0.38 * body_alpha)
	var shine := Color("#F1F5FA", 0.18 * body_alpha)
	var points := PackedVector2Array([
		origin + Vector2(0.0, -27.0),
		origin + Vector2(13.0, -23.0),
		origin + Vector2(22.0, -12.0),
		origin + Vector2(24.0, 4.0),
		origin + Vector2(20.0, 19.0 + wave * 0.35),
		origin + Vector2(13.0, 13.0 - wave),
		origin + Vector2(7.0, 22.5 + wave),
		origin + Vector2(0.0, 14.0 - wave * 0.7),
		origin + Vector2(-7.0, 22.5 + wave),
		origin + Vector2(-13.0, 13.0 - wave),
		origin + Vector2(-20.0, 19.0 + wave * 0.35),
		origin + Vector2(-24.0, 4.0),
		origin + Vector2(-22.0, -12.0),
		origin + Vector2(-13.0, -23.0),
	])
	var shadow_colors := _solid_colors(points.size(), deep_shadow)
	var body_colors := _solid_colors(points.size(), Color(body_fill.r, body_fill.g, body_fill.b, 0.96 * body_alpha))
	var shadow_points := PackedVector2Array()
	for p in points:
		shadow_points.append(p + Vector2(0, 8))
	var glow_points := PackedVector2Array()
	for p in points:
		glow_points.append(origin + (p - origin) * 1.12)
	draw_polygon(shadow_points, shadow_colors)
	draw_polygon(glow_points, _solid_colors(glow_points.size(), Color(team.r, team.g, team.b, (0.13 + breathe * 0.05) * body_alpha)))
	draw_polygon(points, body_colors)
	var front_face := PackedVector2Array([
		points[4],
		points[5],
		points[6],
		points[7],
		points[8],
		points[9],
		points[10],
		points[10] + Vector2(0, 9),
		points[8] + Vector2(0, 12),
		points[7] + Vector2(0, 10),
		points[6] + Vector2(0, 12),
		points[4] + Vector2(0, 9),
	])
	draw_polygon(front_face, _solid_colors(front_face.size(), Color(team.darkened(0.22).r, team.darkened(0.22).g, team.darkened(0.22).b, 0.42 * body_alpha)))
	var inner_points := PackedVector2Array()
	for p in points:
		inner_points.append(origin + (p - origin) * 0.78)
	draw_polygon(inner_points, _solid_colors(inner_points.size(), Color("#FFFFFF", (0.07 + breathe * 0.035) * body_alpha)))
	for i in range(points.size()):
		draw_line(points[i], points[(i + 1) % points.size()], outline, 2.0)
	draw_arc(origin + Vector2(-7.0, -7.0), 18.0, PI * 1.08, PI * 1.54, 14, shine, 2.6)
	draw_line(origin + Vector2(-16, -3), origin + Vector2(16, -3), Color(team.lightened(0.35).r, team.lightened(0.35).g, team.lightened(0.35).b, 0.22 * body_alpha), 2.0)
	draw_circle(origin + Vector2(0, 3), 6.4, Color("#FFFFFF", 0.07 * body_alpha))
	draw_arc(origin + Vector2(0, 3), 7.5, PI * 0.18, PI * 0.82, 12, Color(team.darkened(0.15).r, team.darkened(0.15).g, team.darkened(0.15).b, 0.34 * body_alpha), 1.3)
	_draw_ghost_eye(origin + Vector2(-7.4, -10.0), mouth_open, hurt_expression, body_alpha, -1.0)
	_draw_ghost_eye(origin + Vector2(7.4, -10.0), mouth_open, hurt_expression, body_alpha, 1.0)
	draw_circle(origin + Vector2(-12.5, -15.0), 2.1, Color("#FFFFFF", 0.28 * body_alpha * (1.0 - hurt_expression * 0.35)))
	draw_circle(origin + Vector2(12.5, -15.0), 2.1, Color("#FFFFFF", 0.28 * body_alpha * (1.0 - hurt_expression * 0.35)))
	if mouth_open > 0.04 and hurt_expression < 0.65:
		var radius := lerpf(4.0, 9.4, mouth_open)
		var open_alpha := alpha * (1.0 - hurt_expression * 0.55)
		draw_circle(mouth_center, radius, Color("#030712", 0.96 * open_alpha))
		draw_circle(mouth_center - Vector2(0, 4.0), radius * 0.44, Color("#0B1020", 0.9 * open_alpha))
	else:
		var smile_alpha := alpha * (1.0 - hurt_expression)
		var cry_alpha := alpha * hurt_expression
		draw_arc(mouth_center + Vector2(0, -1.0), 7.0, PI * 0.16, PI * 0.84, 12, Color("#040812", 0.78 * smile_alpha), 1.9)
		draw_circle(mouth_center + Vector2(-9.0, -1.0), 1.6, Color("#FFFFFF", 0.18 * smile_alpha))
		draw_circle(mouth_center + Vector2(9.0, -1.0), 1.6, Color("#FFFFFF", 0.18 * smile_alpha))
		if cry_alpha > 0.01:
			draw_arc(mouth_center + Vector2(0, 6.0), 7.8, PI * 1.10, PI * 1.90, 14, Color("#040812", 0.90 * cry_alpha), 2.2)
			draw_circle(mouth_center + Vector2(0.0, 8.5), 2.0, Color("#040812", 0.40 * cry_alpha))
			draw_circle(mouth_center + Vector2(-7.0, 0.0), 1.2, Color("#8DD7FF", 0.55 * cry_alpha))
			draw_circle(mouth_center + Vector2(7.0, 0.0), 1.2, Color("#8DD7FF", 0.55 * cry_alpha))
	if visual_muzzle_flash > 0.0:
		var flash_alpha := clampf(visual_muzzle_flash / 0.14, 0.0, 1.0) * alpha
		var flash_center := mouth_center + shot_dir * 18.0
		draw_circle(flash_center, 9.0 * flash_alpha, Color("#FFE7A3", 0.72 * flash_alpha))
		draw_circle(mouth_center + shot_dir * 27.0, 4.8 * flash_alpha, Color("#F1F5FA", 0.68 * flash_alpha))
		draw_line(mouth_center + shot_dir * 5.0, mouth_center + shot_dir * 27.0, Color(team.r, team.g, team.b, 0.48 * flash_alpha), 3.4)
	if visual_empty_flash > 0.0:
		draw_arc(mouth_center + Vector2(0, -3.0), 8.0, PI * 1.12, PI * 1.88, 10, Color("#F07178", clampf(visual_empty_flash / 0.16, 0.0, 1.0) * alpha), 1.8)

func _draw_ghost_eye(center: Vector2, mouth_open: float, hurt_expression: float, alpha: float, side_sign: float) -> void:
	draw_circle(center + Vector2(0, 0.8), 6.4, Color("#04111F", 0.20 * alpha))
	draw_circle(center, 5.9, Color("#F6FBFF", 0.98 * alpha))
	var pupil_offset := Vector2(lerpf(1.9 + mouth_open * 0.55, 0.4 * side_sign, hurt_expression), lerpf(0.0, 2.1, hurt_expression))
	var pupil_radius := lerpf(2.55, 2.15, hurt_expression)
	draw_circle(center + pupil_offset, pupil_radius, Color("#07101D", 0.94 * alpha))
	draw_circle(center + pupil_offset + Vector2(0.8, -1.1), 0.82, Color("#FFFFFF", 0.78 * alpha))
	var lid_alpha := 0.32 + hurt_expression * 0.30
	draw_arc(center + Vector2(0, 0.4), 6.5, PI * 1.02, PI * 1.98, 12, Color("#07101D", lid_alpha * hurt_expression * alpha), 1.4)
	if hurt_expression > 0.02:
		var brow_center := center + Vector2(-side_sign * 1.6, -9.4)
		draw_arc(brow_center, 6.2, PI * 1.12, PI * 1.88, 12, Color("#04111F", 0.44 * hurt_expression * alpha), 1.3)
		var tear_center := center + Vector2(5.0 * side_sign, 7.4 + sin(Time.get_ticks_msec() * 0.01 + side_sign) * 1.2)
		draw_circle(tear_center, 2.4, Color("#8DD7FF", 0.76 * hurt_expression * alpha))
		draw_circle(tear_center + Vector2(0.0, 3.2), 1.5, Color("#8DD7FF", 0.52 * hurt_expression * alpha))
		draw_line(tear_center + Vector2(0, 1.4), tear_center + Vector2(0, 7.2), Color("#8DD7FF", 0.38 * hurt_expression * alpha), 1.4)

func _hurt_expression_intensity() -> float:
	if hurt_expression_timer <= 0.0:
		return 0.0
	var fade_in := clampf((HURT_EXPRESSION_DURATION - hurt_expression_timer) / 0.18, 0.0, 1.0)
	var fade_out := clampf(hurt_expression_timer / 0.45, 0.0, 1.0)
	return smoothstep(0.0, 1.0, minf(fade_in, fade_out))

func _solid_colors(count: int, color: Color) -> PackedColorArray:
	var colors := PackedColorArray()
	for _i in range(count):
		colors.append(color)
	return colors

func _draw_character_legs(origin: Vector2, dir: Vector2, side: Vector2, team: Color, speed_ratio: float, alpha: float) -> void:
	var stride := sin(visual_walk_cycle) * 7.5 * speed_ratio
	var lift := cos(visual_walk_cycle) * 2.5 * speed_ratio
	for i in range(2):
		var sign := -1.0 if i == 0 else 1.0
		var hip := origin - dir * 5.0 + side * sign * 7.0 + Vector2(0, 4)
		var knee := hip - dir * (8.0 + stride * sign * 0.45) + side * sign * (1.0 + lift * sign)
		var foot := hip - dir * (18.0 + stride * sign) + side * sign * (2.0 + lift * sign) + Vector2(0, 5)
		_draw_capsule(hip, knee, 6.4, Color("#3B465F").lerp(team, 0.14), Color("#06101F", 0.75 * alpha), alpha)
		_draw_capsule(knee, foot, 5.8, Color("#252F45").lerp(team, 0.08), Color("#06101F", 0.70 * alpha), alpha)
		draw_circle(foot + Vector2(1, 2), 4.8, Color("#07101D", 0.95 * alpha))
		draw_line(foot - side * 3.8, foot + side * 4.8, Color(team.r, team.g, team.b, 0.26 * alpha), 1.4)

func _draw_character_arms_and_weapon(origin: Vector2, dir: Vector2, side: Vector2, team: Color, alpha: float) -> void:
	var recoil := clampf(visual_recoil, 0.0, 1.0)
	var right_shoulder := origin + dir * 4.0 + side * 10.0
	var left_shoulder := origin + dir * 3.0 - side * 10.0
	var weapon_hand := origin + dir * (17.0 - recoil * 5.0) + side * 5.5
	var support_hand := origin + dir * (15.0 - recoil * 4.0) - side * 6.5
	draw_line(right_shoulder + Vector2(0, 5), weapon_hand + Vector2(0, 5), Color("#020713", 0.30 * alpha), 6.5)
	draw_line(left_shoulder + Vector2(0, 5), support_hand + Vector2(0, 5), Color("#020713", 0.26 * alpha), 6.0)
	_draw_capsule(right_shoulder, weapon_hand, 5.5, Color("#323D55").lerp(team, 0.18), Color("#06101F", 0.72 * alpha), alpha)
	_draw_capsule(left_shoulder, support_hand, 5.0, Color("#323D55").lerp(team, 0.10), Color("#06101F", 0.65 * alpha), alpha)
	draw_circle(weapon_hand, 3.5, Color("#D7BFA4", alpha))
	draw_circle(support_hand, 3.2, Color("#D7BFA4", alpha))
	_draw_weapon(weapon_hand, dir, team, recoil, alpha)

func _draw_weapon(hand_position: Vector2, dir: Vector2, team: Color, recoil: float, alpha: float) -> void:
	var side := dir.orthogonal()
	var recoil_offset := recoil * 6.0
	var stock := hand_position - dir * (7.0 + recoil_offset)
	var barrel := hand_position + dir * (28.0 - recoil_offset)
	_draw_capsule(stock - side * 1.5, barrel, 5.5, Color("#111827"), Color("#DCE7F7", 0.18 * alpha), alpha)
	_draw_capsule(hand_position + side * 3.0, barrel + dir * 5.0, 2.0, team.lightened(0.2), Color.TRANSPARENT, alpha)
	draw_line(stock - side * 6.0, stock + side * 6.0, Color("#263248", alpha), 4.0)
	if visual_muzzle_flash > 0.0:
		var flash_alpha := clampf(visual_muzzle_flash / 0.09, 0.0, 1.0) * alpha
		var tip := barrel + dir * 7.0
		draw_polygon(PackedVector2Array([barrel + side * 5.0, tip + dir * 12.0, barrel - side * 5.0]), PackedColorArray([Color("#FFE7A3", flash_alpha), Color("#63D7C4", flash_alpha * 0.75), Color("#FFFFFF", flash_alpha * 0.85)]))
	elif visual_empty_flash > 0.0:
		draw_arc(barrel + dir * 4.0, 6.0, -0.65, 0.65, 10, Color("#F07178", clampf(visual_empty_flash / 0.16, 0.0, 1.0) * alpha), 1.6)

func _draw_character_head(center: Vector2, dir: Vector2, side: Vector2, team: Color, alpha: float) -> void:
	draw_circle(center + Vector2(0, 4), 9.5, Color("#020713", 0.35 * alpha))
	draw_circle(center, 9.2, Color("#06101F", 0.88 * alpha))
	draw_circle(center, 7.8, Color("#D7BFA4", alpha))
	draw_arc(center - dir * 0.5, 8.2, PI * 1.05, PI * 1.95, 18, Color(team.r, team.g, team.b, 0.65 * alpha), 2.2)
	draw_line(center - side * 4.9 + dir * 3.1, center + side * 4.9 + dir * 3.1, Color("#0B1020", 0.9 * alpha), 2.6)
	draw_circle(center - side * 4.8 - dir * 2.0, 2.2, Color(team.r, team.g, team.b, 0.9 * alpha))

func _draw_world_health(alpha: float) -> void:
	var ratio := get_health_ratio()
	var width := 48.0 * float(SettingsManager.get_value("accessibility", "health_bar_size", 1.0))
	var bg := Rect2(Vector2(-width * 0.5, -48.0), Vector2(width, 4.5))
	var hp_color := Color("#63D7C4") if ratio > 0.55 else Color("#E6A85C") if ratio > 0.28 else Color("#F07178")
	draw_rect(bg.grow(1.0), Color("#050812", 0.38 * alpha))
	draw_rect(bg, Color("#243047", 0.82 * alpha))
	draw_rect(Rect2(bg.position, Vector2(width * ratio, bg.size.y)), Color(hp_color.r, hp_color.g, hp_color.b, 0.9 * alpha))
	draw_rect(bg, Color("#F1F5FA", 0.18 * alpha), false, 1.0)

func _draw_capsule(a: Vector2, b: Vector2, width: float, fill: Color, outline: Color, alpha: float) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	if outline.a > 0.0:
		draw_line(a, b, outline, width + 2.0)
		draw_circle(a, width * 0.5 + 1.0, outline)
		draw_circle(b, width * 0.5 + 1.0, outline)
	var c := Color(fill.r, fill.g, fill.b, fill.a * alpha)
	draw_line(a, b, c, width)
	draw_circle(a, width * 0.5, c)
	draw_circle(b, width * 0.5, c)
