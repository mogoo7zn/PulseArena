extends "res://scripts/arena/map_rules/map_rule_base.gd"
# 迷雾地图规则，维护视野遮蔽、虫洞传送和暗色科幻特效。
class_name MistWorldRule

const FOG_SPAWN_INTERVAL_MIN := 1.8
const FOG_SPAWN_INTERVAL_MAX := 3.4
const FOG_DURATION_MIN := 6.0
const FOG_DURATION_MAX := 11.5
const FOG_RADIUS_MIN := 168.0
const FOG_RADIUS_MAX := 272.0
const MAX_ACTIVE_FOGS := 4
const FOG_LOBE_MIN := 8
const FOG_LOBE_MAX := 13
const FOG_PLAYER_MIN_VISIBILITY := 0.0
const PORTAL_SPAWN_INTERVAL_MIN := 5.5
const PORTAL_SPAWN_INTERVAL_MAX := 9.0
const PORTAL_DURATION_MIN := 10.0
const PORTAL_DURATION_MAX := 15.0
const PORTAL_OPEN_DURATION := 0.75
const PORTAL_CLOSE_DURATION := 0.75
const PORTAL_RADIUS := 52.0
const PORTAL_TELEPORT_COOLDOWN := 1.0

var spawn_timer: float = 1.0
var fogs: Array[Dictionary] = []
var portal_spawn_timer: float = 4.5
var portal_pair: Dictionary = {}
var portal_cooldowns: Dictionary = {}
var fog_exposure_players: Dictionary = {}

func configure(map_node: Node, size: Vector2, seed_value: int) -> void:
	super.configure(map_node, size, seed_value)
	spawn_timer = rng.randf_range(0.5, 1.4)
	portal_spawn_timer = rng.randf_range(2.2, 4.0)
	portal_pair.clear()
	portal_cooldowns.clear()
	fog_exposure_players.clear()

func rule_step(delta: float, players: Array, projectiles: Array, match_time: float, playing: bool) -> void:
	if not playing:
		for player in players:
			if player != null:
				_apply_player_visual_visibility(player)
				if player.has_method("set_mist_visibility"):
					player.set_mist_visibility(1.0)
		return
	_update_fogs(delta, players)
	_update_portals(delta, players)
	spawn_timer -= delta
	if spawn_timer <= 0.0:
		spawn_timer = rng.randf_range(FOG_SPAWN_INTERVAL_MIN, FOG_SPAWN_INTERVAL_MAX)
		if fogs.size() < MAX_ACTIVE_FOGS:
			_spawn_fog()
	if visuals_enabled:
		queue_redraw()

func _update_fogs(delta: float, players: Array) -> void:
	var remaining: Array[Dictionary] = []
	for fog in fogs:
		fog["age"] = float(fog.get("age", 0.0)) + delta
		if float(fog["age"]) < float(fog["duration"]):
			remaining.append(fog)
	fogs = remaining
	for player in players:
		if player == null:
			continue
		_apply_player_visual_visibility(player)
		if player.has_method("set_mist_visibility"):
			var visibility := _mist_visibility_at_point(player.global_position)
			player.set_mist_visibility(visibility)
			var exposed := visibility < 0.999
			if exposed and not bool(fog_exposure_players.get(player.player_id, false)):
				var root = arena_map.get_parent() if arena_map != null else null
				if root != null and root.has_method("record_map_event"):
					root.record_map_event(player, "mist_fog")
			fog_exposure_players[player.player_id] = exposed

func _apply_player_visual_visibility(player) -> void:
	if player != null and player.has_method("set_visuals_enabled"):
		player.visible = bool(player.get("visuals_enabled"))
	else:
		player.visible = true

func _spawn_fog() -> void:
	var radius := rng.randf_range(FOG_RADIUS_MIN, FOG_RADIUS_MAX)
	var center := random_clear_point(radius * 0.28, 96.0, 90)
	fogs.append({
		"position": center,
		"radius": radius,
		"duration": rng.randf_range(FOG_DURATION_MIN, FOG_DURATION_MAX),
		"age": 0.0,
		"phase": rng.randf_range(0.0, TAU),
		"lobes": _make_lobes(radius)
	})

