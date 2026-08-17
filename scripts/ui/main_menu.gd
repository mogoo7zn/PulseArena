extends Control
# 主菜单界面，负责模式选择、地图配置和进入比赛。
class_name MainMenu

const MODEL_CATALOG_PATH := "res://training/models/model_catalog.json"
const FALLBACK_MODEL_ID := "hybrid_tactical_v1"

var selected_key: String = "human_vs_1_agent"
var selected_map_id: String = MatchConfig.MAP_ARENA_CROSS
var difficulty: String = "normal"
var agent_type: String = MatchConfig.AGENT_CONTROLLER_HYBRID
var agent_model_id: String = ""
var agent_model_ids: PackedStringArray = PackedStringArray()
var agent_model_labels: PackedStringArray = PackedStringArray()
var agent_model_descriptions: Dictionary = {}
var map_buttons: Dictionary = {}
var mode_buttons: Dictionary = {}
var agent_type_option: OptionButton
var agent_model_option: OptionButton
var details_label: Label
var start_button: Button
var settings_panel: PanelContainer
var help_panel: PanelContainer
var selected_title_label: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_select_mode(selected_key)
	var am := get_node_or_null("/root/AudioManager")
	if am != null:
		am.play_bgm("menu")

func _build_ui() -> void:
	var bg := PulseBackground.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.anchor_left = 0.0
	root.anchor_right = 1.0
	root.anchor_top = 0.0
	root.anchor_bottom = 1.0
	root.offset_left = 28
	root.offset_right = -28
	root.offset_top = 18
	root.offset_bottom = -18
	root.add_theme_constant_override("separation", 14)
	add_child(root)
	root.add_child(_top_bar())
	_load_agent_model_catalog()
	var body := HBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	root.add_child(body)
	var cards_scroll := ScrollContainer.new()
	cards_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(cards_scroll)
	var cards := GridContainer.new()
	cards.columns = 2
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("h_separation", 14)
	cards.add_theme_constant_override("v_separation", 14)
	cards_scroll.add_child(cards)
	_add_map_card(cards, MatchConfig.MAP_ARENA_CROSS)
	_add_map_card(cards, MatchConfig.MAP_NEON_DOCKS)
	_add_map_card(cards, MatchConfig.MAP_REACTOR_RING)
	_add_map_card(cards, MatchConfig.MAP_SKYLINE_YARD)
	body.add_child(_side_panel())
	settings_panel = _build_settings_panel()
	settings_panel.visible = false
	add_child(settings_panel)
	help_panel = _build_help_panel()
	help_panel.visible = false
	add_child(help_panel)
	_select_map(selected_map_id)

func _top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size = Vector2(0, 58)
	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", 0)
	bar.add_child(brand)
	var title := Label.new()
	title.text = "Pulse Arena"
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 31)
	brand.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Top-down projectile combat lab"
	subtitle.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	subtitle.add_theme_font_size_override("font_size", 13)
	brand.add_child(subtitle)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var top_actions: PackedStringArray = PackedStringArray(["Settings", "Help", "Exit"])
	for action_label: String in top_actions:
		var button: Button = _styled_button(action_label)
		button.custom_minimum_size = Vector2(94, 38)
		if action_label == "Settings":
			button.pressed.connect(_toggle_settings)
		if action_label == "Help":
			button.pressed.connect(_toggle_help)
		if action_label == "Exit":
			button.pressed.connect(func() -> void: get_tree().quit())
		bar.add_child(button)
	return bar

