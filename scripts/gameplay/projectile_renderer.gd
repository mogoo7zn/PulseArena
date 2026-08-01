extends RefCounted
# 子弹绘制器，封装弹体、尾迹和命中特效的画法。
class_name ProjectileRenderer

func draw_projectile(canvas: Node2D, projectile) -> void:
	var color := projectile.color
	for i in range(projectile.trail.size()):
		var p := canvas.to_local(projectile.trail[i])
		var a := float(i + 1) / float(maxi(projectile.trail.size(), 1))
		var w := projectile.radius * lerpf(0.28, 0.92, a)
		canvas.draw_circle(p, w, Color(color.r, color.g, color.b, 0.05 + 0.20 * a))
		if i > 0:
			var prev := canvas.to_local(projectile.trail[i - 1])
			canvas.draw_line(prev, p, Color(color.r, color.g, color.b, 0.16 * a), maxf(1.0, w * 0.85))
	canvas.draw_circle(Vector2.ZERO, projectile.radius + 2.5, Color(color.r, color.g, color.b, 0.22))
	canvas.draw_circle(Vector2.ZERO, projectile.radius, color)
	canvas.draw_circle(Vector2.ZERO, projectile.radius * 0.48, Color("#F1F5FA", 0.9))
	canvas.draw_arc(Vector2.ZERO, projectile.radius + 4.0, 0, TAU, 20, Color("#F1F5FA", 0.22), 1.0)