func _update_portals(delta: float, players: Array) -> void:
	for key in portal_cooldowns.keys():
		portal_cooldowns[key] = maxf(0.0, float(portal_cooldowns[key]) - delta)
		if float(portal_cooldowns[key]) <= 0.0:
			portal_cooldowns.erase(key)
	if portal_pair.is_empty():
		portal_spawn_timer -= delta
		if portal_spawn_timer <= 0.0:
			portal_spawn_timer = rng.randf_range(PORTAL_SPAWN_INTERVAL_MIN, PORTAL_SPAWN_INTERVAL_MAX)
			_spawn_portal_pair()
		return
	portal_pair["age"] = float(portal_pair.get("age", 0.0)) + delta
	var age := float(portal_pair["age"])
	var duration := float(portal_pair["duration"])
	if age >= PORTAL_OPEN_DURATION and age <= duration:
		_apply_portals(players)
	if age >= duration + PORTAL_CLOSE_DURATION:
		portal_pair.clear()
		portal_cooldowns.clear()

func _spawn_portal_pair() -> void:
	var first := random_clear_point(PORTAL_RADIUS + 28.0, 104.0, 90)
	var second := random_clear_point(PORTAL_RADIUS + 28.0, 104.0, 90)
	for _attempt in range(30):
		if first.distance_squared_to(second) >= 460.0 * 460.0:
			break
		second = random_clear_point(PORTAL_RADIUS + 28.0, 104.0, 90)
	portal_pair = {
		"a": first,
		"b": second,
		"duration": rng.randf_range(PORTAL_DURATION_MIN, PORTAL_DURATION_MAX),
		"age": 0.0,
		"phase": rng.randf_range(0.0, TAU),
	}

func _apply_portals(players: Array) -> void:
	var a := portal_pair["a"] as Vector2
	var b := portal_pair["b"] as Vector2
	for player in players:
		if player == null or not player.is_alive:
			continue
		if float(portal_cooldowns.get(player.player_id, 0.0)) > 0.0:
			continue
		if player.global_position.distance_squared_to(a) <= PORTAL_RADIUS * PORTAL_RADIUS:
			_teleport_player(player, b, a)
		elif player.global_position.distance_squared_to(b) <= PORTAL_RADIUS * PORTAL_RADIUS:
			_teleport_player(player, a, b)

func _teleport_player(player, destination: Vector2, source: Vector2) -> void:
	var exit_dir := (destination - source).normalized()
	if exit_dir.length_squared() <= 0.001:
		exit_dir = Vector2.RIGHT
	player.global_position = destination + exit_dir * 18.0
	player.velocity = Vector2.ZERO
	portal_cooldowns[player.player_id] = PORTAL_TELEPORT_COOLDOWN
	var root = arena_map.get_parent() if arena_map != null else null
	if root != null and root.has_method("record_map_event"):
		root.record_map_event(player, "mist_portal")

func _make_lobes(radius: float) -> Array[Dictionary]:
	var lobes: Array[Dictionary] = [{
		"offset": Vector2.ZERO,
		"radius": radius * rng.randf_range(0.58, 0.82)
	}]
	var count := rng.randi_range(FOG_LOBE_MIN, FOG_LOBE_MAX)
	for i in range(count):
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.62, 0.62)
		var distance := rng.randf_range(radius * 0.16, radius * 0.72)
		lobes.append({
			"offset": Vector2.RIGHT.rotated(angle) * distance,
			"radius": radius * rng.randf_range(0.32, 0.62)
		})
	return lobes

func _mist_visibility_at_point(point: Vector2) -> float:
	var density := _fog_density_at_point(point)
	if density <= 0.0:
		return 1.0
	return clampf(lerpf(1.0, FOG_PLAYER_MIN_VISIBILITY, density), FOG_PLAYER_MIN_VISIBILITY, 1.0)

func _fog_density_at_point(point: Vector2) -> float:
	var density := 0.0
	for fog in fogs:
		var fog_alpha := _fog_alpha(fog)
		if fog_alpha <= 0.0:
			continue
		var center := fog["position"] as Vector2
		var lobes := fog["lobes"] as Array
		for lobe in lobes:
			var offset := lobe["offset"] as Vector2
			var radius := float(lobe["radius"])
			var distance_ratio := point.distance_to(center + offset) / maxf(radius, 1.0)
			if distance_ratio <= 1.0:
				var local_density := 1.0 - smoothstep(0.72, 1.0, distance_ratio)
				density = maxf(density, fog_alpha * local_density)
	return clampf(density, 0.0, 1.0)

