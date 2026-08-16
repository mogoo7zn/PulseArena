extends RefCounted
# Versioned high-level tactical action used by Hybrid Tactical Agent.
class_name HighLevelDecision

const PROTOCOL_VERSION := 2

enum TargetSlot {
	NONE,
	ENEMY_0,
	ENEMY_1,
	ENEMY_2,
	BEST_VISIBLE_ENEMY,
	LOWEST_HEALTH_ENEMY,
	SCRIPTED_TARGET,
}

enum MovementMode {
	HOLD,
	CHASE,
	KEEP_RANGE,
	STRAFE_CLOCKWISE,
	STRAFE_COUNTERCLOCKWISE,
	RETREAT,
	SEEK_COVER,
	PEEK_FROM_COVER,
	SEEK_BEST_PICKUP,
	MOVE_TO_CENTER,
	EVADE_PROJECTILE,
	USE_SCRIPTED_MOVEMENT,
}

enum FireMode {
	HOLD_FIRE,
	CONSERVATIVE,
	NORMAL,
	BURST,
	ALL_IN,
	USE_SCRIPTED_FIRE_MODE,
}

enum SkillMode {
	NONE,
	AUTO_DEFENSE,
	DASH_EVADE,
	DASH_ENGAGE,
	SHIELD,
	USE_SCRIPTED_SKILL,
}

const TARGET_SLOT_COUNT := 7
const MOVEMENT_MODE_COUNT := 12
const FIRE_MODE_COUNT := 6
const SKILL_MODE_COUNT := 6

const TARGET_NAMES := [
	"NONE",
	"ENEMY_0",
	"ENEMY_1",
	"ENEMY_2",
	"BEST_VISIBLE_ENEMY",
	"LOWEST_HEALTH_ENEMY",
	"SCRIPTED_TARGET",
]

const MOVEMENT_NAMES := [
	"HOLD",
	"CHASE",
	"KEEP_RANGE",
	"STRAFE_CLOCKWISE",
	"STRAFE_COUNTERCLOCKWISE",
	"RETREAT",
	"SEEK_COVER",
	"PEEK_FROM_COVER",
	"SEEK_BEST_PICKUP",
	"MOVE_TO_CENTER",
	"EVADE_PROJECTILE",
	"USE_SCRIPTED_MOVEMENT",
]

const FIRE_NAMES := [
	"HOLD_FIRE",
	"CONSERVATIVE",
	"NORMAL",
	"BURST",
	"ALL_IN",
	"USE_SCRIPTED_FIRE_MODE",
]

const SKILL_NAMES := [
	"NONE",
	"AUTO_DEFENSE",
	"DASH_EVADE",
	"DASH_ENGAGE",
	"SHIELD",
	"USE_SCRIPTED_SKILL",
]

var protocol_version: int = PROTOCOL_VERSION
var target_slot: int = TargetSlot.BEST_VISIBLE_ENEMY
var movement_mode: int = MovementMode.KEEP_RANGE
var fire_mode: int = FireMode.NORMAL
var skill_mode: int = SkillMode.AUTO_DEFENSE
var confidence: float = 1.0
var decision_id: int = 0
var candidate_index: int = -1

func copy():
	var out = get_script().new()
	out.protocol_version = protocol_version
	out.target_slot = target_slot
	out.movement_mode = movement_mode
	out.fire_mode = fire_mode
	out.skill_mode = skill_mode
	out.confidence = confidence
	out.decision_id = decision_id
	out.candidate_index = candidate_index
	return out

func to_dict() -> Dictionary:
	return {
		"protocol_version": protocol_version,
		"target_slot": target_slot,
		"movement_mode": movement_mode,
		"fire_mode": fire_mode,
		"skill_mode": skill_mode,
		"confidence": confidence,
		"decision_id": decision_id,
		"candidate_index": candidate_index,
		"target_name": target_name(target_slot),
		"movement_name": movement_name(movement_mode),
		"fire_name": fire_name(fire_mode),
		"skill_name": skill_name(skill_mode),
	}

static func from_dict(data: Dictionary):
	var decision = load("res://scripts/agents/tactical_decision.gd").new()
	decision.protocol_version = int(data.get("protocol_version", data.get("protocol", PROTOCOL_VERSION)))
	decision.target_slot = int(data.get("target_slot", TargetSlot.BEST_VISIBLE_ENEMY))
	decision.movement_mode = int(data.get("movement_mode", MovementMode.KEEP_RANGE))
	decision.fire_mode = int(data.get("fire_mode", FireMode.NORMAL))
	decision.skill_mode = int(data.get("skill_mode", SkillMode.AUTO_DEFENSE))
	decision.confidence = _safe_float(data.get("confidence", 1.0), 0.0)
	decision.decision_id = int(data.get("decision_id", 0))
	decision.candidate_index = int(data.get("candidate_index", -1))
	decision.clamp_fields()
	return decision