func _add_map_card(parent: Control, key: String) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(292, 208)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0E1A26", 0.82), Color("#284A5C", 0.80)))
	card.gui_input.connect(func(event: InputEvent) -> void:
		var mouse_event := event as InputEventMouseButton
		if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_select_map(key)
	)
	card.mouse_entered.connect(func() -> void:
		if selected_map_id != key:
			card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#182238", 0.94), _map_color(key)))
		AudioManager.play_event("ui_hover")
	)
	card.mouse_exited.connect(func() -> void:
		if selected_map_id != key:
			card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0E1A26", 0.82), Color("#284A5C", 0.80)))
	)
	parent.add_child(card)
	map_buttons[key] = card

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	card.add_child(box)
	var preview := Control.new()
	preview.custom_minimum_size = Vector2(0, 68)
	preview.draw.connect(func() -> void:
		_draw_map_preview(preview, key)
	)
	box.add_child(preview)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	box.add_child(header)
	var swatch := ColorRect.new()
	swatch.color = _map_color(key)
	swatch.custom_minimum_size = Vector2(8, 46)
	header.add_child(swatch)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 0)
	header.add_child(title_box)
	var title_label := Label.new()
	title_label.text = _map_title(key)
	title_label.add_theme_color_override("font_color", UiTokens.TEXT)
	title_label.add_theme_font_size_override("font_size", 18)
	title_box.add_child(title_label)
	var comp_label := Label.new()
	comp_label.text = _map_tagline(key)
	comp_label.add_theme_color_override("font_color", _map_color(key).lightened(0.25))
	comp_label.add_theme_font_size_override("font_size", 12)
	title_box.add_child(comp_label)
	var desc := Label.new()
	desc.text = _map_description(key)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	desc.add_theme_font_size_override("font_size", 12)
	desc.custom_minimum_size = Vector2(0, 34)
	box.add_child(desc)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	box.add_child(chips)
	chips.add_child(_chip(_map_pacing(key)))
	chips.add_child(_chip("4 SPAWNS+"))
	chips.add_child(_chip("VERTICAL"))

func _add_mode_row(parent: Control, title: String, body: String, composition: String, key: String) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 56)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0E1A26", 0.82), Color("#284A5C", 0.78)))
	card.gui_input.connect(func(event: InputEvent) -> void:
		var mouse_event := event as InputEventMouseButton
		if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_select_mode(key)
	)
	card.mouse_entered.connect(func() -> void:
		if selected_key != key:
			card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#182238", 0.94), _mode_color(key)))
		AudioManager.play_event("ui_hover")
	)
	card.mouse_exited.connect(func() -> void:
		if selected_key != key:
			card.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#0E1A26", 0.82), Color("#284A5C", 0.78)))
	)
	parent.add_child(card)
	mode_buttons[key] = card
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	var swatch := ColorRect.new()
	swatch.color = _mode_color(key)
	swatch.custom_minimum_size = Vector2(7, 34)
	row.add_child(swatch)
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 0)
	row.add_child(text_box)
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_color_override("font_color", UiTokens.TEXT)
	title_label.add_theme_font_size_override("font_size", 14)
	text_box.add_child(title_label)
	var body_label := Label.new()
	body_label.text = "%s  |  %s" % [composition, body]
	body_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	body_label.add_theme_font_size_override("font_size", 12)
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_box.add_child(body_label)