func _fog_alpha(fog: Dictionary) -> float:
	var age := float(fog["age"])
	var fade_in := clampf(age / 0.8, 0.0, 1.0)
	var fade_out := clampf(1.0 - age / float(fog["duration"]), 0.0, 1.0)
	return minf(fade_in, fade_out)

func _draw() -> void:
	if not visuals_enabled:
		return
	for fog in fogs:
		_draw_fog(fog)
	if not portal_pair.is_empty():
		_draw_portal_pair()

func _draw_fog(fog: Dictionary) -> void:
	var center := fog["position"] as Vector2
	var radius := float(fog["radius"])
	var age := float(fog["age"])
	var phase := float(fog["phase"])
	var alpha := _fog_alpha(fog)
	var lobes := fog["lobes"] as Array
	var boundary := _shape_boundary_points(center, lobes, 72, phase + age * 0.025)
	var inner := PackedVector2Array()
	var core := PackedVector2Array()
	for point in boundary:
		inner.append(center + (point - center) * 0.72)
		core.append(center + (point - center) * 0.43)
	draw_polygon(boundary, _solid_colors(boundary.size(), Color("#080C18", 0.38 * alpha)))
	draw_polygon(boundary, _solid_colors(boundary.size(), Color("#D7D9FF", 0.38 * alpha)))
	draw_polygon(inner, _solid_colors(inner.size(), Color("#7D74D8", 0.28 * alpha)))
	draw_polygon(core, _solid_colors(core.size(), Color("#FFFFFF", 0.16 * alpha)))
	for i in range(10):
		var a := phase + age * (0.18 + float(i % 3) * 0.05) + TAU * float(i) / 10.0
		var p := center + Vector2.RIGHT.rotated(a) * radius * _fog_hash_unit(i) * 0.58
		var length := lerpf(74.0, 126.0, _fog_hash_unit(i + 17))
		var wisp_alpha := (0.10 + _fog_hash_unit(i + 31) * 0.13) * alpha
		draw_line(p - Vector2(length, 0).rotated(a * 0.42), p + Vector2(length, 0).rotated(a * 0.42), Color("#FFFFFF", wisp_alpha), 10.0 + 6.0 * _fog_hash_unit(i + 9))
	for i in range(6):
		var ring_t := float(i) / 5.0
		var ring_radius := radius * lerpf(0.22, 0.82, ring_t)
		_draw_flat_ellipse_arc(center + Vector2(0, 3.0 * ring_t), Vector2(ring_radius, ring_radius * 0.46), phase + age * 0.12 + ring_t, phase + age * 0.12 + ring_t + PI * 1.45, Color("#77D9D8", (0.08 + ring_t * 0.06) * alpha), 1.2)
	_draw_closed_polyline(boundary, Color("#77D9D8", 0.21 * alpha), 2.0)
	_draw_closed_polyline(inner, Color("#FFFFFF", 0.10 * alpha), 1.2)

func _draw_portal_pair() -> void:
	var a := portal_pair["a"] as Vector2
	var b := portal_pair["b"] as Vector2
	var age := float(portal_pair["age"])
	var duration := float(portal_pair["duration"])
	var phase := float(portal_pair["phase"])
	var open_t := clampf(age / PORTAL_OPEN_DURATION, 0.0, 1.0)
	var close_t := clampf((duration + PORTAL_CLOSE_DURATION - age) / PORTAL_CLOSE_DURATION, 0.0, 1.0)
	var alpha := smoothstep(0.0, 1.0, minf(open_t, close_t))
	_draw_portal_link(a, b, age, alpha)
	_draw_portal(a, phase, age, alpha, Color("#00D6FF"), Color("#3523A6"))
	_draw_portal(b, phase + PI, age, alpha, Color("#8257FF"), Color("#003E66"))

