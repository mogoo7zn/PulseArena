extends Control
# 简单页面基类，为轻量菜单页提供标题、返回和内容容器。
class_name SimplePage

@export var title: String = "Pulse Arena"
# Optional BGM scene key (see scripts/audio/audio_manager.gd BGM_TRACKS).
# Empty string means "don't touch the music" — useful for sub-menus like
# Settings/About that should not interrupt the track playing beneath them.
@export var bgm_key: String = ""

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := PulseBackground.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var label: Label = Label.new()
	label.text = title
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.45
	label.anchor_bottom = 0.55
	label.horizontal_alignment = HORIZONTAL_ALIGN_CENTER
	label.add_theme_color_override("font_color", UiTokens.TEXT)
	label.add_theme_font_size_override("font_size", 30)
	add_child(label)
	if not bgm_key.is_empty():
		var am := get_node_or_null("/root/AudioManager")
		if am != null:
			am.play_bgm(bgm_key)
