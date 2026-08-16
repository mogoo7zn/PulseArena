extends RefCounted
# Tunable deterministic layer parameters for the Hybrid Tactical Agent.
class_name HybridAgentConfig

const MODEL_ID := "hybrid_tactical_v1"
const PROTOCOL_VERSION := 2
const OBSERVATION_SCHEMA_VERSION := 2
const REPLAY_SCHEMA := "hybrid_replay_v2"

var decision_hz: float = 15.0
var model_timeout_ms: int = 16
var low_confidence_threshold: float = 0.32
var low_confidence_window: float = 1.0
var fallback_recover_window: float = 0.75
var no_target_fire_window: float = 0.45
var projectile_prediction_margin: float = 18.0
var max_prediction_time: float = 1.35
var max_aim_smoothing_rate: float = 18.0
var preferred_range: float = 420.0
var close_range: float = 190.0
var far_range: float = 640.0
var cover_probe_distance: float = 220.0
var wall_probe_distance: float = 120.0
var stuck_window: float = 0.65
var stuck_min_command: float = 0.45
var stuck_max_displacement: float = 7.5
var stuck_recovery_duration: float = 0.38
var stuck_recovery_cooldown: float = 0.55
var movement_hysteresis: float = 0.18
var conservative_hit_probability: float = 0.74
var normal_hit_probability: float = 0.52
var burst_hit_probability: float = 0.58
var all_in_hit_probability: float = 0.46
var conservative_max_aim_error: float = 0.14
var normal_max_aim_error: float = 0.28
var burst_max_aim_error: float = 0.24
var all_in_max_aim_error: float = 0.34
var burst_size: int = 3
var burst_recovery: float = 0.48
var base_reserved_energy_ratio: float = 0.22
var defensive_reserved_energy_ratio: float = 0.45
var all_in_reserved_energy_ratio: float = 0.05
var conservative_reserved_energy_ratio: float = 0.40
var burst_reserved_energy_ratio: float = 0.18
var high_threat_threshold: float = 0.72
var emergency_threat_threshold: float = 0.88
var cover_health_threshold: float = 0.34
var cover_threat_threshold: float = 0.0
var dash_ready_reserved_energy_ratio: float = 0.26
var shield_ready_reserved_energy_ratio: float = 0.24
var threat_reserved_energy_floor: float = 0.26
var engagement_vantage_enabled: bool = false
var engagement_vantage_probe_distance: float = 180.0
var engagement_vantage_samples: int = 16
var engagement_vantage_hold_seconds: float = 0.75
# Keeps the deployed default feature semantics stable.  Pressure training opts
# in to target-level geometric visibility from public map collision data.
var target_visibility_features_enabled: bool = false
# Only enabled by the replay-only pressure profile: it lets the deterministic
# teacher drive collection trajectories when no model service is attached.
var teacher_fallback_enabled: bool = false
var engagement_profile_id: String = "baseline"

# Training profiles may tune the deterministic safety envelope, but gameplay
# defaults deliberately remain unchanged for deployed hybrid controllers.
static func for_profile(profile_id: String) -> HybridAgentConfig:
	var resolved := HybridAgentConfig.new()
	if profile_id == "legal_window_pressure":
		resolved.engagement_profile_id = profile_id
		resolved.target_visibility_features_enabled = true
		resolved.teacher_fallback_enabled = true
		resolved.engagement_vantage_enabled = true
		resolved.engagement_vantage_probe_distance = 280.0
		resolved.conservative_hit_probability = 0.60
		resolved.normal_hit_probability = 0.44
		resolved.burst_hit_probability = 0.50
		resolved.conservative_max_aim_error = 0.20
		resolved.normal_max_aim_error = 0.34
		resolved.burst_max_aim_error = 0.30
		resolved.base_reserved_energy_ratio = 0.16
		resolved.defensive_reserved_energy_ratio = 0.38
		resolved.conservative_reserved_energy_ratio = 0.26
		resolved.burst_reserved_energy_ratio = 0.14
		resolved.cover_health_threshold = 0.46
		resolved.cover_threat_threshold = 0.38
		resolved.dash_ready_reserved_energy_ratio = 0.20
		resolved.shield_ready_reserved_energy_ratio = 0.22
		resolved.threat_reserved_energy_floor = 0.16
	return resolved
