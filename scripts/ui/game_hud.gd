extends Control
# 对战 HUD，显示计时、玩家状态、技能、比分和结束菜单。
class_name GameHUD

const PlayerStatusCardScene = preload("res://scenes/ui/PlayerStatusCard.tscn")

var time_label: Label
var mode_label: Label
var score_label: Label
var center_label: Label
var local_cards_box: HBoxContainer
var standings_box: VBoxContainer
var hint_label: Label
var agent_debug_label: Label
var local_cards: Dictionary = {}
var standings_rows: Dictionary = {}
var pause_overlay: PanelContainer
var result_overlay: Control
var result_panel: PanelContainer
var result_body: VBoxContainer
var quick_menu_button: Button
var current_config: MatchConfig
var current_players: Array[ArenaPlayer] = []
var current_score_manager: ScoreManager
var current_match_manager: MatchManager

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_sync_viewport_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_sync_viewport_layout()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if GameFlowManager.current_state == GameFlowManagerService.GameState.PLAYING:
			GameFlowManager.pause_match()
			get_viewport().set_input_as_handled()
		elif GameFlowManager.current_state == GameFlowManagerService.GameState.PAUSED:
			GameFlowManager.resume_match()
			get_viewport().set_input_as_handled()
	if event.is_action_pressed("return_menu") and GameFlowManager.is_match_active():
		_exit_to_menu()
		get_viewport().set_input_as_handled()

func configure(config: MatchConfig, players: Array[ArenaPlayer], score_manager: ScoreManager, match_manager: MatchManager) -> void:
	current_config = config
	current_players = players
	current_score_manager = score_manager
	current_match_manager = match_manager
	if result_overlay != null:
		result_overlay.visible = false
	if quick_menu_button != null:
		quick_menu_button.visible = true
	_rebuild_local_cards(players)
	_rebuild_standings(players)
	update_snapshot(players, score_manager, match_manager, null)

func update_snapshot(players: Array[ArenaPlayer], score_manager: ScoreManager, match_manager: MatchManager, reward_calculator: RewardCalculator) -> void:
	current_players = players
	current_score_manager = score_manager
	current_match_manager = match_manager
	if local_cards_box.get_child_count() != _local_player_count(players):
		_rebuild_local_cards(players)
	if standings_rows.size() != players.size():
		_rebuild_standings(players)
	time_label.text = _format_time(match_manager.remaining_time)
	mode_label.text = _mode_text()
	score_label.text = _score_text(score_manager)
	if match_manager.countdown > 0.0:
		center_label.text = str(match_manager.get_countdown_number())
		center_label.modulate = Color.WHITE
		center_label.add_theme_font_size_override("font_size", 64)
		time_label.add_theme_color_override("font_color", UiTokens.TEXT)
	elif GameFlowManager.current_state == GameFlowManagerService.GameState.PLAYING and match_manager.remaining_time <= 10.0:
		var remaining := maxi(0, ceili(match_manager.remaining_time))
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.018)
		center_label.text = str(remaining)
		center_label.modulate = Color(1.0, 0.82 + pulse * 0.18, 0.72, 0.78 + pulse * 0.22)
		center_label.add_theme_color_override("font_color", Color("#FF6B6B").lerp(Color("#F2D36B"), pulse * 0.35))
		center_label.add_theme_font_size_override("font_size", 86)
		time_label.add_theme_color_override("font_color", Color("#FF6B6B"))
	elif GameFlowManager.current_state == GameFlowManagerService.GameState.PAUSED:
		center_label.text = ""
		center_label.modulate = Color.WHITE
		center_label.add_theme_font_size_override("font_size", 64)
		time_label.add_theme_color_override("font_color", UiTokens.TEXT)
	else:
		center_label.text = ""
		center_label.modulate = Color.WHITE
		center_label.add_theme_font_size_override("font_size", 64)
		time_label.add_theme_color_override("font_color", UiTokens.TEXT)
	for player in players:
		var card = local_cards.get(player.player_id)
		if card != null:
			card.update_player(player, score_manager, true)
		var row: Label = standings_rows.get(player.player_id)
		if row != null:
			var public_view: Dictionary = _build_public_player_view(players[0] if not players.is_empty() else player, player, score_manager)
			row.text = "P%d  HP%02d  K%d  S%d" % [
				int(public_view["player_id"]) + 1,
				roundi(float(public_view["health_ratio"]) * 100.0),
				int(public_view["kills"]),
				int(public_view["score"]),
			]
			row.modulate = Color(1, 1, 1, 1.0 if bool(public_view["is_alive"]) else 0.45)
	_update_agent_debug(players)
	pause_overlay.visible = GameFlowManager.current_state == GameFlowManagerService.GameState.PAUSED
	queue_redraw()