func _side_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(330, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#081420", 0.90), Color("#5CAFC5", 0.72)))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Match Setup"
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 21)
	box.add_child(title)
	selected_title_label = Label.new()
	selected_title_label.add_theme_color_override("font_color", UiTokens.CYAN)
	selected_title_label.add_theme_font_size_override("font_size", 15)
	box.add_child(selected_title_label)
	var mode_title := Label.new()
	mode_title.text = "Mode"
	mode_title.add_theme_color_override("font_color", UiTokens.TEXT_WEAK)
	mode_title.add_theme_font_size_override("font_size", 12)
	box.add_child(mode_title)
	_add_mode_row(box, "Human vs 1 Agent", "Duel", "1H / 1AI", "human_vs_1_agent")
	_add_mode_row(box, "Human vs 2 Agents", "Pressure", "1H / 2AI", "human_vs_2_agents")
	_add_mode_row(box, "Human vs 3 Agents", "Chaos", "1H / 3AI", "human_vs_3_agents")
	_add_mode_row(box, "2 Humans vs 2 Agents", "Team", "2H / 2AI", "two_humans_vs_two_agents")
	agent_type_option = OptionButton.new()
	var agent_type_values: PackedStringArray = PackedStringArray([MatchConfig.AGENT_CONTROLLER_SCRIPTED, MatchConfig.AGENT_CONTROLLER_HYBRID])
	var agent_type_labels: PackedStringArray = PackedStringArray(["Scripted Agent", "Hybrid Tactical Agent"])
	for label: String in agent_type_labels:
		agent_type_option.add_item(label)
	agent_type_option.select(1)
	agent_type_option.item_selected.connect(func(index: int) -> void:
		agent_type = agent_type_values[index]
		_sync_agent_model_option()
		_update_details()
	)
	box.add_child(_labeled("Agent Type", agent_type_option))
	agent_model_option = OptionButton.new()
	for label: String in agent_model_labels:
		agent_model_option.add_item(label)
	var selected_model_index := agent_model_ids.find(agent_model_id)
	if selected_model_index < 0:
		selected_model_index = 0
	agent_model_option.select(selected_model_index)
	agent_model_option.item_selected.connect(func(index: int) -> void:
		if index >= 0 and index < agent_model_ids.size():
			agent_model_id = agent_model_ids[index]
			difficulty = _difficulty_from_model_id(agent_model_id)
			_update_details()
	)
	box.add_child(_labeled("Agent Model", agent_model_option))
	_sync_agent_model_option()
	details_label = Label.new()
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	details_label.add_theme_font_size_override("font_size", 13)
	details_label.custom_minimum_size = Vector2(280, 104)
	box.add_child(details_label)
	start_button = _styled_button("Start Match")
	start_button.custom_minimum_size = Vector2(250, 46)
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.add_theme_font_size_override("font_size", 16)
	start_button.add_theme_stylebox_override("normal", UiTokens.button_style(UiTokens.BLUE, UiTokens.CYAN))
	start_button.add_theme_stylebox_override("hover", UiTokens.button_style(UiTokens.CYAN, Color("#BFF7EF")))
	start_button.add_theme_stylebox_override("pressed", UiTokens.button_style(Color("#4F87DA"), UiTokens.CYAN))
	start_button.add_theme_color_override("font_color", UiTokens.BG_DARK)
	start_button.pressed.connect(_start_match)
	box.add_child(start_button)
	return panel

func _load_agent_model_catalog() -> void:
	agent_model_ids = PackedStringArray()
	agent_model_labels = PackedStringArray()
	agent_model_descriptions.clear()
	var default_model_id := ""
	if FileAccess.file_exists(MODEL_CATALOG_PATH):
		var text := FileAccess.get_file_as_string(MODEL_CATALOG_PATH)
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			var data := parsed as Dictionary
			default_model_id = str(data.get("default_model_id", "")).strip_edges()
			var models_value: Variant = data.get("models", [])
			if models_value is Array:
				for item in models_value:
					if not (item is Dictionary):
						continue
					var model_data := item as Dictionary
					var id := str(model_data.get("model_id", "")).strip_edges()
					if id.is_empty():
						continue
					var label := str(model_data.get("label", id)).strip_edges()
					if label.is_empty():
						label = id
					agent_model_ids.append(id)
					agent_model_labels.append(label)
					agent_model_descriptions[id] = str(model_data.get("description", model_data.get("notes", ""))).strip_edges()
	if agent_model_ids.is_empty():
		agent_model_ids.append(FALLBACK_MODEL_ID)
		agent_model_labels.append("Hybrid Tactical v1")
	if default_model_id.is_empty() or agent_model_ids.find(default_model_id) < 0:
		default_model_id = agent_model_ids[0]
	agent_model_id = default_model_id
	difficulty = _difficulty_from_model_id(agent_model_id)

func _sync_agent_model_option() -> void:
	if agent_model_option == null:
		return
	agent_model_option.disabled = agent_type == MatchConfig.AGENT_CONTROLLER_SCRIPTED

func _difficulty_from_model_id(model_id_value: String) -> String:
	# Extract the strength suffix (easy/casual/normal/strong/elite) from a
	# promoted-tier model id like "..._promoted_normal_20260816". Falls back
	# to "normal" for non-tier model ids.
	var known := ["easy", "casual", "normal", "strong", "elite"]
	for tier in known:
		if model_id_value.contains("_" + tier + "_"):
			return tier
	return "normal"

func _selected_agent_model_label() -> String:
	var index := agent_model_ids.find(agent_model_id)
	if index >= 0 and index < agent_model_labels.size():
		return agent_model_labels[index]
	return agent_model_id if not agent_model_id.is_empty() else "Default"

