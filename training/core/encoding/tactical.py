"""Tactical decision labels, masks and feature projection.

These helpers translate between teacher decision dictionaries and the
fixed-shape tensors consumed by masked PPO and behavior cloning.
"""
from __future__ import annotations

from typing import Any

import numpy as np


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


def normalize_tactical_features(values: Any) -> list[float]:
    """Trim/pad a tactical feature list to ``TACTICAL_FEATURE_DIM``."""
    raw = list(values or [])[:TACTICAL_FEATURE_DIM]
    out = [float(x) if np.isfinite(float(x)) else 0.0 for x in raw]
    while len(out) < TACTICAL_FEATURE_DIM:
        out.append(0.0)
    return out


def tactical_decision_to_indices(decision: dict[str, Any]) -> tuple[int, int, int, int]:
    """Project a decision dict onto ``(target, movement, fire, skill)`` indices."""
    return (
        int(np.clip(int(decision.get("target_slot", 0)), 0, len(TACTICAL_TARGETS) - 1)),
        int(np.clip(int(decision.get("movement_mode", 0)), 0, len(TACTICAL_MOVEMENTS) - 1)),
        int(np.clip(int(decision.get("fire_mode", 0)), 0, len(TACTICAL_FIRE_MODES) - 1)),
        int(np.clip(int(decision.get("skill_mode", 0)), 0, len(TACTICAL_SKILL_MODES) - 1)),
    )


def normalize_tactical_mask(mask: Any, count: int, required_index: int) -> list[bool]:
    """Trim/pad a mask to ``count`` entries and force the supervised label trainable."""
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
    """True when the decision defers all four heads to the scripted controller."""
    return (
        int(decision.get("target_slot", -1)) == 6
        and int(decision.get("movement_mode", -1)) == 11
        and int(decision.get("fire_mode", -1)) == 5
        and int(decision.get("skill_mode", -1)) == 5
    )


def tactical_action_masks_from_observation(obs: dict[str, Any]) -> dict[str, list[bool]]:
    """Compute per-head legal action masks from a Godot-style observation."""
    from training.core.encoding.observation import (
        MAX_OTHER_PLAYERS,
        vec2,
    )

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
    """Use the flat observation as the tactical feature vector (truncated/padded)."""
    from training.core.encoding.observation import flatten_observation

    base = flatten_observation(obs)
    out = base[:TACTICAL_FEATURE_DIM]
    while len(out) < TACTICAL_FEATURE_DIM:
        out.append(0.0)
    return [float(x) for x in out]