func show_result(result: Dictionary) -> void:
	_build_result(result)
	result_overlay.visible = true
	if quick_menu_button != null:
		quick_menu_button.visible = false
	center_label.text = ""

func _build() -> void:
	var top_panel := PanelContainer.new()
	top_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_panel.anchor_left = 0.38
	top_panel.anchor_right = 0.62
	top_panel.offset_top = 10
	top_panel.offset_bottom = 48
	top_panel.add_theme_stylebox_override("panel", _compact_panel_style(Color("#10192C", 0.50), Color("#2D3C57", 0.62)))
	add_child(top_panel)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 10)
	top_panel.add_child(top)
	mode_label = Label.new()
	mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	mode_label.add_theme_font_size_override("font_size", 11)
	top.add_child(mode_label)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	time_label = Label.new()
	time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	time_label.add_theme_color_override("font_color", UiTokens.TEXT)
	time_label.add_theme_font_size_override("font_size", 19)
	top.add_child(time_label)
	score_label = Label.new()
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_label.add_theme_color_override("font_color", UiTokens.CYAN)
	score_label.add_theme_font_size_override("font_size", 11)
	top.add_child(score_label)
	_build_quick_menu_button()
	center_label = Label.new()
	center_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_label.anchor_left = 0.0
	center_label.anchor_right = 1.0
	center_label.anchor_top = 0.42
	center_label.anchor_bottom = 0.58
	center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center_label.add_theme_color_override("font_color", UiTokens.TEXT)
	center_label.add_theme_font_size_override("font_size", 64)
	add_child(center_label)
	standings_box = VBoxContainer.new()
	standings_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	standings_box.anchor_left = 1.0
	standings_box.anchor_right = 1.0
	standings_box.offset_left = -202
	standings_box.offset_right = -12
	standings_box.offset_top = 12
	standings_box.offset_bottom = 112
	standings_box.add_theme_constant_override("separation", 2)
	add_child(_wrap_panel(standings_box, Vector2(-214, 10), Vector2(-12, 116), "Score"))
	local_cards_box = HBoxContainer.new()
	local_cards_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	local_cards_box.anchor_left = 0.0
	local_cards_box.anchor_right = 0.0
	local_cards_box.anchor_top = 1.0
	local_cards_box.anchor_bottom = 1.0
	local_cards_box.offset_left = 12
	local_cards_box.offset_right = 420
	local_cards_box.offset_top = -78
	local_cards_box.offset_bottom = -10
	local_cards_box.add_theme_constant_override("separation", 8)
	add_child(local_cards_box)
	hint_label = Label.new()
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_label.anchor_left = 0.0
	hint_label.anchor_right = 1.0
	hint_label.anchor_top = 1.0
	hint_label.anchor_bottom = 1.0
	hint_label.offset_left = 590
	hint_label.offset_right = -360
	hint_label.offset_top = -42
	hint_label.offset_bottom = -14
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	hint_label.visible = false
	hint_label.text = "Esc pause   Backspace/Menu exit"
	add_child(hint_label)
	agent_debug_label = Label.new()
	agent_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	agent_debug_label.anchor_left = 0.0
	agent_debug_label.anchor_right = 0.0
	agent_debug_label.anchor_top = 0.0
	agent_debug_label.anchor_bottom = 0.0
	agent_debug_label.offset_left = 12
	agent_debug_label.offset_right = 540
	agent_debug_label.offset_top = 116
	agent_debug_label.offset_bottom = 250
	agent_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	agent_debug_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	agent_debug_label.add_theme_font_size_override("font_size", 11)
	agent_debug_label.visible = false
	add_child(agent_debug_label)
	_build_pause_overlay()
	_build_result_overlay()

