extends RefCounted
# 世界空间血条绘制器，为玩家和生物提供紧凑的生命值反馈。
class_name WorldHealthBar

func draw(canvas: CanvasItem, player, alpha: float, scale_value: float = 1.0) -> void:
	var ratio := player.get_health_ratio()
	var width := 48.0 * clampf(scale_value, 0.75, 1.35)
	var height := 4.5 * clampf(scale_value, 0.85, 1.4)
	var y := -48.0
	var bg := Rect2(Vector2(-width * 0.5, y), Vector2(width, height))
	var fill := Rect2(bg.position, Vector2(width * ratio, height))
	var intensity := 0.38 if ratio > 0.98 else 0.68
	var hp_color := Color("#63D7C4") if ratio > 0.55 else Color("#E6A85C") if ratio > 0.28 else Color("#F07178")
	canvas.draw_rect(bg.grow(1.0), Color("#050812", intensity * alpha))
	canvas.draw_rect(bg, Color("#243047", 0.82 * alpha))
	canvas.draw_rect(fill, Color(hp_color.r, hp_color.g, hp_color.b, lerpf(0.45, 0.95, 1.0 - ratio) * alpha))
	canvas.draw_rect(bg, Color("#F1F5FA", 0.18 * alpha), false, 1.0)
