class_name DebugEventLog

const MAX_ENTRIES := 50

var _entries: PackedStringArray = PackedStringArray()

func append_game_event(kind: String, payload: Dictionary) -> void:
	var line := _format_game_event(kind, payload)
	if not line.is_empty():
		_append(line)

func append_public_log(level: String, message: String) -> void:
	_append("[%s] %s" % [level, message])

func get_lines() -> PackedStringArray:
	return _entries

func clear() -> void:
	_entries.clear()

func _append(line: String) -> void:
	_entries.append(line)
	if _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)

func _format_game_event(kind: String, payload: Dictionary) -> String:
	match kind:
		"player_spawned", "player_respawned":
			return _format_player_event(kind, payload, PackedStringArray(["player_id"]))
		"player_damaged":
			return _format_player_event(kind, payload, PackedStringArray(["victim_id", "attacker_id", "amount"]))
		"player_killed":
			return _format_player_event(kind, payload, PackedStringArray(["victim_id", "killer_id"]))
		"projectile_fired":
			return _format_player_event(kind, payload, PackedStringArray(["projectile_id", "owner_id"]))
		"time_changed":
			return _format_player_event(kind, payload, PackedStringArray(["remaining_seconds"]))
		_:
			return ""

func _format_player_event(kind: String, payload: Dictionary, public_keys: PackedStringArray) -> String:
	var fields: PackedStringArray = PackedStringArray()
	for key in public_keys:
		if payload.has(key) and _is_public_number(payload[key]):
			fields.append("%s=%s" % [key, payload[key]])
	return "%s %s" % [kind, " ".join(fields)]

func _is_public_number(value: Variant) -> bool:
	return value is int or value is float