func _build_quick_menu_button() -> void:
	quick_menu_button = Button.new()
	quick_menu_button.text = "Menu"
	quick_menu_button.anchor_left = 0.0
	quick_menu_button.anchor_right = 0.0
	quick_menu_button.offset_left = 10
	quick_menu_button.offset_right = 66
	quick_menu_button.offset_top = 10
	quick_menu_button.offset_bottom = 36
	quick_menu_button.modulate = Color(1, 1, 1, 0.62)
	quick_menu_button.add_theme_color_override("font_color", UiTokens.TEXT)
	quick_menu_button.add_theme_font_size_override("font_size", 11)
	quick_menu_button.add_theme_stylebox_override("normal", _compact_button_style(Color("#10192C", 0.42), Color("#2D3C57", 0.52)))
	quick_menu_button.add_theme_stylebox_override("hover", UiTokens.button_style(UiTokens.FLOATING, UiTokens.CYAN))
	quick_menu_button.add_theme_stylebox_override("pressed", UiTokens.button_style(Color("#243656"), UiTokens.CYAN))
	quick_menu_button.mouse_entered.connect(func() -> void: quick_menu_button.modulate = Color.WHITE)
	quick_menu_button.mouse_exited.connect(func() -> void: quick_menu_button.modulate = Color(1, 1, 1, 0.62))
	quick_menu_button.mouse_entered.connect(func() -> void: AudioManager.play_event("ui_hover"))
	quick_menu_button.pressed.connect(func() -> void:
		AudioManager.play_event("ui_click")
		_exit_to_menu()
	)
	add_child(quick_menu_button)

func _wrap_panel(content: Control, top_left: Vector2, bottom_right: Vector2, title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = top_left.x
	panel.offset_right = bottom_right.x
	panel.offset_top = top_left.y
	panel.offset_bottom = bottom_right.y
	panel.add_theme_stylebox_override("panel", _compact_panel_style(Color("#10192C", 0.38), Color("#2D3C57", 0.45)))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = title
	label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	label.add_theme_font_size_override("font_size", 10)
	box.add_child(label)
	content.anchor_left = 0.0
	content.anchor_right = 0.0
	content.anchor_top = 0.0
	content.anchor_bottom = 0.0
	content.offset_left = 0.0
	content.offset_right = 0.0
	content.offset_top = 0.0
	content.offset_bottom = 0.0
	box.add_child(content)
	return panel

func _rebuild_local_cards(players: Array[ArenaPlayer]) -> void:
	for child in local_cards_box.get_children():
		child.queue_free()
	local_cards.clear()
	for player in players:
		if not player.is_human:
			continue
		var card = PlayerStatusCardScene.instantiate()
		card.custom_minimum_size = Vector2(186, 62)
		local_cards_box.add_child(card)
		local_cards[player.player_id] = card

func _rebuild_standings(players: Array[ArenaPlayer]) -> void:
	for child in standings_box.get_children():
		child.queue_free()
	standings_rows.clear()
	for player in players:
		var row := Label.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_color_override("font_color", player.body_color.lightened(0.35))
		row.add_theme_font_size_override("font_size", 11)
		standings_box.add_child(row)
		standings_rows[player.player_id] = row

func _compact_panel_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := UiTokens.panel_style(color, border)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	style.shadow_size = 4
	style.shadow_offset = Vector2(0, 2)
	return style

func _compact_button_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := _compact_panel_style(color, border)
	style.set_corner_radius_all(5)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style

func _build_pause_overlay() -> void:
	pause_overlay = PanelContainer.new()
	pause_overlay.visible = false
	pause_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_overlay.anchor_left = 0.5
	pause_overlay.anchor_right = 0.5
	pause_overlay.anchor_top = 0.5
	pause_overlay.anchor_bottom = 0.5
	pause_overlay.offset_left = -160
	pause_overlay.offset_right = 160
	pause_overlay.offset_top = -118
	pause_overlay.offset_bottom = 118
	pause_overlay.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0B1020", 0.92), UiTokens.CYAN))
	add_child(pause_overlay)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pause_overlay.add_child(box)
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)
	box.add_child(_hud_button("Resume", func() -> void: GameFlowManager.resume_match()))
	box.add_child(_hud_button("Restart", func() -> void:
		if current_config != null:
			get_tree().paused = false
			GameFlowManager.start_match(current_config)
	))
	box.add_child(_hud_button("Main Menu", _exit_to_menu))

