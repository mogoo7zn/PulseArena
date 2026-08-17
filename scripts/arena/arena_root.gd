extends Node2D
# 对战主场景控制器，负责玩家、弹道、道具、地图规则和比赛循环。
class_name ArenaRoot

const PLAYER_SCENE: PackedScene = preload("res://scenes/gameplay/Player.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/gameplay/Projectile.tscn")
const PICKUP_SCENE: PackedScene = preload("res://scenes/gameplay/Pickup.tscn")
const SimpleEffectScript = preload("res://scripts/gameplay/simple_effect.gd")
const ModelAgentControllerScript = preload("res://scripts/controllers/model_agent_controller.gd")
const HybridAgentControllerScript = preload("res://scripts/controllers/hybrid_agent_controller.gd")
const HybridAgentConfigScript = preload("res://scripts/agents/hybrid_agent_config.gd")
const HighLevelDecision = preload("res://scripts/agents/tactical_decision.gd")
const MatchManagerScript = preload("res://scripts/core/match_manager.gd")
const ScoreManagerScript = preload("res://scripts/core/score_manager.gd")
const SpawnManagerScript = preload("res://scripts/core/spawn_manager.gd")
const ReplayManagerScript = preload("res://scripts/replay/replay_manager.gd")
const RewardCalculatorScript = preload("res://scripts/rl/reward_calculator.gd")
const MAP_SCENE: PackedScene = preload("res://scenes/arena/ArenaCross.tscn")
const HUD_SCENE: PackedScene = preload("res://scenes/ui/GameHUD.tscn")
const DEBUG_OVERLAY_SCENE: PackedScene = preload("res://scenes/debug/DebugOverlay.tscn")
const DebugRuntimeSnapshot = preload("res://scripts/debug/debug_runtime_snapshot.gd")
const HUD_UPDATE_INTERVAL := 1.0 / 12.0
const DEBUG_UPDATE_INTERVAL := 1.0 / 4.0
const PICKUP_TYPE_HEALTH := "health"
const PICKUP_TYPE_SHIELD := "shield"
const PICKUP_TYPE_HASTE := "haste"
const PICKUP_TYPE_PULSE := "pulse"
const PICKUP_TYPE_OVERCHARGE := "overcharge"
const PICKUP_TYPE_MAGNET := "magnet"
const TRAINING_RESOURCE_CONTEST := "resource_contest"

var config: MatchConfig
var balance: GameBalance = GameBalance.default()
var rng := RandomNumberGenerator.new()
var players: Array[ArenaPlayer] = []
var projectiles: Array[ArenaProjectile] = []
var match_manager = MatchManagerScript.new()
var score_manager = ScoreManagerScript.new()
var spawn_manager = SpawnManagerScript.new()
var replay_manager = ReplayManagerScript.new()
var reward_calculator = RewardCalculatorScript.new()
var arena_map: ArenaCross
var pickup_layer: Node2D
var players_layer: Node2D
var projectile_layer: Node2D
var feedback_layer: Node2D
var camera: Camera2D
var hud_layer: CanvasLayer
var hud: Control
var debug_layer: CanvasLayer
var debug_overlay: DebugOverlay
var debug_toggle_button: Button
var projectile_counter: int = 0
var pickup_counter: int = 0
var pickups: Array = []
var pending_pulses: Array[Dictionary] = []
var pickup_spawn_timer: float = 0.0
var hud_update_timer: float = 0.0
var debug_update_timer: float = 0.0
var started: bool = false
var finished: bool = false
var controller_action_cache: Dictionary = {}
var controller_observation_cache: Dictionary = {}
var controller_decision_timers: Dictionary = {}
var external_action_cache: Dictionary = {}
var tactical_decision_cache: Dictionary = {}
var tactical_decision_generations: Dictionary = {}
var tactical_rewarded_generations: Dictionary = {}
var tactical_decision_facts: Dictionary = {}
var match_result: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	if config != null:
		call_deferred("_start_match")
	# Switch BGM to the track for the active map (one of arena_cross / neon_docks / reactor_ring / skyline_yard).
	var am := get_node_or_null("/root/AudioManager")
	if am != null and config != null:
		var map_key: String = AudioManager.MAP_BGM_KEY.get(config.map_id, "")
		if not map_key.is_empty():
			am.play_bgm(map_key)

func configure(match_config: MatchConfig) -> void:
	config = match_config.duplicate_config()
	if is_inside_tree():
		call_deferred("_start_match")

func build_observation(player: ArenaPlayer, validate_private_fields: bool = false) -> AgentObservation:
	return ObservationBuilder.build(player, players, projectiles, balance, config, arena_map, match_manager.get_remaining_ratio(), score_manager.get_player_score(player.player_id), validate_private_fields, pickups)

func get_rewards() -> Dictionary:
	var out: Dictionary = {}
	for player in players:
		out[player.player_id] = reward_calculator.get_total(player.player_id)
	return out

func get_reward_components(player_id: int) -> Dictionary:
	return reward_calculator.get_components(player_id)

func get_tactical_event_counts(player_id: int) -> Dictionary:
	return reward_calculator.get_tactical_event_counts(player_id)

func get_resource_event_counts(player_id: int) -> Dictionary:
	return reward_calculator.get_resource_event_counts(player_id)

