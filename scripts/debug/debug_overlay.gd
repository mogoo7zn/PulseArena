extends Control
# Development-only overlay for public, in-match diagnostics.
class_name DebugOverlay

const EVENT_LINE_LIMIT := 6

var _arena: Node
var _event_log := DebugEventLog.new()
var _runtime_label: Label
var _events_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_controls()
	_connect_public_sources()
	visible = false

func configure(arena: Node) -> void:
	_arena = arena

func update_runtime(snapshot: Dictionary) -> void:
	if _runtime_label == null:
		return
	_runtime_label.text = "FPS %.1f · %.1f ms\n%s · %s\nTime %05.1f · Players %d · Projectiles %d\nScore %s" % [
		float(snapshot.get("fps", 0.0)),
		float(snapshot.get("frame_ms", 0.0)),
		str(snapshot.get("state", "UNKNOWN")),
		str(snapshot.get("map_id", "unknown")).capitalize(),
		float(snapshot.get("remaining_seconds", 0.0)),
		int(snapshot.get("player_count", 0)),
		int(snapshot.get("projectile_count", 0)),
		str(snapshot.get("score_summary", "0")),
	]

func toggle_visibility() -> void:
	visible = not visible

func get_display_text() -> String:
	var runtime_text := _runtime_label.text if _runtime_label != null else ""
	var events_text := _events_label.text if _events_label != null else ""
	return runtime_text + "\n" + events_text

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_overlay") and not event.is_echo():
		toggle_visibility()
		get_viewport().set_input_as_handled()

func _build_controls() -> void:
	var panel := PanelContainer.new()
	panel.name = "DebugPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -356.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	panel.offset_bottom = 240.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)

	var title := Label.new()
	title.text = "DEVELOPMENT DIAGNOSTICS"
	content.add_child(title)

	_runtime_label = Label.new()
	_runtime_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_runtime_label)

	_events_label = Label.new()
	_events_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_events_label.text = "Events\nNo public events yet"
	content.add_child(_events_label)

	var toggle_button := Button.new()
	toggle_button.text = "DEBUG"
	toggle_button.pressed.connect(toggle_visibility)
	content.add_child(toggle_button)

func _connect_public_sources() -> void:
	var game_events := get_node_or_null("/root/GameEvents") as GameEventsService
	if game_events != null:
		game_events.player_spawned.connect(_on_game_event.bind("player_spawned"))
		game_events.player_respawned.connect(_on_game_event.bind("player_respawned"))
		game_events.player_damaged.connect(_on_game_event.bind("player_damaged"))
		game_events.player_killed.connect(_on_game_event.bind("player_killed"))
		game_events.projectile_fired.connect(_on_game_event.bind("projectile_fired"))
		game_events.time_changed.connect(_on_time_changed)
		game_events.match_paused.connect(_on_match_paused)
		game_events.match_resumed.connect(_on_match_resumed)
		game_events.match_finished.connect(_on_match_finished)
	var app_log := get_node_or_null("/root/AppLog") as AppLogService
	if app_log != null:
		app_log.public_log_emitted.connect(_on_public_log)

func _on_game_event(payload: Dictionary, kind: String) -> void:
	_event_log.append_game_event(kind, payload)
	_refresh_event_text()

func _on_time_changed(remaining_seconds: float, _ratio: float) -> void:
	_event_log.append_game_event("time_changed", {"remaining_seconds": remaining_seconds})
	_refresh_event_text()

func _on_match_paused() -> void:
	_append_status_event("Match paused")

func _on_match_resumed() -> void:
	_append_status_event("Match resumed")

func _on_match_finished(_result: Dictionary) -> void:
	_append_status_event("Match finished")

func _on_public_log(level: String, message: String) -> void:
	_event_log.append_public_log(level, message)
	_refresh_event_text()

func _append_status_event(message: String) -> void:
	_event_log.append_public_log("GAME", message)
	_refresh_event_text()

func _refresh_event_text() -> void:
	if _events_label == null:
		return
	var entries := _event_log.get_lines()
	var first_index := maxi(0, entries.size() - EVENT_LINE_LIMIT)
	var lines: PackedStringArray = PackedStringArray(["Events"])
	for index in range(first_index, entries.size()):
		lines.append(entries[index])
	if lines.size() == 1:
		lines.append("No public events yet")
	_events_label.text = "\n".join(lines)
