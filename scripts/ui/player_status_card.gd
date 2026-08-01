extends PanelContainer
# 玩家状态卡片，展示生命、分数、连击和当前增益信息。
class_name PlayerStatusCard

var name_label: Label
var tag_label: Label
var score_label: Label
var health_bar: ProgressBar
var energy_bar: ProgressBar
var cooldown_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", _compact_panel_style())
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(top)
	name_label = Label.new()
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_color_override("font_color", UiTokens.TEXT)
	name_label.add_theme_font_size_override("font_size", 12)
	top.add_child(name_label)
	tag_label = Label.new()
	tag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_label.add_theme_color_override("font_color", UiTokens.PURPLE)
	tag_label.add_theme_font_size_override("font_size", 10)
	top.add_child(tag_label)
	score_label = Label.new()
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_label.add_theme_color_override("font_color", UiTokens.TEXT_MUTED)
	score_label.add_theme_font_size_override("font_size", 10)
	box.add_child(score_label)
	health_bar = _make_bar(UiTokens.RED)
	box.add_child(health_bar)
	energy_bar = _make_bar(UiTokens.CYAN)
	box.add_child(energy_bar)
	cooldown_label = Label.new()
	cooldown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cooldown_label.add_theme_color_override("font_color", UiTokens.TEXT_WEAK)
	cooldown_label.add_theme_font_size_override("font_size", 9)
	box.add_child(cooldown_label)

func update_player(player: ArenaPlayer, score_manager: ScoreManager, reveal_private: bool = false) -> void:
	name_label.text = player.display_name
	tag_label.text = "  AI" if not player.is_human else "  HUMAN"
	tag_label.add_theme_color_override("font_color", UiTokens.PURPLE if not player.is_human else UiTokens.CYAN)
	score_label.text = "K %d  D %d  S %d" % [
		score_manager.get_player_kills(player.player_id),
		score_manager.get_player_deaths(player.player_id),
		score_manager.get_player_score(player.player_id),
	]
	health_bar.value = player.get_health_ratio() * 100.0
	energy_bar.visible = reveal_private
	if reveal_private:
		energy_bar.value = player.get_energy_ratio() * 100.0
	if player.is_alive and reveal_private:
		var dash_text := "OK" if player.get_dash_cooldown_ratio() <= 0.01 else "%02d" % roundi(player.get_dash_cooldown_ratio() * 100.0)
		var shield_text := "OK" if player.get_shield_cooldown_ratio() <= 0.01 else "%02d" % roundi(player.get_shield_cooldown_ratio() * 100.0)
		cooldown_label.text = "EN %.0f  D %s  SH %s" % [player.get_energy_ratio() * 100.0, dash_text, shield_text]
	elif player.is_alive:
		cooldown_label.text = "HP %.0f%%" % [player.get_health_ratio() * 100.0]
	else:
		cooldown_label.text = "Respawn %.1fs" % player.respawn_timer
	modulate = Color(1, 1, 1, 0.74 if player.is_alive else 0.42)

func _make_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.min_value = 0
	bar.max_value = 100
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(140, 5)
	var bg := _compact_panel_style(Color("#202D47", 0.48), Color("#2D3C57", 0.38))
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color(color.r, color.g, color.b, 0.86)
	fg.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)
	return bar

func _compact_panel_style(color: Color = Color("#10192C", 0.42), border: Color = Color("#2D3C57", 0.45)) -> StyleBoxFlat:
	var style := UiTokens.panel_style(color, border)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.shadow_size = 4
	style.shadow_offset = Vector2(0, 2)
	return style
