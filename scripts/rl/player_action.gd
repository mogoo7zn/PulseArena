extends RefCounted
# 玩家动作数据结构，统一表示移动、瞄准、射击和技能输入。
class_name PlayerAction

var move: Vector2 = Vector2.ZERO
var aim: Vector2 = Vector2.RIGHT
var shoot: bool = false
var dash: bool = false
var shield: bool = false
var communication: int = 0

var move_x: float:
	get:
		return move.x
	set(value):
		move.x = value

var move_y: float:
	get:
		return move.y
	set(value):
		move.y = value

var aim_x: float:
	get:
		return aim.x
	set(value):
		aim.x = value

var aim_y: float:
	get:
		return aim.y
	set(value):
		aim.y = value

func normalize_vectors(fallback_aim: Vector2 = Vector2.RIGHT) -> void:
	if move.length_squared() > 1.0:
		move = move.normalized()
	if aim.length_squared() > 0.001:
		aim = aim.normalized()
	else:
		aim = fallback_aim.normalized() if fallback_aim.length_squared() > 0.001 else Vector2.RIGHT

func copy() -> PlayerAction:
	var out := PlayerAction.new()
	out.move = move
	out.aim = aim
	out.shoot = shoot
	out.dash = dash
	out.shield = shield
	out.communication = communication
	return out

func to_dict() -> Dictionary:
	return {
		"move_x": move.x,
		"move_y": move.y,
		"aim_x": aim.x,
		"aim_y": aim.y,
		"shoot": shoot,
		"dash": dash,
		"shield": shield,
		"communication": communication,
	}

func to_flat_array() -> PackedFloat32Array:
	return PackedFloat32Array([
		move.x,
		move.y,
		aim.x,
		aim.y,
		1.0 if shoot else 0.0,
		1.0 if dash else 0.0,
		1.0 if shield else 0.0,
		float(communication),
	])

static func from_dict(data: Dictionary, fallback_aim: Vector2 = Vector2.RIGHT) -> PlayerAction:
	var action := PlayerAction.new()
	action.move = Vector2(float(data.get("move_x", 0.0)), float(data.get("move_y", 0.0)))
	action.aim = Vector2(float(data.get("aim_x", fallback_aim.x)), float(data.get("aim_y", fallback_aim.y)))
	action.shoot = bool(data.get("shoot", false))
	action.dash = bool(data.get("dash", false))
	action.shield = bool(data.get("shield", false))
	action.communication = int(data.get("communication", 0))
	action.normalize_vectors(fallback_aim)
	return action

static func from_flat_array(values: PackedFloat32Array, fallback_aim: Vector2 = Vector2.RIGHT) -> PlayerAction:
	var action := PlayerAction.new()
	if values.size() >= 2:
		action.move = Vector2(values[0], values[1])
	if values.size() >= 4:
		action.aim = Vector2(values[2], values[3])
	if values.size() >= 5:
		action.shoot = values[4] > 0.5
	if values.size() >= 6:
		action.dash = values[5] > 0.5
	if values.size() >= 7:
		action.shield = values[6] > 0.5
	if values.size() >= 8:
		action.communication = int(values[7])
	action.normalize_vectors(fallback_aim)
	return action