func _build_result_overlay() -> void:
	result_overlay = Control.new()
	result_overlay.name = "ResultOverlay"
	result_overlay.visible = false
	result_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_explicit_rect(result_overlay, get_viewport_rect().size)
	add_child(result_overlay)

	var scrim := ColorRect.new()
	scrim.color = Color("#020614", 0.58)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_overlay.add_child(scrim)

	result_panel = PanelContainer.new()
	result_panel.name = "ResultPanel"
	result_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	result_panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0B1020", 0.96), UiTokens.CYAN))
	result_overlay.add_child(result_panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	result_panel.add_child(scroll)
	result_body = VBoxContainer.new()
	result_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_body.add_theme_constant_override("separation", 7)
	scroll.add_child(result_body)
	_layout_result_overlay()

func _sync_viewport_layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = Vector2(1600, 900)
	_set_explicit_rect(self, viewport_size)
	custom_minimum_size = viewport_size
	_layout_result_overlay()
	queue_redraw()

func _set_explicit_rect(control: Control, rect_size: Vector2) -> void:
	control.anchor_left = 0.0
	control.anchor_right = 0.0
	control.anchor_top = 0.0
	control.anchor_bottom = 0.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = rect_size.x
	control.offset_bottom = rect_size.y

func _layout_result_overlay() -> void:
	if result_overlay == null:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = Vector2(1600, 900)
	var panel_width := clampf(viewport_size.x - 44.0, 320.0, 480.0)
	var panel_height := clampf(viewport_size.y - 44.0, 260.0, 420.0)
	_set_explicit_rect(result_overlay, viewport_size)
	if result_panel != null:
		result_panel.anchor_left = 0.5
		result_panel.anchor_right = 0.5
		result_panel.anchor_top = 0.5
		result_panel.anchor_bottom = 0.5
		result_panel.offset_left = -panel_width * 0.5
		result_panel.offset_right = panel_width * 0.5
		result_panel.offset_top = -panel_height * 0.5
		result_panel.offset_bottom = panel_height * 0.5
	if result_body != null:
		result_body.custom_minimum_size = Vector2(maxf(240.0, panel_width - 54.0), 0.0)

func _build_result(result: Dictionary) -> void:
	_layout_result_overlay()
	for child in result_body.get_children():
		child.queue_free()
	var winner := int(result.get("winner_player_id", -1))
	var title := Label.new()
	title.text = "Match Result"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 25)
	result_body.add_child(title)
	var winner_label := Label.new()
	winner_label.text = "Winner: Player %d" % [winner + 1] if winner >= 0 else "Draw"
	winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_label.add_theme_color_override("font_color", UiTokens.CYAN)
	winner_label.add_theme_font_size_override("font_size", 16)
	result_body.add_child(winner_label)
	for standing in result.get("standings", []):
		var row := Label.new()
		row.text = "%s  Team %d  K%d D%d  Score %d" % [
			str(standing.get("label", "Player")),
			int(standing.get("team_id", 0)) + 1,
			int(standing.get("kills", 0)),
			int(standing.get("deaths", 0)),
			int(standing.get("score", 0)),
		]
		row.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
		row.add_theme_font_size_override("font_size", 13)
		result_body.add_child(row)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	result_body.add_child(spacer)
	result_body.add_child(_hud_button("Run It Back", func() -> void:
		if current_config != null:
			if quick_menu_button != null:
				quick_menu_button.visible = true
			get_tree().paused = false
			GameFlowManager.start_match(current_config)
	))
	result_body.add_child(_hud_button("Main Menu", _exit_to_menu))

func _hud_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(210, 38)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_color_override("font_color", UiTokens.TEXT)
	button.add_theme_stylebox_override("normal", UiTokens.button_style(UiTokens.PANEL, UiTokens.BORDER))
	button.add_theme_stylebox_override("hover", UiTokens.button_style(UiTokens.FLOATING, UiTokens.CYAN))
	button.add_theme_stylebox_override("pressed", UiTokens.button_style(Color("#243656"), UiTokens.CYAN))
	button.pressed.connect(callback)
	button.mouse_entered.connect(func() -> void: AudioManager.play_event("ui_hover"))
	button.pressed.connect(func() -> void: AudioManager.play_event("ui_click"))
	return button

func _exit_to_menu() -> void:
	get_tree().paused = false
	GameFlowManager.enter_main_menu()

