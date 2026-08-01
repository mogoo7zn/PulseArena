extends SceneTree
# Verifies the browser debug overlay remains opt-in and renders only supplied public runtime data.

const DEBUG_OVERLAY_SCENE := preload("res://scenes/debug/DebugOverlay.tscn")

func _init() -> void:
	var overlay := DEBUG_OVERLAY_SCENE.instantiate() as DebugOverlay
	root.add_child(overlay)
	call_deferred("_run", overlay)

func _run(overlay: DebugOverlay) -> void:
	overlay.update_runtime({
		"map_id": "dungeon",
		"state": "PLAYING",
		"remaining_seconds": 12.0,
		"player_count": 4,
		"projectile_count": 3,
		"fps": 60.0,
		"frame_ms": 16.7,
		"score_summary": "T1 3 · T2 1",
	})
	if overlay.visible:
		push_error("Debug overlay must start hidden")
		quit(1)
		return
	overlay.toggle_visibility()
	var display_text: String = overlay.get_display_text()
	if not overlay.visible or not display_text.contains("FPS") or not display_text.contains("Dungeon") or not display_text.contains("Score T1 3 · T2 1"):
		push_error("Debug overlay did not render its public runtime snapshot")
		quit(1)
		return
	quit(0)
