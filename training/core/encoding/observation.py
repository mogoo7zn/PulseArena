"""Raw observation -> flat feature vector encoding.

The Hybrid replay protocol stores self/players/projectiles/map as nested dicts.
``flatten_observation`` produces a fixed-size float vector that downstream
models (BC, PPO, runtime inference) consume directly. The shape constants
document how many slots each section occupies.
"""
from __future__ import annotations

from typing import Any

MAX_OTHER_PLAYERS = 3
MAX_PROJECTILES = 24
RAY_COUNT = 16
ACTION_DIM = 7
HYBRID_PROTOCOL_VERSION = 2
TACTICAL_FEATURE_SCHEMA_VERSION = 2


def vec2(data: Any) -> tuple[float, float]:
    if isinstance(data, dict):
        return float(data.get("x", 0.0)), float(data.get("y", 0.0))
    return 0.0, 0.0


def b(value: Any) -> float:
    return 1.0 if bool(value) else 0.0


def flatten_observation(obs: dict[str, Any]) -> list[float]:
    """Project a Godot-style observation dict onto a flat numeric vector.

    The output is sized to fit ``MAX_OTHER_PLAYERS``, ``MAX_PROJECTILES`` and
    ``RAY_COUNT``. Padding entries are zeroed out so consumers do not need to
    distinguish "missing" from "absent".
    """
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