from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np


MAX_OTHER_PLAYERS = 3
MAX_PROJECTILES = 24
RAY_COUNT = 16
ACTION_DIM = 7
HYBRID_PROTOCOL_VERSION = 2
TACTICAL_FEATURE_SCHEMA_VERSION = 2
TACTICAL_FEATURE_DIM = 142
TACTICAL_TARGETS = [
    "NONE",
    "ENEMY_0",
    "ENEMY_1",
    "ENEMY_2",
    "BEST_VISIBLE_ENEMY",
    "LOWEST_HEALTH_ENEMY",
    "SCRIPTED_TARGET",
]
TACTICAL_MOVEMENTS = [
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
TACTICAL_FIRE_MODES = [
    "HOLD_FIRE",
    "CONSERVATIVE",
    "NORMAL",
    "BURST",
    "ALL_IN",
    "USE_SCRIPTED_FIRE_MODE",
]
TACTICAL_SKILL_MODES = [
    "NONE",
    "AUTO_DEFENSE",
    "DASH_EVADE",
    "DASH_ENGAGE",
    "SHIELD",
    "USE_SCRIPTED_SKILL",
]


@dataclass(frozen=True)
class ReplayArrays:
    observations: np.ndarray
    actions: np.ndarray
    files: list[Path]

    @property
    def observation_dim(self) -> int:
        return int(self.observations.shape[1])

    @property
    def action_dim(self) -> int:
        return int(self.actions.shape[1])


@dataclass(frozen=True)
class HybridReplayArrays:
    tactical_features: np.ndarray
    target_slots: np.ndarray
    movement_modes: np.ndarray
    fire_modes: np.ndarray
    skill_modes: np.ndarray
    target_masks: np.ndarray
    movement_masks: np.ndarray
    fire_masks: np.ndarray
    skill_masks: np.ndarray
    label_weights: np.ndarray
    confidence_targets: np.ndarray
    action_masks: list[dict[str, Any]]
    files: list[Path]

    @property
    def feature_dim(self) -> int:
        return int(self.tactical_features.shape[1])


def vec2(data: Any) -> tuple[float, float]:
    if isinstance(data, dict):
        return float(data.get("x", 0.0)), float(data.get("y", 0.0))
    return 0.0, 0.0


def b(value: Any) -> float:
    return 1.0 if bool(value) else 0.0


def flatten_observation(obs: dict[str, Any]) -> list[float]:
    self_data = obs.get("self", {})
    pos = vec2(self_data.get("position", {}))
    vel = vec2(self_data.get("velocity", {}))
    aim = vec2(self_data.get("aim_direction", {"x": 1.0, "y": 0.0}))
    out: list[float] = [
        float(self_data.get("player_id", -1)),
        float(self_data.get("team_id", -1)),
        pos[0],
        pos[1],
        vel[0],
        vel[1],
        aim[0],
        aim[1],
        float(self_data.get("health_ratio", 1.0)),
        float(self_data.get("energy_ratio", 1.0)),
        float(self_data.get("shoot_cooldown_ratio", 0.0)),
        float(self_data.get("dash_cooldown_ratio", 0.0)),
        float(self_data.get("shield_cooldown_ratio", 0.0)),
        b(self_data.get("is_alive", True)),
        b(self_data.get("is_shielding", False)),
        b(self_data.get("has_respawn_protection", False)),
        float(self_data.get("score", 0)),
        float(self_data.get("remaining_time_ratio", 1.0)),
    ]

    players = list(obs.get("other_players", []))[:MAX_OTHER_PLAYERS]
    while len(players) < MAX_OTHER_PLAYERS:
        players.append({})
    for player in players:
        rel = vec2(player.get("relative_position", {}))
        rel_vel = vec2(player.get("relative_velocity", {}))
        player_aim = vec2(player.get("aim_direction", {"x": 1.0, "y": 0.0}))
        out.extend([
            rel[0],
            rel[1],
            rel_vel[0],
            rel_vel[1],
            player_aim[0],
            player_aim[1],
            float(player.get("health_ratio", 0.0)),
            b(player.get("is_teammate", False)),
            b(player.get("is_alive", False)),
            b(player.get("is_shielding", False)),
            b(player.get("is_dashing", False)),
            b(player.get("has_respawn_protection", False)),
            b(player.get("valid", False)),
        ])

    projectiles = list(obs.get("projectiles", []))[:MAX_PROJECTILES]
    while len(projectiles) < MAX_PROJECTILES:
        projectiles.append({})
    for projectile in projectiles:
        rel = vec2(projectile.get("relative_position", {}))
        rel_vel = vec2(projectile.get("relative_velocity", {}))
        out.extend([
            rel[0],
            rel[1],
            rel_vel[0],
            rel_vel[1],
            b(projectile.get("is_own", False)),
            b(projectile.get("is_teammate", False)),
            float(projectile.get("lifetime_ratio", 0.0)),
            float(projectile.get("damage_ratio", 0.0)),
            b(projectile.get("valid", False)),
        ])

    map_data = obs.get("map", {})
    boundaries = list(map_data.get("boundary_distances", [1.0, 1.0, 1.0, 1.0]))[:4]
    while len(boundaries) < 4:
        boundaries.append(1.0)
    rays = list(map_data.get("ray_results", []))[:RAY_COUNT]
    while len(rays) < RAY_COUNT:
        rays.append(1.0)
    resource = vec2(map_data.get("nearest_resource_relative_position", {}))
    out.extend(float(x) for x in boundaries)
    out.extend(float(x) for x in rays)
    out.extend([
        resource[0],
        resource[1],
        float(map_data.get("map_id", 0)),
        float(map_data.get("game_mode_id", 0)),
    ])
    return out


def flatten_action(action: dict[str, Any]) -> list[float]:
    return [
        float(action.get("move_x", 0.0)),
        float(action.get("move_y", 0.0)),
        float(action.get("aim_x", 1.0)),
        float(action.get("aim_y", 0.0)),
        b(action.get("shoot", False)),
        b(action.get("dash", False)),
        b(action.get("shield", False)),
    ]


def normalize_tactical_features(values: Any) -> list[float]:
    raw = list(values or [])[:TACTICAL_FEATURE_DIM]
    out = [float(x) if np.isfinite(float(x)) else 0.0 for x in raw]
    while len(out) < TACTICAL_FEATURE_DIM:
        out.append(0.0)
    return out


def tactical_decision_to_indices(decision: dict[str, Any]) -> tuple[int, int, int, int]:
    return (
        int(np.clip(int(decision.get("target_slot", 0)), 0, len(TACTICAL_TARGETS) - 1)),
        int(np.clip(int(decision.get("movement_mode", 0)), 0, len(TACTICAL_MOVEMENTS) - 1)),
        int(np.clip(int(decision.get("fire_mode", 0)), 0, len(TACTICAL_FIRE_MODES) - 1)),
        int(np.clip(int(decision.get("skill_mode", 0)), 0, len(TACTICAL_SKILL_MODES) - 1)),
    )


def normalize_tactical_mask(mask: Any, count: int, required_index: int) -> list[bool]:
    values = list(mask or [])[:count]
    out = [bool(value) for value in values]
    while len(out) < count:
        out.append(False)
    if not any(out):
        out[int(np.clip(required_index, 0, count - 1))] = True
    elif 0 <= required_index < count and not out[required_index]:
        # Keep the supervised label trainable while preserving all other mask
        # information. Bad labels should be handled by label_weight upstream.
        out[required_index] = True
    return out


def tactical_decision_is_scripted_delegate(decision: dict[str, Any]) -> bool:
    return (
        int(decision.get("target_slot", -1)) == 6
        and int(decision.get("movement_mode", -1)) == 11
        and int(decision.get("fire_mode", -1)) == 5
        and int(decision.get("skill_mode", -1)) == 5
    )


def tactical_action_masks_from_observation(obs: dict[str, Any]) -> dict[str, list[bool]]:
    players = list(obs.get("other_players", []))[:MAX_OTHER_PLAYERS]
    valid_enemies = [
        i
        for i, player in enumerate(players)
        if player.get("valid") and player.get("is_alive") and not player.get("is_teammate")
    ]
    any_enemy = bool(valid_enemies)
    self_data = obs.get("self", {})
    energy_ratio = float(self_data.get("energy_ratio", 0.0))
    dash_ready = float(self_data.get("dash_cooldown_ratio", 1.0)) <= 0.01 and energy_ratio >= 0.30
    shield_ready = float(self_data.get("shield_cooldown_ratio", 1.0)) <= 0.01 and energy_ratio >= 0.25
    target = [False] * len(TACTICAL_TARGETS)
    target[0] = True
    target[6] = True
    for slot in valid_enemies:
        target[1 + slot] = True
    target[4] = any_enemy
    target[5] = any_enemy
    movement = [True] * len(TACTICAL_MOVEMENTS)
    movement[8] = bool(vec2(obs.get("map", {}).get("nearest_resource_relative_position", {})) != (0.0, 0.0))
    movement[10] = True
    fire = [any_enemy] * len(TACTICAL_FIRE_MODES)
    fire[0] = True
    fire[5] = True
    if energy_ratio <= 0.03:
        fire[3] = False
        fire[4] = False
    skill = [True] * len(TACTICAL_SKILL_MODES)
    skill[2] = dash_ready
    skill[3] = dash_ready and any_enemy
    skill[4] = shield_ready
    return {
        "target_slot": target,
        "movement_mode": movement,
        "fire_mode": fire,
        "skill_mode": skill,
    }


def tactical_features_from_observation(obs: dict[str, Any]) -> list[float]:
    base = flatten_observation(obs)
    out = base[:TACTICAL_FEATURE_DIM]
    while len(out) < TACTICAL_FEATURE_DIM:
        out.append(0.0)
    return [float(x) for x in out]


def load_replay_arrays(replay_dir: Path, max_samples: int | None = None) -> ReplayArrays:
    files = sorted(replay_dir.glob("*.jsonl"))
    if not files:
        raise FileNotFoundError(f"No replay JSONL files found in {replay_dir}")
    observations: list[list[float]] = []
    actions: list[list[float]] = []
    used_files: list[Path] = []
    for path in files:
        loaded_from_file = 0
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("replay_schema") == "hybrid_replay_v2":
                    continue
                observations.append(flatten_observation(row["observation"]))
                actions.append(flatten_action(row["action"]))
                loaded_from_file += 1
                if max_samples is not None and len(observations) >= max_samples:
                    break
        if loaded_from_file:
            used_files.append(path)
        if max_samples is not None and len(observations) >= max_samples:
            break
    if not observations:
        raise FileNotFoundError(f"No raw replay v1 rows found in {replay_dir}; hybrid_replay_v2 must use load_hybrid_replay_arrays")
    return ReplayArrays(
        observations=np.asarray(observations, dtype=np.float32),
        actions=np.asarray(actions, dtype=np.float32),
        files=used_files,
    )


def load_hybrid_replay_arrays(replay_dir: Path, max_samples: int | None = None, decision_key: str = "teacher_decision") -> HybridReplayArrays:
    files = sorted(replay_dir.glob("*.hybrid_v2.jsonl"))
    if not files:
        files = sorted(replay_dir.glob("*.jsonl"))
    if not files:
        raise FileNotFoundError(f"No replay JSONL files found in {replay_dir}")
    features: list[list[float]] = []
    target_slots: list[int] = []
    movement_modes: list[int] = []
    fire_modes: list[int] = []
    skill_modes: list[int] = []
    target_masks: list[list[bool]] = []
    movement_masks: list[list[bool]] = []
    fire_masks: list[list[bool]] = []
    skill_masks: list[list[bool]] = []
    label_weights: list[float] = []
    confidence_targets: list[float] = []
    masks: list[dict[str, Any]] = []
    used_files: list[Path] = []
    for path in files:
        loaded_from_file = 0
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("replay_schema") != "hybrid_replay_v2":
                    continue
                decision = row.get(decision_key) or row.get("executed_decision") or {}
                target, movement, fire, skill = tactical_decision_to_indices(decision)
                action_mask = dict(row.get("action_masks") or tactical_action_masks_from_observation(row.get("observation", {})))
                weight = float(row.get("label_weight", 1.0))
                if tactical_decision_is_scripted_delegate(decision) and not row.get("label_source"):
                    weight = min(weight, 0.15)
                if bool(row.get("fallback_used", False)):
                    weight *= 0.70
                if bool(row.get("safety_override", False)):
                    weight *= 0.85
                features.append(normalize_tactical_features(row.get("tactical_features", [])))
                target_slots.append(target)
                movement_modes.append(movement)
                fire_modes.append(fire)
                skill_modes.append(skill)
                target_masks.append(normalize_tactical_mask(action_mask.get("target_slot"), len(TACTICAL_TARGETS), target))
                movement_masks.append(normalize_tactical_mask(action_mask.get("movement_mode"), len(TACTICAL_MOVEMENTS), movement))
                fire_masks.append(normalize_tactical_mask(action_mask.get("fire_mode"), len(TACTICAL_FIRE_MODES), fire))
                skill_masks.append(normalize_tactical_mask(action_mask.get("skill_mode"), len(TACTICAL_SKILL_MODES), skill))
                label_weights.append(float(np.clip(weight, 0.05, 1.0)))
                confidence_targets.append(float(np.clip(row.get("label_confidence", decision.get("confidence", 1.0)), 0.0, 1.0)))
                masks.append(action_mask)
                loaded_from_file += 1
                if max_samples is not None and len(features) >= max_samples:
                    break
        if loaded_from_file:
            used_files.append(path)
        if max_samples is not None and len(features) >= max_samples:
            break
    if not features:
        raise FileNotFoundError(f"No hybrid_replay_v2 rows found in {replay_dir}")
    return HybridReplayArrays(
        tactical_features=np.asarray(features, dtype=np.float32),
        target_slots=np.asarray(target_slots, dtype=np.int64),
        movement_modes=np.asarray(movement_modes, dtype=np.int64),
        fire_modes=np.asarray(fire_modes, dtype=np.int64),
        skill_modes=np.asarray(skill_modes, dtype=np.int64),
        target_masks=np.asarray(target_masks, dtype=np.bool_),
        movement_masks=np.asarray(movement_masks, dtype=np.bool_),
        fire_masks=np.asarray(fire_masks, dtype=np.bool_),
        skill_masks=np.asarray(skill_masks, dtype=np.bool_),
        label_weights=np.asarray(label_weights, dtype=np.float32),
        confidence_targets=np.asarray(confidence_targets, dtype=np.float32),
        action_masks=masks,
        files=used_files,
    )


def count_replay_rows(replay_dir: Path) -> tuple[int, int, int]:
    files = sorted(replay_dir.glob("*.jsonl"))
    rows = 0
    bytes_total = 0
    for path in files:
        bytes_total += path.stat().st_size
        with path.open("r", encoding="utf-8") as handle:
            rows += sum(1 for line in handle if line.strip())
    return len(files), rows, bytes_total
