extends Resource
# 单局比赛配置资源，记录模式、地图、人数、随机种子和训练标记。
class_name MatchConfig

const MODE_FFA := "ffa"
const MODE_TEAM_2V2 := "team_2v2"
const MAP_DUNGEON := "dungeon"
const MAP_SKY_CITY := "sky_city"
const MAP_JUNGLE := "jungle"
const MAP_MIST_WORLD := "mist_world"
const MAP_ARENA_CROSS := MAP_DUNGEON
const MAP_NEON_DOCKS := MAP_SKY_CITY
const MAP_REACTOR_RING := MAP_JUNGLE
const MAP_SKYLINE_YARD := MAP_MIST_WORLD
const AGENT_CONTROLLER_SCRIPTED := "scripted"
const AGENT_CONTROLLER_MODEL := "model"
const AGENT_CONTROLLER_HYBRID := "hybrid"

@export var mode: String = MODE_FFA
@export var human_player_count: int = 1
@export var agent_count: int = 1
@export var team_mode: bool = false
@export var friendly_fire: bool = true
@export var time_limit: float = 90.0
@export var score_limit: int = 0
@export var map_id: String = MAP_DUNGEON
@export var agent_difficulty: String = "normal"
@export var agent_controller: String = AGENT_CONTROLLER_SCRIPTED
@export var agent_model_id: String = ""
@export var agent_model_host: String = "127.0.0.1"
@export var agent_model_port: int = 8766
@export var agent_model_timeout_ms: int = 16
@export var random_seed: int = 1234
@export var headless: bool = false
@export var record_replay: bool = false
@export var training_fast_mode: bool = false

func duplicate_config() -> MatchConfig:
	var copy := MatchConfig.new()
	copy.mode = mode
	copy.human_player_count = human_player_count
	copy.agent_count = agent_count
	copy.team_mode = team_mode
	copy.friendly_fire = friendly_fire
	copy.time_limit = time_limit
	copy.score_limit = score_limit
	copy.map_id = map_id
	copy.agent_difficulty = agent_difficulty
	copy.agent_controller = agent_controller
	copy.agent_model_id = agent_model_id
	copy.agent_model_host = agent_model_host
	copy.agent_model_port = agent_model_port
	copy.agent_model_timeout_ms = agent_model_timeout_ms
	copy.random_seed = random_seed
	copy.headless = headless
	copy.record_replay = record_replay
	copy.training_fast_mode = training_fast_mode
	return copy

func total_players() -> int:
	return human_player_count + agent_count

func to_dict() -> Dictionary:
	return {
		"mode": mode,
		"human_player_count": human_player_count,
		"agent_count": agent_count,
		"team_mode": team_mode,
		"friendly_fire": friendly_fire,
		"time_limit": time_limit,
		"score_limit": score_limit,
		"map_id": map_id,
		"agent_difficulty": agent_difficulty,
		"agent_controller": agent_controller,
		"agent_model_id": agent_model_id,
		"agent_model_host": agent_model_host,
		"agent_model_port": agent_model_port,
		"agent_model_timeout_ms": agent_model_timeout_ms,
		"random_seed": random_seed,
		"headless": headless,
		"record_replay": record_replay,
		"training_fast_mode": training_fast_mode,
	}

static func from_dict(data: Dictionary) -> MatchConfig:
	var config := MatchConfig.new()
	config.mode = str(data.get("mode", MODE_FFA))
	config.human_player_count = int(data.get("human_player_count", 1))
	config.agent_count = int(data.get("agent_count", 1))
	config.team_mode = bool(data.get("team_mode", false))
	config.friendly_fire = bool(data.get("friendly_fire", not config.team_mode))
	config.time_limit = float(data.get("time_limit", 90.0))
	config.score_limit = int(data.get("score_limit", 0))
	config.map_id = str(data.get("map_id", MAP_ARENA_CROSS))
	config.agent_difficulty = str(data.get("agent_difficulty", "normal"))
	config.agent_controller = str(data.get("agent_controller", AGENT_CONTROLLER_SCRIPTED))
	config.agent_model_id = str(data.get("agent_model_id", ""))
	config.agent_model_host = str(data.get("agent_model_host", "127.0.0.1"))
	config.agent_model_port = int(data.get("agent_model_port", 8766))
	config.agent_model_timeout_ms = int(data.get("agent_model_timeout_ms", 16))
	config.random_seed = int(data.get("random_seed", 1234))
	config.headless = bool(data.get("headless", false))
	config.record_replay = bool(data.get("record_replay", false))
	config.training_fast_mode = bool(data.get("training_fast_mode", false))
	return config

static func preset_human_vs_agent(agent_count_value: int) -> MatchConfig:
	var config := MatchConfig.new()
	config.mode = MODE_FFA
	config.human_player_count = 1
	config.agent_count = clampi(agent_count_value, 1, 3)
	config.team_mode = false
	config.friendly_fire = true
	return config

static func preset_2_humans_vs_2_agents() -> MatchConfig:
	var config := MatchConfig.new()
	config.mode = MODE_TEAM_2V2
	config.human_player_count = 2
	config.agent_count = 2
	config.team_mode = true
	config.friendly_fire = false
	return config

static func preset_training_ffa_agents(agent_count_value: int = 4) -> MatchConfig:
	var config := MatchConfig.new()
	config.mode = MODE_FFA
	config.human_player_count = 0
	config.agent_count = clampi(agent_count_value, 1, 4)
	config.team_mode = false
	config.friendly_fire = true
	config.headless = true
	config.time_limit = 10.0
	config.record_replay = false
	config.training_fast_mode = true
	return config
