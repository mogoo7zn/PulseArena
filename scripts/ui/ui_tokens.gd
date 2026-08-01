extends RefCounted
# UI 设计令牌，集中定义颜色、间距和常用控件样式。
class_name UiTokens

const BG_DARK := Color("#0B1020")
const BG_LAYER := Color("#11182B")
const PANEL := Color("#182238")
const FLOATING := Color("#202D47")
const TEXT := Color("#F1F5FA")
const TEXT_MUTED := Color("#AAB6C8")
const TEXT_WEAK := Color("#718096")
const BLUE := Color("#6EA8FE")
const CYAN := Color("#63D7C4")
const RED := Color("#F07178")
const ORANGE := Color("#E6A85C")
const PURPLE := Color("#A78BFA")
const BORDER := Color("#2D3C57")

static func panel_style(color: Color = PANEL, border: Color = BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.shadow_color = Color("#000000", 0.26)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 5)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

static func button_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := panel_style(color, border)
	style.set_corner_radius_all(6)
	style.border_color = border.lightened(0.10)
	style.shadow_color = Color("#000000", 0.34)
	style.shadow_size = 7
	style.shadow_offset = Vector2(0, 4)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style