func get_map_event_counts(player_id: int) -> Dictionary:
	return reward_calculator.get_map_event_counts(player_id)

func get_tactical_player_ids() -> Array[int]:
	var out: Array[int] = []
	for player in players:
		if player.controller != null and player.controller.get_script() == HybridAgentControllerScript:
			out.append(int(player.player_id))
	out.sort()
	return out

func apply_training_actions(actions: Dictionary) -> void:
	tactical_decision_cache.clear()
	for key in actions.keys():
		var player_id := _parse_external_player_id(key)
		if player_id < 0:
			continue
		var action := _action_from_external(actions[key], _fallback_aim_for_player_id(player_id))
		if action != null:
			external_action_cache[player_id] = action.copy()

func apply_tactical_decisions(decisions: Dictionary) -> bool:
	var expected_player_ids := get_tactical_player_ids()
	var received_player_ids: Array[int] = []
	var validated: Dictionary = {}
	for key in decisions.keys():
		var player_id := _parse_external_player_id(key)
		if player_id < 0 or received_player_ids.has(player_id):
			return false
		received_player_ids.append(player_id)
		var player: ArenaPlayer = _player_for_id(player_id)
		var decision: Variant = decisions[key]
		if player == null or player.controller == null or player.controller.get_script() != HybridAgentControllerScript:
			return false
		if decision == null or not decision.has_method("apply_masks"):
			return false
		validated[player_id] = decision.copy()
	received_player_ids.sort()
	if received_player_ids != expected_player_ids:
		return false
	external_action_cache.clear()
	tactical_decision_cache = validated
	for player_id in validated.keys():
		tactical_decision_generations[player_id] = int(tactical_decision_generations.get(player_id, 0)) + 1
	return true

func get_executed_tactical_decision(player_id: int) -> Dictionary:
	var player: ArenaPlayer = _player_for_id(player_id)
	if player == null or player.controller == null or player.controller.get_script() != HybridAgentControllerScript:
		return {}
	return player.controller.current_decision.to_dict()

func get_tactical_diagnostics(player_id: int) -> Dictionary:
	var player: ArenaPlayer = _player_for_id(player_id)
	if player == null or player.controller == null or not player.controller.has_method("get_diagnostics"):
		return {}
	var diagnostics: Dictionary = player.controller.get_diagnostics()
	diagnostics["decision_generation_id"] = int(tactical_decision_generations.get(player_id, 0))
	return diagnostics

func get_match_result() -> Dictionary:
	if not finished:
		return {}
	return match_result.duplicate(true)