func _mode_text() -> String:
	if current_config == null:
		return "MATCH"
	return "TEAM 2V2" if current_config.team_mode else "FREE FOR ALL"

func _score_text(score_manager: ScoreManager) -> String:
	if current_config != null and current_config.team_mode:
		var teams := score_manager.get_team_scores()
		return "T1 %d  T2 %d" % [int(teams.get(0, 0)), int(teams.get(1, 0))]
	var top := score_manager.get_sorted_standings()
	if top.is_empty():
		return "S 0"
	return "LEAD %d" % [int(top[0].get("score", 0))]

func _local_player_count(players: Array[ArenaPlayer]) -> int:
	var count := 0
	for player in players:
		if player.is_human:
			count += 1
	return count

func _build_public_player_view(viewer: ArenaPlayer, subject: ArenaPlayer, score_manager: ScoreManager) -> Dictionary:
	return {
		"player_id": subject.player_id,
		"team_id": subject.team_id,
		"display_name": subject.display_name,
		"is_human": subject.is_human,
		"is_teammate": TeamRules.are_teammates(current_config, viewer.team_id, subject.team_id, viewer.player_id, subject.player_id) if viewer != null and current_config != null else false,
		"health_ratio": subject.get_health_ratio(),
		"is_alive": subject.is_alive,
		"is_shielding": subject.is_shielding(),
		"is_dashing": subject.is_dashing(),
		"has_respawn_protection": subject.has_respawn_protection(),
		"score": score_manager.get_player_score(subject.player_id),
		"kills": score_manager.get_player_kills(subject.player_id),
		"deaths": score_manager.get_player_deaths(subject.player_id),
	}

func _update_agent_debug(players: Array[ArenaPlayer]) -> void:
	if agent_debug_label == null:
		return
	if not bool(SettingsManager.get_value("debug", "show_agent_diagnostics", false)):
		agent_debug_label.visible = false
		if not agent_debug_label.text.is_empty():
			agent_debug_label.text = ""
		return
	var lines: PackedStringArray = PackedStringArray()
	for player in players:
		if player == null or player.controller == null or not player.controller.has_method("get_diagnostics"):
			continue
		var diag: Dictionary = player.controller.get_diagnostics()
		if diag.is_empty():
			continue
		lines.append("P%d %s T:%s M:%s F:%s S:%s conf %.2f fb:%s safe:%s" % [
			player.player_id + 1,
			player.controller.get_label(),
			str(diag.get("target", "-")),
			str(diag.get("movement_mode", "-")),
			str(diag.get("fire_mode", "-")),
			str(diag.get("skill_mode", "-")),
			float(diag.get("confidence", 0.0)),
			str(diag.get("script_fallback", false)),
			str(diag.get("safety_override", false)),
		])
		lines.append("aim %.2f hit %.2f reserve %.0f block:%s stuck %.2f threat %.2f latency %.1fms" % [
			float(diag.get("aim_error", 0.0)),
			float(diag.get("predicted_hit_probability", 0.0)),
			float(diag.get("reserved_energy", 0.0)),
			str(diag.get("fire_block_reason", "")),
			float(diag.get("stuck_score", 0.0)),
			float(diag.get("primary_projectile_threat", 0.0)),
			float(diag.get("inference_latency_ms", 0.0)),
		])
	if lines.is_empty():
		agent_debug_label.visible = false
		return
	agent_debug_label.visible = true
	agent_debug_label.text = "\n".join(lines)

func _draw() -> void:
	if result_overlay != null and result_overlay.visible:
		return
	var center := size * 0.5
	var high_contrast := bool(SettingsManager.get_value("accessibility", "high_contrast_crosshair", false))
	var color := Color("#F1F5FA", 0.88) if high_contrast else Color("#63D7C4", 0.72)
	var gap := 7.0
	var length := 16.0
	draw_line(center + Vector2(-length, 0), center + Vector2(-gap, 0), color, 1.6)
	draw_line(center + Vector2(gap, 0), center + Vector2(length, 0), color, 1.6)
	draw_line(center + Vector2(0, -length), center + Vector2(0, -gap), color, 1.6)
	draw_line(center + Vector2(0, gap), center + Vector2(0, length), color, 1.6)
	draw_circle(center, 1.8, color)

func _format_time(seconds: float) -> String:
	var total := maxi(0, ceili(seconds))
	return "%02d:%02d" % [int(total / 60), total % 60]