func _labeled(label: String, control: Control) -> Control:
	var box := VBoxContainer.new()
	var text := Label.new()
	text.text = label
	text.add_theme_color_override("font_color", UiTokens.TEXT_WEAK)
	box.add_child(text)
	box.add_child(control)
	return box

func _styled_button(label: String) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_stylebox_override("normal", UiTokens.button_style(Color("#102335", 0.94), Color("#3E6C7E")))
	button.add_theme_stylebox_override("hover", UiTokens.button_style(Color("#1D3C52", 0.98), UiTokens.CYAN))
	button.add_theme_stylebox_override("pressed", UiTokens.button_style(Color("#0C1827", 0.98), UiTokens.CYAN))
	button.add_theme_color_override("font_color", UiTokens.TEXT)
	button.mouse_entered.connect(func() -> void: AudioManager.play_event("ui_hover"))
	button.pressed.connect(func() -> void: AudioManager.play_event("ui_click"))
	return button

func _chip(text: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#182238", 0.78), UiTokens.BORDER))
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", UiTokens.TEXT)
	label.add_theme_font_size_override("font_size", 11)
	panel.add_child(label)
	return panel

func _metric(label: String, value: String) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 0)
	var top := Label.new()
	top.text = label
	top.add_theme_color_override("font_color", UiTokens.TEXT_WEAK)
	top.add_theme_font_size_override("font_size", 11)
	box.add_child(top)
	var bottom := Label.new()
	bottom.text = value
	bottom.add_theme_color_override("font_color", UiTokens.TEXT)
	bottom.add_theme_font_size_override("font_size", 18)
	box.add_child(bottom)
	return box

func _mode_color(key: String) -> Color:
	match key:
		"human_vs_1_agent":
			return UiTokens.CYAN
		"human_vs_2_agents":
			return UiTokens.BLUE
		"human_vs_3_agents":
			return UiTokens.PURPLE
		"two_humans_vs_two_agents":
			return UiTokens.ORANGE
	return UiTokens.CYAN

func _mode_humans(key: String) -> int:
	return 2 if key == "two_humans_vs_two_agents" else 1

func _mode_agents(key: String) -> int:
	match key:
		"human_vs_1_agent":
			return 1
		"human_vs_2_agents":
			return 2
		"human_vs_3_agents":
			return 3
		"two_humans_vs_two_agents":
			return 2
	return 1

func _mode_title(key: String) -> String:
	match key:
		"human_vs_1_agent":
			return "Human vs 1 Agent"
		"human_vs_2_agents":
			return "Human vs 2 Agents"
		"human_vs_3_agents":
			return "Human vs 3 Agents"
		"two_humans_vs_two_agents":
			return "2 Humans vs 2 Agents"
	return "Human vs Agent"

func _select_mode(key: String) -> void:
	selected_key = key
	for mode_key in mode_buttons.keys():
		var button := mode_buttons[mode_key] as PanelContainer
		if button == null:
			continue
		var border: Color = UiTokens.CYAN if mode_key == selected_key else Color("#284A5C", 0.78)
		var fill := Color("#173A46", 0.96) if mode_key == selected_key else Color("#0E1A26", 0.82)
		button.add_theme_stylebox_override("panel", UiTokens.panel_style(fill, border))
	_update_details()

func _select_map(key: String) -> void:
	selected_map_id = key
	for map_key in map_buttons.keys():
		var button := map_buttons[map_key] as PanelContainer
		if button == null:
			continue
		var border: Color = _map_color(map_key) if map_key == selected_map_id else Color("#284A5C", 0.80)
		var fill := Color("#173A46", 0.96) if map_key == selected_map_id else Color("#0E1A26", 0.82)
		button.add_theme_stylebox_override("panel", UiTokens.panel_style(fill, border))
	_update_details()