func _physics_process(delta: float) -> void:
	if not started or finished or config == null:
		return
	if GameFlowManager.current_state == GameFlowManagerService.GameState.PAUSED:
		return
	match_manager.physics_step(delta)
	_update_players(delta, match_manager.playing)
	if match_manager.playing:
		_update_pickups(delta)
		_update_pending_pulses(delta)
		_update_projectiles(delta)
	if match_manager.finished:
		_finish_match()
	hud_update_timer -= delta
	if hud != null and hud_update_timer <= 0.0 and hud.has_method("update_snapshot"):
		hud_update_timer = HUD_UPDATE_INTERVAL
		hud.update_snapshot(players, score_manager, match_manager, reward_calculator)
	debug_update_timer -= delta
	if debug_overlay != null and debug_update_timer <= 0.0:
		debug_update_timer = DEBUG_UPDATE_INTERVAL
		var snapshot := DebugRuntimeSnapshot.build(
			config.map_id,
			GameFlowManagerService.GameState.keys()[GameFlowManager.current_state],
			match_manager.remaining_time,
			players.size(),
			projectiles.size(),
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		snapshot["score_summary"] = _debug_score_summary()
		debug_overlay.update_runtime(snapshot)

func _start_match() -> void:
	if config == null:
		return
	started = true
	finished = false
	balance = ConfigDB.get_balance()
	balance.time_limit = config.time_limit
	rng.seed = config.random_seed
	spawn_manager.set_seed(config.random_seed)
	match_manager.configure(config)
	score_manager.reset()
	reward_calculator.configure(config, ConfigDB.get_reward_config().for_profile(config.reward_profile_id))
	replay_manager.start(config)
	match_result.clear()
	pickup_counter = 0
	tactical_decision_generations.clear()
	tactical_rewarded_generations.clear()
	tactical_decision_facts.clear()
	if AudioManager.has_method("set_runtime_audio_enabled"):
		AudioManager.set_runtime_audio_enabled(not config.headless)
	pickups.clear()
	pending_pulses.clear()
	_clear_controller_caches()
	pickup_spawn_timer = 0.0
	hud_update_timer = 0.0
	debug_update_timer = 0.0
	_clear_children()
	_build_world()
	_create_roster()
	_spawn_initial_players()
	if hud != null and hud.has_method("configure"):
		hud.configure(config, players, score_manager, match_manager)
	GameFlowManager.enter_countdown()
	GameEvents.emit_match_started(config)

func _build_world() -> void:
	if not config.headless:
		camera = Camera2D.new()
		camera.name = "ArenaCamera"
		camera.position = balance.map_size * 0.5
		_configure_camera_for_map()
		camera.enabled = true
		add_child(camera)
	arena_map = MAP_SCENE.instantiate() as ArenaCross
	if arena_map.has_method("set_visuals_enabled"):
		arena_map.set_visuals_enabled(not config.headless)
	add_child(arena_map)
	arena_map.build_map(balance, config.map_id, config.random_seed)
	pickup_layer = Node2D.new()
	pickup_layer.name = "Pickups"
	add_child(pickup_layer)
	projectile_layer = Node2D.new()
	projectile_layer.name = "Projectiles"
	add_child(projectile_layer)
	players_layer = Node2D.new()
	players_layer.name = "Players"
	add_child(players_layer)
	if not config.headless:
		feedback_layer = Node2D.new()
		feedback_layer.name = "CombatFeedback"
		add_child(feedback_layer)
		hud_layer = CanvasLayer.new()
		hud_layer.name = "HUDLayer"
		hud_layer.layer = 20
		add_child(hud_layer)
		hud = HUD_SCENE.instantiate()
		hud_layer.add_child(hud)
		debug_layer = CanvasLayer.new()
		debug_layer.name = "DebugLayer"
		debug_layer.layer = 30
		add_child(debug_layer)
		debug_overlay = DEBUG_OVERLAY_SCENE.instantiate() as DebugOverlay
		debug_layer.add_child(debug_overlay)
		debug_overlay.configure(self)
		_create_debug_toggle_button()

func _create_debug_toggle_button() -> void:
	if debug_layer == null or debug_overlay == null:
		return
	debug_toggle_button = Button.new()
	debug_toggle_button.name = "DebugToggle"
	debug_toggle_button.text = "DEBUG"
	debug_toggle_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	debug_toggle_button.offset_left = -444.0
	debug_toggle_button.offset_top = 16.0
	debug_toggle_button.offset_right = -364.0
	debug_toggle_button.offset_bottom = 50.0
	debug_toggle_button.mouse_filter = Control.MOUSE_FILTER_STOP
	debug_toggle_button.pressed.connect(debug_overlay.toggle_visibility)
	debug_layer.add_child(debug_toggle_button)

func _debug_score_summary() -> String:
	if config != null and config.team_mode:
		var team_scores := score_manager.get_team_scores()
		return "T1 %d · T2 %d" % [int(team_scores.get(0, 0)), int(team_scores.get(1, 0))]
	var standings := score_manager.get_sorted_standings()
	if standings.is_empty():
		return "Lead 0"
	return "Lead %d" % [int(standings[0].get("score", 0))]

func _create_roster() -> void:
	players.clear()
	projectiles.clear()
	var colors: Array[Color] = [
		Color("#6EA8FE"),
		Color("#63D7C4"),
		Color("#A78BFA"),
		Color("#E6A85C"),
	]
	var player_id := 0
	for human_index in range(config.human_player_count):
		var controller := HumanController.new(human_index + 1)
		_add_player(player_id, true, controller, "Human %d" % [human_index + 1], colors[player_id % colors.size()])
		player_id += 1
	for agent_index in range(config.agent_count):
		var difficulty := ConfigDB.get_difficulty(config.agent_difficulty)
		var seed := config.random_seed + 101 + agent_index * 17
		var controller_kind := _agent_controller_for_player(player_id)
		var model_id := _agent_model_id_for_player(player_id)
		var controller: PlayerController
		if controller_kind == MatchConfig.AGENT_CONTROLLER_MODEL:
			controller = ModelAgentControllerScript.new(difficulty, seed, config.agent_model_host, config.agent_model_port, config.agent_model_timeout_ms, model_id)
			(controller as ModelAgentController).set_strength_profile(config.agent_difficulty)
		elif controller_kind == MatchConfig.AGENT_CONTROLLER_HYBRID:
			controller = HybridAgentControllerScript.new(difficulty, seed, config.agent_model_host, config.agent_model_port, config.agent_model_timeout_ms, model_id)
			(controller as HybridAgentController).config = HybridAgentConfigScript.for_profile(config.reward_profile_id)
		else:
			controller = ScriptedAgentController.new(difficulty, seed)
		_add_player(player_id, false, controller, "Agent %d" % [agent_index + 1], colors[player_id % colors.size()])
		player_id += 1

func _agent_controller_for_player(player_id: int) -> String:
	if config.agent_controller_overrides.has(player_id):
		return str(config.agent_controller_overrides[player_id])
	var key := str(player_id)
	if config.agent_controller_overrides.has(key):
		return str(config.agent_controller_overrides[key])
	return config.agent_controller

func _agent_model_id_for_player(player_id: int) -> String:
	if config.agent_model_id_overrides.has(player_id):
		return str(config.agent_model_id_overrides[player_id])
	var key := str(player_id)
	if config.agent_model_id_overrides.has(key):
		return str(config.agent_model_id_overrides[key])
	return config.agent_model_id

func _add_player(player_id: int, human: bool, controller: PlayerController, label: String, color: Color) -> void:
	var player := PLAYER_SCENE.instantiate() as ArenaPlayer
	var team := TeamRules.team_for_player(config, player_id, human)
	players_layer.add_child(player)
	player.configure(player_id, team, label, human, controller, color, balance)
	if player.has_method("set_visuals_enabled"):
		player.set_visuals_enabled(not config.headless)
	player.projectile_requested.connect(_on_projectile_requested)
	player.pickup_effect_expired.connect(_on_pickup_effect_expired)
	players.append(player)
	score_manager.register_player(player_id, team, label)
	reward_calculator.register_player(player_id)

func _spawn_initial_players() -> void:
	for player in players:
		var spawn := spawn_manager.choose_spawn(player, players, projectiles, arena_map.get_spawn_points(), arena_map, config)
		player.spawn_at(spawn, false)
	pickup_spawn_timer = rng.randf_range(1.2, 2.4)

func _update_players(delta: float, allow_actions: bool) -> void:
	for player in players:
		player.status_step(delta)
		if not player.is_alive and player.respawn_timer <= 0.0:
			_respawn_player(player)
	if arena_map != null:
		arena_map.rule_step(delta, players, projectiles, match_manager.elapsed_time, allow_actions)
	if not allow_actions:
		return
	for player in players:
		if not player.is_alive:
			continue
		var action := _get_player_action(player, delta)
		player.apply_action(action, delta, balance.map_size)

func _get_player_action(player: ArenaPlayer, delta: float) -> PlayerAction:
	var tactical_action := _get_tactical_player_action(player, delta)
	if tactical_action != null:
		return tactical_action
	var external_action := _get_external_player_action(player)
	if external_action != null:
		var external_obs := build_observation(player, false)
		replay_manager.record_decision(match_manager.elapsed_time, player, external_obs, external_action, score_manager.get_player_score(player.player_id), arena_map)
		return external_action
	if _uses_training_action_cache(player):
		return _get_cached_player_action(player, delta)
	var obs := build_observation(player, false)
	var action := PlayerAction.new()
	if player.controller != null:
		action = player.controller.get_action(obs, delta)
	if action == null:
		action = PlayerAction.new()
	action.normalize_vectors(player.aim_direction)
	replay_manager.record_decision(match_manager.elapsed_time, player, obs, action, score_manager.get_player_score(player.player_id), arena_map)
	return action

func _get_tactical_player_action(player: ArenaPlayer, delta: float) -> PlayerAction:
	if player == null or not tactical_decision_cache.has(player.player_id):
		return null
	if player.controller == null or player.controller.get_script() != HybridAgentControllerScript:
		return null
	var controller = player.controller
	var observation := build_observation(player, false)
	var decision = tactical_decision_cache[player.player_id].copy()
	var scripted_action: PlayerAction = controller.scripted.get_action(observation, delta) if controller.scripted != null else PlayerAction.new()
	var tactical_config := HybridAgentConfigScript.for_profile(config.reward_profile_id)
	var tactical_data: Dictionary = controller.feature_builder.build(observation, balance, tactical_config, controller.current_decision, arena_map)
	tactical_data["engagement_profile_id"] = config.reward_profile_id
	var masks: Dictionary = tactical_data.get("action_masks", {})
	decision.apply_masks(masks)
	tactical_decision_cache[player.player_id] = decision.copy()
	controller.current_decision = decision.copy()
	controller.current_action = controller.executor.execute(
		observation,
		controller.current_decision,
		scripted_action,
		controller._scripted_target(observation),
		player,
		delta,
		tactical_data
	)
	controller.current_action.normalize_vectors(observation.aim_direction)
	controller._update_no_target_fire_guard(observation, controller.current_action, controller.current_decision, delta)
	controller._collect_diagnostics(controller.current_decision, tactical_data)
	_record_tactical_execution(player.player_id, controller.current_decision.to_dict(), controller.get_diagnostics())
	replay_manager.record_decision(match_manager.elapsed_time, player, observation, controller.current_action, score_manager.get_player_score(player.player_id), arena_map)
	return controller.current_action.copy()

func _record_tactical_execution(player_id: int, decision: Dictionary, diagnostics: Dictionary) -> void:
	var generation := int(tactical_decision_generations.get(player_id, 0))
	if generation <= 0 or int(tactical_rewarded_generations.get(player_id, 0)) == generation:
		return
	tactical_rewarded_generations[player_id] = generation
	var facts := {
		"target_valid": bool(diagnostics.get("target_valid", false)),
		"fire_allowed": bool(diagnostics.get("fire_allowed", false)),
		"fire_block_reason": str(diagnostics.get("fire_block_reason", "")),
		"script_fallback": bool(diagnostics.get("script_fallback", false)),
	}
	tactical_decision_facts[player_id] = facts
	reward_calculator.on_tactical_execution(player_id, decision, diagnostics, generation)

func _get_cached_player_action(player: ArenaPlayer, delta: float) -> PlayerAction:
	var player_id := player.player_id
	var timer := float(controller_decision_timers.get(player_id, 0.0)) - delta
	var cached_action := controller_action_cache.get(player_id) as PlayerAction
	if timer <= 0.0 or cached_action == null:
		var obs := build_observation(player, false)
		var action := PlayerAction.new()
		if player.controller != null:
			action = player.controller.get_action(obs, _controller_decision_interval())
		if action == null:
			action = PlayerAction.new()
		action.normalize_vectors(player.aim_direction)
		controller_action_cache[player_id] = action.copy()
		controller_observation_cache[player_id] = obs
		controller_decision_timers[player_id] = _controller_decision_interval()
		replay_manager.record_decision(match_manager.elapsed_time, player, obs, action, score_manager.get_player_score(player_id), arena_map)
		return action
	controller_decision_timers[player_id] = timer
	return cached_action.copy()

func _uses_training_action_cache(player: ArenaPlayer) -> bool:
	return config != null and config.training_fast_mode and not player.is_human

func _controller_decision_interval() -> float:
	return 1.0 / maxf(float(balance.agent_decision_hz), 1.0)

func _clear_controller_caches() -> void:
	controller_action_cache.clear()
	controller_observation_cache.clear()
	controller_decision_timers.clear()
	external_action_cache.clear()
	tactical_decision_cache.clear()

func _get_external_player_action(player: ArenaPlayer) -> PlayerAction:
	if player == null or not external_action_cache.has(player.player_id):
		return null
	var action := external_action_cache[player.player_id] as PlayerAction
	if action == null:
		return null
	action.normalize_vectors(player.aim_direction)
	return action.copy()

func _parse_external_player_id(key: Variant) -> int:
	if key is int:
		return int(key)
	var text := str(key)
	return int(text) if text.is_valid_int() else -1

func _fallback_aim_for_player_id(player_id: int) -> Vector2:
	for player in players:
		if player.player_id == player_id:
			return player.aim_direction
	return Vector2.RIGHT

func _player_for_id(player_id: int):
	for player in players:
		if player.player_id == player_id:
			return player
	return null

func _action_from_external(data: Variant, fallback_aim: Vector2) -> PlayerAction:
	if data is PlayerAction:
		var direct := data as PlayerAction
		direct.normalize_vectors(fallback_aim)
		return direct.copy()
	if data is Dictionary:
		return PlayerAction.from_dict(data, fallback_aim)
	if data is PackedFloat32Array:
		return PlayerAction.from_flat_array(data, fallback_aim)
	if data is Array:
		var packed := PackedFloat32Array()
		for value in data:
			packed.append(float(value))
		return PlayerAction.from_flat_array(packed, fallback_aim)
	return null

func _update_projectiles(delta: float) -> void:
	var to_remove: Array[ArenaProjectile] = []
	for projectile in projectiles:
		projectile.physics_step(delta)
		if projectile.is_expired() or arena_map.is_point_blocked(projectile.global_position):
			to_remove.append(projectile)
			AudioManager.play_event("impact", projectile.global_position)
			continue
		if arena_map.has_method("handle_projectile_hit") and arena_map.handle_projectile_hit(projectile):
			to_remove.append(projectile)
			AudioManager.play_event("hit", projectile.global_position)
			continue
		for target in players:
			if not target.is_alive:
				continue
			if not TeamRules.can_damage(config, projectile.owner_team_id, target.team_id, projectile.owner_id, target.player_id):
				continue
			var hit_distance := balance.projectile_radius + balance.player_radius
			if projectile.global_position.distance_squared_to(target.global_position) <= hit_distance * hit_distance:
				var result := target.take_damage(projectile.damage, projectile.owner_id)
				if float(result.get("dealt", 0.0)) > 0.0:
					var authorized := reward_calculator.on_damage(projectile.owner_id, target.player_id, float(result["dealt"]), projectile.projectile_id)
					if authorized:
						var haste_source: int = projectile.owner.get_pickup_haste_source_id()
						var overcharge_source: int = projectile.owner.get_pickup_overcharge_source_id()
						reward_calculator.on_pickup_authorized_damage(projectile.owner_id, PICKUP_TYPE_HASTE, haste_source, float(result["dealt"]))
						reward_calculator.on_pickup_authorized_damage(projectile.owner_id, PICKUP_TYPE_OVERCHARGE, overcharge_source, float(result["dealt"]))
						if haste_source >= 0:
							projectile.owner.mark_pickup_haste_realized()
						if overcharge_source >= 0:
							projectile.owner.mark_pickup_overcharge_realized()
				if float(result.get("absorbed", 0.0)) > 0.0:
					reward_calculator.on_pickup_shield_absorption(target.player_id, int(result.get("pickup_shield_source_id", -1)), float(result["absorbed"]))
					target.mark_pickup_shield_realized()
				if bool(result.get("killed", false)):
					_handle_kill(target, projectile.owner_id)
				to_remove.append(projectile)
				AudioManager.play_event("hit", projectile.global_position)
				break
	for projectile in to_remove:
		_remove_projectile(projectile)

func _update_pickups(delta: float) -> void:
	if pickup_layer == null:
		return
	pickup_spawn_timer = maxf(0.0, pickup_spawn_timer - delta)
	if pickup_spawn_timer <= 0.0:
		if pickups.size() < balance.pickup_max_active:
			_spawn_pickup()
		pickup_spawn_timer = rng.randf_range(balance.pickup_spawn_interval_min, balance.pickup_spawn_interval_max)
	var to_remove: Array = []
	for pickup in pickups:
		pickup.physics_step(delta)
		if pickup.is_expired():
			to_remove.append(pickup)
			continue
		_apply_magnet_pull(pickup, delta)
		for player in players:
			if not player.is_alive:
				continue
			var collect_distance := balance.pickup_collect_radius + balance.player_radius
			if pickup.global_position.distance_squared_to(player.global_position) <= collect_distance * collect_distance:
				_apply_pickup(player, pickup)
				to_remove.append(pickup)
				break
	for pickup in to_remove:
		_remove_pickup(pickup)

func _spawn_pickup() -> void:
	var position := _choose_pickup_position()
	if position == Vector2.INF:
		return
	var pickup = PICKUP_SCENE.instantiate()
	pickup_layer.add_child(pickup)
	if pickup.has_method("set_visuals_enabled"):
		pickup.set_visuals_enabled(not config.headless)
	pickup_counter += 1
	pickup.configure(_choose_pickup_type(), position, balance.pickup_lifetime, balance.pickup_collect_radius, pickup_counter)
	pickups.append(pickup)

func _choose_pickup_type() -> String:
	var roll := rng.randf()
	if roll < 0.30:
		return PICKUP_TYPE_HEALTH
	if roll < 0.48:
		return PICKUP_TYPE_SHIELD
	if roll < 0.66:
		return PICKUP_TYPE_HASTE
	if roll < 0.80:
		return PICKUP_TYPE_PULSE
	if roll < 0.92:
		return PICKUP_TYPE_OVERCHARGE
	return PICKUP_TYPE_MAGNET

func _choose_pickup_position() -> Vector2:
	if arena_map == null:
		return Vector2.INF
	var margin := maxf(72.0, balance.pickup_spawn_radius + balance.player_radius)
	if config != null and config.training_spawn_policy == TRAINING_RESOURCE_CONTEST:
		var contest_position := _choose_resource_contest_pickup_position(margin)
		if not contest_position.is_equal_approx(Vector2.INF):
			return contest_position
	for _attempt in range(72):
		var point := Vector2(
			rng.randf_range(margin, balance.map_size.x - margin),
			rng.randf_range(margin, balance.map_size.y - margin)
		)
		if not arena_map.is_spawn_area_clear(point, balance.pickup_spawn_radius):
			continue
		if _pickup_position_is_crowded(point):
			continue
		return point
	return Vector2.INF

func _choose_resource_contest_pickup_position(margin: float) -> Vector2:
	var closest_a = null
	var closest_b = null
	var closest_distance_sq := INF
	for player in players:
		if player == null or not player.is_alive:
			continue
		for other in players:
			if other == null or not other.is_alive or other.player_id <= player.player_id:
				continue
			if TeamRules.are_teammates(config, player.team_id, other.team_id, player.player_id, other.player_id):
				continue
			var distance_sq := player.global_position.distance_squared_to(other.global_position)
			if distance_sq < closest_distance_sq:
				closest_distance_sq = distance_sq
				closest_a = player
				closest_b = other
	if closest_a == null or closest_b == null:
		return Vector2.INF
	var midpoint: Vector2 = (closest_a.global_position + closest_b.global_position) * 0.5
	var axis: Vector2 = (closest_b.global_position - closest_a.global_position).normalized()
	if axis.length_squared() <= 0.001:
		axis = Vector2.RIGHT
	var offsets: Array[Vector2] = [Vector2.ZERO, axis.orthogonal() * 44.0, -axis.orthogonal() * 44.0]
	for offset in offsets:
		var point := midpoint + offset
		point.x = clampf(point.x, margin, balance.map_size.x - margin)
		point.y = clampf(point.y, margin, balance.map_size.y - margin)
		if not arena_map.is_spawn_area_clear(point, balance.pickup_spawn_radius):
			continue
		if _pickup_position_is_crowded(point):
			continue
		return point
	return Vector2.INF

func _pickup_position_is_crowded(point: Vector2) -> bool:
	for pickup in pickups:
		if pickup.global_position.distance_squared_to(point) < 110.0 * 110.0:
			return true
	for player in players:
		if player.is_alive and player.global_position.distance_squared_to(point) < 130.0 * 130.0:
			return true
	return false

func _apply_pickup(player: ArenaPlayer, pickup) -> void:
	var pickup_id := int(pickup.get("pickup_id"))
	var pickup_type := str(pickup.pickup_type)
	var restored_health := 0.0
	if pickup_type == PICKUP_TYPE_HEALTH:
		restored_health = player.restore_health(balance.max_health * balance.pickup_health_restore_ratio)
	var nearest_enemy_distance := _nearest_pickup_enemy_distance(player, pickup.global_position)
	var contested := nearest_enemy_distance >= 0.0 and nearest_enemy_distance <= reward_calculator.get_resource_contest_radius()
	reward_calculator.on_pickup_collected(pickup_id, player.player_id, pickup_type, contested, restored_health, nearest_enemy_distance)
	match pickup.pickup_type:
		PICKUP_TYPE_SHIELD:
			player.apply_pickup_shield(balance.pickup_shield_duration, balance.pickup_shield_absorb, pickup_id)
			AudioManager.play_event("shield", pickup.global_position)
		PICKUP_TYPE_HASTE:
			player.apply_haste(balance.pickup_haste_duration, balance.pickup_haste_speed_multiplier, balance.pickup_haste_fire_rate_multiplier, pickup_id)
			AudioManager.play_event("pickup", pickup.global_position)
		PICKUP_TYPE_PULSE:
			player.apply_pulse_flash()
			_queue_pulse_pickup(player, pickup.global_position)
			AudioManager.play_event("pulse", pickup.global_position)
		PICKUP_TYPE_OVERCHARGE:
			player.apply_overcharge(balance.pickup_overcharge_duration, balance.pickup_overcharge_damage_multiplier, balance.pickup_overcharge_projectile_speed_multiplier, pickup_id)
			AudioManager.play_event("pickup", pickup.global_position)
		PICKUP_TYPE_MAGNET:
			player.apply_magnet(balance.pickup_magnet_duration)
			AudioManager.play_event("pickup", pickup.global_position)
		_:
			AudioManager.play_event("pickup", pickup.global_position)

func _pickup_is_contested(collector: ArenaPlayer, position: Vector2) -> bool:
	var nearest_enemy_distance := _nearest_pickup_enemy_distance(collector, position)
	return nearest_enemy_distance >= 0.0 and nearest_enemy_distance <= reward_calculator.get_resource_contest_radius()

func _nearest_pickup_enemy_distance(collector: ArenaPlayer, position: Vector2) -> float:
	var nearest_distance := INF
	for other in players:
		if other == null or not other.is_alive or other.player_id == collector.player_id:
			continue
		if TeamRules.are_teammates(config, collector.team_id, other.team_id, collector.player_id, other.player_id):
			continue
		nearest_distance = minf(nearest_distance, other.global_position.distance_to(position))
	return nearest_distance if is_finite(nearest_distance) else -1.0

func _queue_pulse_pickup(source: ArenaPlayer, center: Vector2) -> void:
	# 脉冲固定在拾取点连续释放，后续波次不跟随拾取者移动。
	var pulse_count := maxi(1, balance.pickup_pulse_count)
	for i in range(pulse_count):
		pending_pulses.append({
			"timer": balance.pickup_pulse_interval * float(i),
			"center": center,
			"source_id": source.player_id,
			"source_aim": source.aim_direction,
		})

func _update_pending_pulses(delta: float) -> void:
	var remaining: Array[Dictionary] = []
	for pulse in pending_pulses:
		pulse["timer"] = float(pulse.get("timer", 0.0)) - delta
		if float(pulse["timer"]) <= 0.0:
			_apply_pulse_pickup(
				int(pulse.get("source_id", -1)),
				pulse.get("source_aim", Vector2.RIGHT) as Vector2,
				pulse.get("center", Vector2.ZERO) as Vector2
			)
		else:
			remaining.append(pulse)
	pending_pulses = remaining

func _apply_pulse_pickup(source_id: int, source_aim: Vector2, center: Vector2) -> void:
	# 每次脉冲都会独立清弹、伤害其他玩家，并把地图生物伤害交给地图规则。
	_spawn_feedback_ring(center, Color("#A78BFA"), balance.pickup_pulse_radius, 0.34)
	_clear_projectiles_in_radius(center, balance.pickup_pulse_radius)
	if arena_map != null and arena_map.has_method("apply_pulse_hit"):
		arena_map.apply_pulse_hit(center, balance.pickup_pulse_radius, balance.pickup_pulse_damage, source_id)
	for target in players:
		if target == null or not target.is_alive or target.player_id == source_id:
			continue
		var offset := target.global_position - center
		if offset.length_squared() > balance.pickup_pulse_radius * balance.pickup_pulse_radius:
			continue
		var dir := offset.normalized() if offset.length_squared() > 0.001 else source_aim
		target.displace_by_pickup(dir * balance.pickup_pulse_knockback, balance.map_size, arena_map)
		var result := target.take_damage(balance.pickup_pulse_damage, source_id)
		if source_id >= 0 and float(result.get("dealt", 0.0)) > 0.0:
			reward_calculator.on_damage(source_id, target.player_id, float(result["dealt"]))
		if bool(result.get("killed", false)):
			_handle_kill(target, source_id)

func _clear_projectiles_in_radius(center: Vector2, radius: float) -> void:
	var to_remove: Array[ArenaProjectile] = []
	var radius_squared := radius * radius
	for projectile in projectiles:
		if projectile.global_position.distance_squared_to(center) <= radius_squared:
			to_remove.append(projectile)
	for projectile in to_remove:
		_spawn_feedback_ring(projectile.global_position, Color("#EBDFFF"), 34.0, 0.18)
		AudioManager.play_event("impact", projectile.global_position)
		_remove_projectile(projectile)

func _apply_magnet_pull(pickup, delta: float) -> void:
	var magnet_player = _nearest_magnet_player(pickup.global_position)
	if magnet_player == null:
		return
	var offset: Vector2 = magnet_player.global_position - pickup.global_position
	var distance := offset.length()
	if distance <= 1.0:
		return
	var step := minf(distance, balance.pickup_magnet_pull_speed * delta)
	pickup.global_position += offset / distance * step

func _nearest_magnet_player(position: Vector2):
	var best_player = null
	var best_distance_sq := balance.pickup_magnet_radius * balance.pickup_magnet_radius
	for player in players:
		if player == null or not player.is_alive or not player.has_pickup_magnet():
			continue
		var distance_sq := player.global_position.distance_squared_to(position)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_player = player
	return best_player

func _spawn_feedback_ring(position: Vector2, color: Color, radius: float, lifetime: float) -> void:
	if feedback_layer == null:
		return
	var effect := SimpleEffectScript.new() as SimpleEffect
	effect.global_position = position
	effect.effect_color = color
	effect.effect_kind = "ring"
	effect.lifetime = lifetime
	effect.scale = Vector2.ONE * maxf(1.0, radius / 48.0)
	feedback_layer.add_child(effect)

func _remove_pickup(pickup) -> void:
	if not pickups.has(pickup):
		return
	pickups.erase(pickup)
	pickup.queue_free()

func _on_projectile_requested(player: ArenaPlayer, origin: Vector2, direction: Vector2) -> void:
	var projectile := PROJECTILE_SCENE.instantiate() as ArenaProjectile
	projectile_counter += 1
	projectile_layer.add_child(projectile)
	if projectile.has_method("set_visuals_enabled"):
		projectile.set_visuals_enabled(not config.headless)
	projectile.configure(projectile_counter, player, origin, direction, balance)
	if player.controller != null and player.controller.get_script() == HybridAgentControllerScript and player.controller.has_method("get_diagnostics"):
		var generation := int(tactical_decision_generations.get(player.player_id, 0))
		var facts: Dictionary = tactical_decision_facts.get(player.player_id, {})
		reward_calculator.register_authorized_projectile(projectile_counter, player.player_id, generation, facts)
	projectiles.append(projectile)

func _remove_projectile(projectile: ArenaProjectile) -> void:
	if not projectiles.has(projectile):
		return
	reward_calculator.discard_projectile(projectile.projectile_id)
	projectiles.erase(projectile)
	projectile.queue_free()

func _handle_kill(victim: ArenaPlayer, killer_id: int) -> void:
	score_manager.record_kill(killer_id, victim.player_id)
	reward_calculator.on_kill(killer_id, victim.player_id)
	GameEvents.emit_player_killed({"victim_id": victim.player_id, "killer_id": killer_id, "position": victim.global_position})

func kill_player_by_environment(player: ArenaPlayer, hazard: String = "environment") -> void:
	if player == null or not player.is_alive:
		return
	var result := player.kill_by_environment()
	if bool(result.get("killed", false)):
		score_manager.record_kill(-1, player.player_id)
		reward_calculator.on_environment_death(player.player_id, hazard)
		reward_calculator.on_kill(-1, player.player_id)

func apply_environment_damage(player: ArenaPlayer, amount: float, hazard: String = "environment") -> void:
	if player == null or not player.is_alive:
		return
	var result := player.take_damage(amount, -1)
	var dealt := float(result.get("dealt", 0.0))
	if float(result.get("absorbed", 0.0)) > 0.0:
		reward_calculator.on_pickup_shield_absorption(player.player_id, int(result.get("pickup_shield_source_id", -1)), float(result["absorbed"]))
		player.mark_pickup_shield_realized()
	if dealt > 0.0:
		reward_calculator.on_environment_damage(player.player_id, dealt, hazard)
	if bool(result.get("killed", false)):
		score_manager.record_kill(-1, player.player_id)
		reward_calculator.on_environment_death(player.player_id, hazard)
		reward_calculator.on_kill(-1, player.player_id)
		GameEvents.emit_player_killed({"victim_id": player.player_id, "killer_id": -1, "position": player.global_position})

func kill_player_by_void(player: ArenaPlayer) -> void:
	if player == null or not player.is_alive:
		return
	var result := player.kill_by_void()
	if bool(result.get("killed", false)):
		score_manager.record_kill(-1, player.player_id)
		reward_calculator.on_environment_death(player.player_id, "sky_void")
		reward_calculator.on_kill(-1, player.player_id)

func record_map_event(player: ArenaPlayer, event_source: String, amount: int = 1) -> void:
	if player == null:
		return
	reward_calculator.on_map_event(player.player_id, event_source, amount)

func _on_pickup_effect_expired(player: ArenaPlayer, pickup_type: String, source_id: int, realized: bool) -> void:
	if player == null:
		return
	reward_calculator.on_pickup_effect_expired(player.player_id, pickup_type, source_id, realized)

func _respawn_player(player: ArenaPlayer) -> void:
	var spawn := spawn_manager.choose_spawn(player, players, projectiles, arena_map.get_spawn_points(), arena_map, config)
	player.spawn_at(spawn, true)
	AudioManager.play_event("respawn", spawn)

func _finish_match() -> void:
	if finished:
		return
	finished = true
	var result := score_manager.build_result(config)
	match_result = result.duplicate(true)
	reward_calculator.on_match_finished(result)
	replay_manager.stop()
	GameFlowManager.finish_match(result)
	if hud != null and hud.has_method("show_result"):
		hud.show_result(result)
	if config.headless:
		print(JSON.stringify({"headless_result": result, "rewards": get_rewards()}))
		if not _is_managed_by_environment_bridge():
			get_tree().quit(0)

func _is_managed_by_environment_bridge() -> bool:
	var parent := get_parent()
	return parent != null and parent is EnvironmentBridge

func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
	pending_pulses.clear()
	_clear_controller_caches()
	arena_map = null
	pickup_layer = null
	players_layer = null
	projectile_layer = null
	feedback_layer = null
	camera = null
	hud_layer = null
	hud = null
	debug_layer = null
	debug_overlay = null
	debug_toggle_button = null

func _configure_camera_for_map() -> void:
	if camera == null:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = Vector2(1600, 900)
	var fit_zoom := minf(viewport_size.x / balance.map_size.x, viewport_size.y / balance.map_size.y)
	camera.zoom = Vector2(fit_zoom, fit_zoom)
	camera.position = balance.map_size * 0.5
	camera.position_smoothing_enabled = false
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(balance.map_size.x)
	camera.limit_bottom = int(balance.map_size.y)

func _is_local_human_id(player_id: int) -> bool:
	for player in players:
		if player.player_id == player_id:
			return player.is_human
	return false