func _draw_portal(center: Vector2, phase: float, age: float, alpha: float, color: Color, secondary: Color) -> void:
	var radius := PORTAL_RADIUS * lerpf(0.25, 1.0, alpha)
	_draw_flat_ellipse(center + Vector2(6, 12), Vector2(radius * 0.98, radius * 0.40), Color("#000000", 0.36 * alpha))
	for i in range(6):
		var t := float(i) / 5.0
		var ring_radius := radius * lerpf(1.26, 0.30, t)
		var ring_color := Color("#020614").lerp(secondary, 0.32 + t * 0.34).lerp(color, t * 0.28)
		_draw_flat_ellipse(center, Vector2(ring_radius, ring_radius * 0.58), Color(ring_color.r, ring_color.g, ring_color.b, lerpf(0.10, 0.42, t) * alpha))
	for tick in range(10):
		var tick_angle := phase + age * 0.85 + TAU * float(tick) / 10.0
		var inner := center + Vector2(cos(tick_angle) * radius * 0.84, sin(tick_angle) * radius * 0.48)
		var outer := center + Vector2(cos(tick_angle) * radius * 1.10, sin(tick_angle) * radius * 0.63)
		var tick_color := color.lerp(secondary, _portal_hash_unit(tick + 31))
		draw_line(inner, outer, Color(tick_color.r, tick_color.g, tick_color.b, 0.20 * alpha), 1.2)
	_draw_portal_arc(center, Vector2(radius * 1.10, radius * 0.64), phase + age * 2.2, phase + age * 2.2 + PI * 1.55, Color(color.r, color.g, color.b, 0.88 * alpha), 3.0)
	_draw_portal_arc(center, Vector2(radius * 0.78, radius * 0.44), phase - age * 2.9, phase - age * 2.9 + PI * 1.36, Color(secondary.r, secondary.g, secondary.b, 0.62 * alpha), 2.0)
	_draw_portal_arc(center, Vector2(radius * 1.34, radius * 0.74), phase - age * 1.4 + PI, phase - age * 1.4 + PI * 1.82, Color("#0D1634", 0.50 * alpha), 2.4)
	_draw_flat_ellipse(center, Vector2(radius * 0.42, radius * 0.22), Color("#02030B", 0.78 * alpha))
	_draw_flat_ellipse(center, Vector2(radius * 0.24, radius * 0.12), Color(color.r, color.g, color.b, 0.18 * alpha))
	for i in range(12):
		var a := phase + age * (1.1 + float(i % 3) * 0.22) + TAU * float(i) / 12.0
		var orbit := radius * (0.62 + 0.38 * _portal_hash_unit(i))
		var p := center + Vector2(cos(a) * orbit, sin(a) * orbit * 0.50)
		var dot_radius := lerpf(1.3, 3.4, _portal_hash_unit(i + 11))
		var dot_color := color.lerp(secondary, _portal_hash_unit(i + 17))
		draw_circle(p, dot_radius, Color(dot_color.r, dot_color.g, dot_color.b, (0.18 + 0.28 * _portal_hash_unit(i + 23)) * alpha))

func _draw_portal_link(a: Vector2, b: Vector2, age: float, alpha: float) -> void:
	var dir := b - a
	var normal := dir.orthogonal().normalized()
	draw_line(a, b, Color("#020614", 0.18 * alpha), 9.0)
	for strand in range(3):
		var points := PackedVector2Array()
		var strand_phase := age * (1.8 + strand * 0.35) + float(strand) * 1.7
		for i in range(24):
			var t := float(i) / 23.0
			var base := a.lerp(b, t)
			var wave := sin(t * TAU * 2.0 + strand_phase) * (10.0 + strand * 4.0)
			points.append(base + normal * wave)
		for i in range(points.size() - 1):
			var local_t := float(i) / float(maxi(points.size() - 2, 1))
			var pulse := 0.5 + 0.5 * sin(age * 5.0 + local_t * TAU)
			var color := Color("#00D6FF").lerp(Color("#6D4DFF"), float(strand) / 2.0)
			draw_line(points[i], points[i + 1], Color(color.r, color.g, color.b, (0.08 + pulse * 0.10) * alpha), 1.3 + strand * 0.55)

func _draw_portal_arc(center: Vector2, radii: Vector2, start_angle: float, end_angle: float, color: Color, width: float) -> void:
	var points := PackedVector2Array()
	var steps := 36
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var angle := lerpf(start_angle, end_angle, t)
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], color, width)

func _draw_flat_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(maxf(radii.x, 1.0), maxf(radii.y, 1.0)))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_flat_ellipse_arc(center: Vector2, radii: Vector2, start_angle: float, end_angle: float, color: Color, width: float) -> void:
	var points := PackedVector2Array()
	var steps := 42
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var a := lerpf(start_angle, end_angle, t)
		points.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], color, width)

func _fog_hash_unit(index: int) -> float:
	return 0.42 + fposmod(sin(float(index) * 18.233) * 27644.771, 1.0) * 0.58

func _portal_hash_unit(index: int) -> float:
	return fposmod(sin(float(index) * 29.371) * 38142.611, 1.0)