func _update_details() -> void:
	if details_label == null:
		return
	var agents := _mode_agents(selected_key)
	var humans := _mode_humans(selected_key)
	var mode_text := "Team 2v2, friendly fire off" if selected_key == "two_humans_vs_two_agents" else "Free-for-all"
	var agent_text := "Scripted Agent"
	if agent_type == MatchConfig.AGENT_CONTROLLER_HYBRID:
		agent_text = "Hybrid Tactical Agent: %s" % [_selected_agent_model_label()]
	if selected_title_label != null:
		selected_title_label.text = "%s / %s" % [_map_title(selected_map_id), _mode_title(selected_key)]
	details_label.text = "%s\n%s\n%d Human / %d Agent\nAgent: %s\nFallback difficulty: %s\n\n%s\n\nP1 WASD + mouse. P2 arrows + IJKL." % [_map_tagline(selected_map_id), mode_text, humans, agents, agent_text, difficulty.capitalize(), _map_description(selected_map_id)]

func _start_match() -> void:
	var config: MatchConfig
	match selected_key:
		"human_vs_1_agent":
			config = MatchConfig.preset_human_vs_agent(1)
		"human_vs_2_agents":
			config = MatchConfig.preset_human_vs_agent(2)
		"human_vs_3_agents":
			config = MatchConfig.preset_human_vs_agent(3)
		"two_humans_vs_two_agents":
			config = MatchConfig.preset_2_humans_vs_2_agents()
		_:
			config = MatchConfig.preset_human_vs_agent(1)
	config.agent_difficulty = difficulty
	config.agent_controller = agent_type
	config.agent_model_id = agent_model_id if agent_type != MatchConfig.AGENT_CONTROLLER_SCRIPTED else ""
	config.map_id = selected_map_id
	config.random_seed = int(Time.get_ticks_msec() % 2147483647)
	GameFlowManager.start_match(config)

func _map_title(key: String) -> String:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return "Sky City"
		MatchConfig.MAP_REACTOR_RING:
			return "Jungle Ruins"
		MatchConfig.MAP_SKYLINE_YARD:
			return "Mist World"
	return "Dungeon Keep"

func _map_tagline(key: String) -> String:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return "Floating marble and clouds"
		MatchConfig.MAP_REACTOR_RING:
			return "Overgrown ruins and roots"
		MatchConfig.MAP_SKYLINE_YARD:
			return "Soft fog and dark monoliths"
	return "Stone halls and torchlight"

func _map_description(key: String) -> String:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return "Bright floating platforms with marble barricades and open sightlines."
		MatchConfig.MAP_REACTOR_RING:
			return "Vine-covered ruins split the arena into rotation paths and ambush pockets."
		MatchConfig.MAP_SKYLINE_YARD:
			return "Fog bands and obelisks make distance reading softer and more mysterious."
	return "A dungeon layout with heavy stone cover, cracked tiles, and readable choke points."

func _map_pacing(key: String) -> String:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return "AERIAL"
		MatchConfig.MAP_REACTOR_RING:
			return "RUINS"
		MatchConfig.MAP_SKYLINE_YARD:
			return "FOG"
	return "DUNGEON"

func _map_color(key: String) -> Color:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return Color("#8DD7FF")
		MatchConfig.MAP_REACTOR_RING:
			return Color("#8DFF7A")
		MatchConfig.MAP_SKYLINE_YARD:
			return Color("#B7A7FF")
	return Color("#D7A765")

func _draw_map_preview(preview: Control, key: String) -> void:
	var rect := Rect2(Vector2.ZERO, preview.size).grow(-4.0)
	var c := _map_color(key)
	var floor := _map_preview_floor(key)
	var wall := _map_preview_wall(key)
	preview.draw_rect(rect, floor)
	preview.draw_rect(rect, Color(c.r, c.g, c.b, 0.28), false, 2.0)
	for i in range(1, 5):
		var x := rect.position.x + rect.size.x * float(i) / 5.0
		preview.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color("#F1F5FA", 0.08), 1.0)
	for i in range(1, 3):
		var y := rect.position.y + rect.size.y * float(i) / 3.0
		preview.draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), Color("#000000", 0.10), 1.0)
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			for i in range(3):
				preview.draw_circle(rect.position + rect.size * Vector2(0.18 + 0.26 * i, 0.22), 10.0, Color("#FFFFFF", 0.20))
		MatchConfig.MAP_REACTOR_RING:
			for i in range(5):
				preview.draw_circle(rect.position + rect.size * Vector2(0.16 + 0.17 * i, 0.72), 6.0, Color("#356A32", 0.32))
		MatchConfig.MAP_SKYLINE_YARD:
			preview.draw_line(rect.position + rect.size * Vector2(0.08, 0.22), rect.position + rect.size * Vector2(0.92, 0.40), Color("#D7D9FF", 0.12), 7.0)
		_:
			for i in range(1, 4):
				var x2 := rect.position.x + rect.size.x * float(i) / 4.0
				preview.draw_line(Vector2(x2, rect.position.y), Vector2(x2, rect.end.y), Color("#6E5A48", 0.18), 1.0)
	var blocks := _map_preview_blocks(key, rect)
	for block in blocks:
		_draw_preview_block(preview, block, wall, c)
	preview.draw_circle(rect.position + rect.size * Vector2(0.18, 0.22), 4.0, Color("#6EA8FE"))
	preview.draw_circle(rect.position + rect.size * Vector2(0.82, 0.78), 4.0, Color("#F07178"))

