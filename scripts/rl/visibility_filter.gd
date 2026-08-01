extends RefCounted
# 可见性过滤器，根据地图规则与视野范围筛选智能体可观测对象。
class_name VisibilityFilter

const PRIVATE_FIELD_KEYWORDS: PackedStringArray = PackedStringArray([
	"ammo",
	"reserve",
	"magazine",
	"reloadremaining",
	"reload_remaining",
	"reloadtimer",
	"reload_timer",
	"weaponcooldown",
	"weapon_cooldown",
	"shootcooldown",
	"shoot_cooldown",
	"energy",
])

func build_public_player_view(viewer, subject, config, score_manager = null) -> Dictionary:
	return {
		"player_id": subject.player_id,
		"team_id": subject.team_id,
		"display_name": subject.display_name,
		"is_human": subject.is_human,
		"is_teammate": TeamRules.are_teammates(config, viewer.team_id, subject.team_id, viewer.player_id, subject.player_id) if viewer != null and config != null else false,
		"health_ratio": subject.get_health_ratio(),
		"is_alive": subject.is_alive,
		"is_shielding": subject.is_shielding(),
		"is_dashing": subject.is_dashing(),
		"has_respawn_protection": subject.has_respawn_protection(),
		"score": score_manager.get_player_score(subject.player_id) if score_manager != null else 0,
		"kills": score_manager.get_player_kills(subject.player_id) if score_manager != null else 0,
		"deaths": score_manager.get_player_deaths(subject.player_id) if score_manager != null else 0,
	}

func build_private_player_view(subject, score_manager = null) -> Dictionary:
	var view := build_public_player_view(subject, subject, null, score_manager)
	view["energy_ratio"] = subject.get_energy_ratio()
	view["shoot_cooldown_ratio"] = subject.get_shoot_cooldown_ratio()
	view["dash_cooldown_ratio"] = subject.get_dash_cooldown_ratio()
	view["shield_cooldown_ratio"] = subject.get_shield_cooldown_ratio()
	view["respawn_timer"] = subject.respawn_timer
	return view

func contains_private_fields(data: Variant) -> bool:
	if data is Dictionary:
		for key in data.keys():
			if is_private_key(str(key)):
				return true
			if contains_private_fields(data[key]):
				return true
	elif data is Array:
		for item in data:
			if contains_private_fields(item):
				return true
	return false

func is_private_key(key: String) -> bool:
	var normalized := key.to_lower().replace("-", "_")
	var compact := normalized.replace("_", "")
	for token in PRIVATE_FIELD_KEYWORDS:
		var t := String(token).to_lower()
		if normalized == t or compact == t.replace("_", ""):
			return true
		if normalized.find(t) >= 0 or compact.find(t.replace("_", "")) >= 0:
			return true
	return false
