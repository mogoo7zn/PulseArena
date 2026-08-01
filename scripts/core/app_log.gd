extends Node
# 简单日志服务，统一输出带等级和上下文的运行日志。
class_name AppLogService

enum Level { DEBUG, INFO, WARN, ERROR }

signal public_log_emitted(level: String, message: String)

var minimum_level: Level = Level.INFO

func debug(message: String, context: Dictionary = {}) -> void:
	_log(Level.DEBUG, message, context)

func info(message: String, context: Dictionary = {}) -> void:
	_log(Level.INFO, message, context)

func warn(message: String, context: Dictionary = {}) -> void:
	_log(Level.WARN, message, context)

func error(message: String, context: Dictionary = {}) -> void:
	_log(Level.ERROR, message, context)

func public_info(message: String) -> void:
	_log(Level.INFO, message, {})
	public_log_emitted.emit("INFO", message)

func public_warn(message: String) -> void:
	_log(Level.WARN, message, {})
	public_log_emitted.emit("WARN", message)

func public_error(message: String) -> void:
	_log(Level.ERROR, message, {})
	public_log_emitted.emit("ERROR", message)

func _log(level: Level, message: String, context: Dictionary) -> void:
	if level < minimum_level:
		return
	var label: String = Level.keys()[level]
	var suffix: String = ""
	if not context.is_empty():
		suffix = " " + JSON.stringify(context)
	print("[%s] %s%s" % [label, message, suffix])