func _draw_preview_block(preview: Control, block: Rect2, wall: Color, accent: Color) -> void:
	var depth := clampf(minf(block.size.x, block.size.y) * 0.75, 5.0, 11.0)
	var side := Rect2(block.position + Vector2(0, block.size.y), Vector2(block.size.x, depth))
	var shadow := Rect2(block.position + Vector2(4, depth + 5), block.size)
	preview.draw_rect(shadow, Color("#000000", 0.22))
	preview.draw_rect(side, wall.darkened(0.28))
	preview.draw_rect(block, wall)
	preview.draw_rect(Rect2(block.position, Vector2(block.size.x, 3.0)), wall.lightened(0.30))
	preview.draw_rect(Rect2(block.position + Vector2(0, block.size.y - 3.0), Vector2(block.size.x, 3.0)), Color("#000000", 0.14))
	preview.draw_rect(block, Color(accent.r, accent.g, accent.b, 0.34), false, 1.5)

func _map_preview_floor(key: String) -> Color:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return Color("#BFE9FF", 0.82)
		MatchConfig.MAP_REACTOR_RING:
			return Color("#15331E", 0.94)
		MatchConfig.MAP_SKYLINE_YARD:
			return Color("#131728", 0.96)
	return Color("#1B1714", 0.96)

func _map_preview_wall(key: String) -> Color:
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			return Color("#E9F8FF")
		MatchConfig.MAP_REACTOR_RING:
			return Color("#466038")
		MatchConfig.MAP_SKYLINE_YARD:
			return Color("#30324D")
	return Color("#5B4A39")

func _map_preview_blocks(key: String, rect: Rect2) -> Array[Rect2]:
	var blocks: Array[Rect2] = []
	match key:
		MatchConfig.MAP_NEON_DOCKS:
			blocks.append_array([Rect2(rect.position + rect.size * Vector2(0.16, 0.18), rect.size * Vector2(0.28, 0.11)), Rect2(rect.position + rect.size * Vector2(0.56, 0.70), rect.size * Vector2(0.28, 0.11)), Rect2(rect.position + rect.size * Vector2(0.43, 0.36), rect.size * Vector2(0.10, 0.30)), Rect2(rect.position + rect.size * Vector2(0.62, 0.36), rect.size * Vector2(0.10, 0.30))])
		MatchConfig.MAP_REACTOR_RING:
			blocks.append_array([Rect2(rect.position + rect.size * Vector2(0.42, 0.40), rect.size * Vector2(0.16, 0.20)), Rect2(rect.position + rect.size * Vector2(0.29, 0.23), rect.size * Vector2(0.14, 0.10)), Rect2(rect.position + rect.size * Vector2(0.57, 0.67), rect.size * Vector2(0.14, 0.10)), Rect2(rect.position + rect.size * Vector2(0.18, 0.47), rect.size * Vector2(0.15, 0.10)), Rect2(rect.position + rect.size * Vector2(0.67, 0.47), rect.size * Vector2(0.15, 0.10))])
		MatchConfig.MAP_SKYLINE_YARD:
			blocks.append_array([Rect2(rect.position + rect.size * Vector2(0.16, 0.28), rect.size * Vector2(0.23, 0.10)), Rect2(rect.position + rect.size * Vector2(0.61, 0.62), rect.size * Vector2(0.23, 0.10)), Rect2(rect.position + rect.size * Vector2(0.40, 0.16), rect.size * Vector2(0.09, 0.28)), Rect2(rect.position + rect.size * Vector2(0.52, 0.56), rect.size * Vector2(0.09, 0.28))])
		_:
			blocks.append_array([Rect2(rect.position + rect.size * Vector2(0.46, 0.28), rect.size * Vector2(0.08, 0.44)), Rect2(rect.position + rect.size * Vector2(0.36, 0.45), rect.size * Vector2(0.28, 0.10)), Rect2(rect.position + rect.size * Vector2(0.14, 0.18), rect.size * Vector2(0.18, 0.10)), Rect2(rect.position + rect.size * Vector2(0.68, 0.72), rect.size * Vector2(0.18, 0.10))])
	return blocks

