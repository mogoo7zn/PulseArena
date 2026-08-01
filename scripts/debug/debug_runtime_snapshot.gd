class_name DebugRuntimeSnapshot

static func build(map_id: String, state: String, remaining_seconds: float, player_count: int, projectile_count: int, fps: float, frame_ms: float) -> Dictionary:
	return {"map_id": map_id, "state": state, "remaining_seconds": remaining_seconds, "player_count": player_count, "projectile_count": projectile_count, "fps": fps, "frame_ms": frame_ms}