static func scripted_teacher(decision_id_value: int = 0):
	var decision = load("res://scripts/agents/tactical_decision.gd").new()
	decision.target_slot = TargetSlot.SCRIPTED_TARGET
	decision.movement_mode = MovementMode.USE_SCRIPTED_MOVEMENT
	decision.fire_mode = FireMode.USE_SCRIPTED_FIRE_MODE
	decision.skill_mode = SkillMode.USE_SCRIPTED_SKILL
	decision.confidence = 1.0
	decision.decision_id = decision_id_value
	return decision

func clamp_fields() -> void:
	protocol_version = PROTOCOL_VERSION
	target_slot = clampi(target_slot, 0, TARGET_SLOT_COUNT - 1)
	movement_mode = clampi(movement_mode, 0, MOVEMENT_MODE_COUNT - 1)
	fire_mode = clampi(fire_mode, 0, FIRE_MODE_COUNT - 1)
	skill_mode = clampi(skill_mode, 0, SKILL_MODE_COUNT - 1)
	if not is_finite(confidence):
		confidence = 0.0
	confidence = clampf(confidence, 0.0, 1.0)

func apply_masks(masks: Dictionary) -> bool:
	clamp_fields()
	var changed := false
	var target_mask := _mask_array(masks, "target_slot", TARGET_SLOT_COUNT)
	var movement_mask := _mask_array(masks, "movement_mode", MOVEMENT_MODE_COUNT)
	var fire_mask := _mask_array(masks, "fire_mode", FIRE_MODE_COUNT)
	var skill_mask := _mask_array(masks, "skill_mode", SKILL_MODE_COUNT)
	if not _is_legal(target_mask, target_slot):
		target_slot = _first_legal(target_mask, TargetSlot.BEST_VISIBLE_ENEMY)
		changed = true
	if not _is_legal(movement_mask, movement_mode):
		movement_mode = _first_legal(movement_mask, MovementMode.KEEP_RANGE)
		changed = true
	if not _is_legal(fire_mask, fire_mode):
		fire_mode = _first_legal(fire_mask, FireMode.HOLD_FIRE)
		changed = true
	if not _is_legal(skill_mask, skill_mode):
		skill_mode = _first_legal(skill_mask, SkillMode.NONE)
		changed = true
	return not changed

static func masks_have_any_action(masks: Dictionary) -> bool:
	return _has_legal(_mask_array(masks, "target_slot", TARGET_SLOT_COUNT)) and _has_legal(_mask_array(masks, "movement_mode", MOVEMENT_MODE_COUNT)) and _has_legal(_mask_array(masks, "fire_mode", FIRE_MODE_COUNT)) and _has_legal(_mask_array(masks, "skill_mode", SKILL_MODE_COUNT))

static func target_name(value: int) -> String:
	return _name_for(TARGET_NAMES, value)

static func movement_name(value: int) -> String:
	return _name_for(MOVEMENT_NAMES, value)

static func fire_name(value: int) -> String:
	return _name_for(FIRE_NAMES, value)

static func skill_name(value: int) -> String:
	return _name_for(SKILL_NAMES, value)

static func _name_for(names: Array, value: int) -> String:
	return names[value] if value >= 0 and value < names.size() else "UNKNOWN"

static func _mask_array(masks: Dictionary, key: String, count: int) -> Array:
	var raw: Variant = masks.get(key, [])
	var out: Array = []
	if raw is Array:
		out = raw.duplicate()
	elif raw is PackedFloat32Array:
		for value in raw:
			out.append(value)
	while out.size() < count:
		out.append(false)
	return out

static func _is_legal(mask: Array, index: int) -> bool:
	return index >= 0 and index < mask.size() and bool(mask[index])

static func _first_legal(mask: Array, fallback: int) -> int:
	if _is_legal(mask, fallback):
		return fallback
	for i in range(mask.size()):
		if bool(mask[i]):
			return i
	return fallback

static func _has_legal(mask: Array) -> bool:
	for value in mask:
		if bool(value):
			return true
	return false

static func _safe_float(value: Variant, fallback: float) -> float:
	var result := float(value)
	return result if is_finite(result) else fallback
