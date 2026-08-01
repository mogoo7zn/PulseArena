extends SceneTree
# 地图构建 smoke 测试，验证各地图规则可以实例化并完成基础更新。

func _init() -> void:
	var balance := GameBalance.default()
	var map_ids: PackedStringArray = PackedStringArray([
		MatchConfig.MAP_ARENA_CROSS,
		MatchConfig.MAP_NEON_DOCKS,
		MatchConfig.MAP_REACTOR_RING,
		MatchConfig.MAP_SKYLINE_YARD,
	])
	var map_index := 0
	for map_id in map_ids:
		var arena := ArenaCross.new()
		arena.build_map(balance, map_id, 1000 + map_index)
		if arena.get_wall_rects().size() < 6:
			_fail("map %s has too few walls" % map_id)
			return
		if arena.get_spawn_points().size() < 4:
			_fail("map %s has too few spawn points" % map_id)
			return
		if _clear_spawn_sample_count(arena, balance, 3000 + map_index) < 18:
			_fail("map %s has too few random clear spawn candidates" % map_id)
			return
		var variant := ArenaCross.new()
		var first_layout := arena.get_wall_rects()
		variant.build_map(balance, map_id, 2000 + map_index)
		if first_layout == variant.get_wall_rects():
			_fail("map %s did not randomize wall layout across seeds" % map_id)
			return
		variant.free()
		arena.free()
		map_index += 1
	print("PASS: map build check")
	quit(0)

func _clear_spawn_sample_count(arena: ArenaCross, balance: GameBalance, seed_value: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var clear_count := 0
	for _i in range(96):
		var point := Vector2(
			rng.randf_range(70.0, balance.map_size.x - 70.0),
			rng.randf_range(70.0, balance.map_size.y - 70.0)
		)
		if arena.is_spawn_area_clear(point, 28.0):
			clear_count += 1
	return clear_count

func _fail(message: String) -> void:
	push_error("FAIL: " + message)
	quit(1)