func _toggle_settings() -> void:
	settings_panel.visible = not settings_panel.visible
	help_panel.visible = false

func _toggle_help() -> void:
	help_panel.visible = not help_panel.visible
	settings_panel.visible = false

func _build_settings_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -390
	panel.offset_right = -34
	panel.offset_top = 78
	panel.offset_bottom = -22
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#10192C", 0.96), UiTokens.CYAN))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)
	box.add_child(_settings_slider("Screen Shake", "video", "screen_shake", 0.0, 1.0, 0.01))
	box.add_child(_settings_slider("Particle Quality", "video", "particle_quality", 0.0, 1.0, 0.05))
	box.add_child(_settings_toggle("Shadows", "video", "shadows"))
	box.add_child(_settings_toggle("Hit Flash", "video", "hit_flash"))
	box.add_child(_settings_toggle("Damage Numbers", "video", "damage_numbers"))
	box.add_child(_settings_slider("Master Volume", "audio", "master", 0.0, 1.0, 0.01))
	box.add_child(_settings_slider("SFX Volume", "audio", "sfx", 0.0, 1.0, 0.01))
	box.add_child(_settings_slider("Music Volume", "audio", "music", 0.0, 1.0, 0.01))
	box.add_child(_settings_toggle("Reduced Motion", "video", "reduced_motion"))
	box.add_child(_settings_toggle("High Contrast Crosshair", "accessibility", "high_contrast_crosshair"))
	box.add_child(_settings_slider("Health Bar Size", "accessibility", "health_bar_size", 0.8, 1.35, 0.01))
	return panel

func _build_help_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -420
	panel.offset_right = -34
	panel.offset_top = 78
	panel.offset_bottom = -22
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("#10192C", 0.96), UiTokens.BORDER))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Controls And Agent Interface"
	title.add_theme_color_override("font_color", UiTokens.TEXT)
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	label.add_theme_font_size_override("font_size", 14)
	label.text = "P1: WASD, mouse aim, left mouse shoot, Space dash, right mouse shield.\n\nP2: Arrow keys, IJKL aim, Right Ctrl shoot, Right Shift dash, Enter shield.\n\nAgent choices are Scripted Agent and Hybrid Tactical Agent. Hybrid uses learned tactical decisions with deterministic combat execution and Scripted Hard fallback."
	box.add_child(label)
	return panel

func _settings_slider(label: String, section: String, key: String, min_value: float, max_value: float, step: float) -> Control:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	box.add_child(row)
	var text := Label.new()
	text.text = label
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	row.add_child(text)
	var value_label := Label.new()
	value_label.add_theme_color_override("font_color", UiTokens.TEXT)
	row.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = float(SettingsManager.get_value(section, key, min_value))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(slider)
	var update_value := func(value: float) -> void:
		value_label.text = "%.0f%%" % [value * 100.0]
	update_value.call(slider.value)
	slider.value_changed.connect(func(value: float) -> void:
		update_value.call(value)
		SettingsManager.set_value(section, key, value, true)
	)
	return box

func _settings_toggle(label: String, section: String, key: String) -> Control:
	var toggle := CheckButton.new()
	toggle.text = label
	toggle.button_pressed = bool(SettingsManager.get_value(section, key, false))
	toggle.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	toggle.toggled.connect(func(pressed: bool) -> void:
		SettingsManager.set_value(section, key, pressed, true)
		AudioManager.play_event("ui_click")
	)
	return toggle
