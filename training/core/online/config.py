"""Tactical PPO online-training configuration + match-config builder."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class TacticalOnlineConfig:
    output_dir: Path
    profile_id: str = "local_constrained"
    stage: str = "01_foundation_combat"
    map_id: str = "dungeon"
    map_ids: tuple[str, ...] = ()
    mode: str = "ffa"
    agents: int = 2
    opponent_controller: str = "self_play"
    training_spawn_policy: str = "safe"
    seconds: int = 20
    seed: int = 30000
    rollout_steps: int = 128
    total_env_steps: int = 2048
    tick_skip: int = 4
    hidden: int = 192
    recurrent: bool = True
    rnn_hidden: int | None = None
    lr: float = 3e-4
    ppo_clip_ratio: float = 0.2
    ppo_value_coef: float = 0.5
    ppo_entropy_coef: float = 0.01
    ppo_max_grad_norm: float = 0.5
    ppo_update_epochs: int = 4
    ppo_minibatch_size: int = 1024
    ppo_mixed_precision: bool = True
    device: str | None = None
    reward_profile_id: str = "baseline"
    bc_checkpoint: Path | None = None
    resume_checkpoint: Path | None = None
    godot: str | None = None
    port: int = 8765
    require_cuda: bool = False


SUPPORTED_MAP_IDS = ("dungeon", "sky_city", "jungle", "mist_world")


def resolve_tactical_map_ids(config: TacticalOnlineConfig) -> tuple[str, ...]:
    map_ids = tuple(config.map_ids) if config.map_ids else (config.map_id,)
    if not map_ids:
        raise ValueError("Tactical PPO requires at least one map")
    if len(set(map_ids)) != len(map_ids):
        raise ValueError(f"Tactical PPO maps must be unique: {map_ids}")
    unsupported = [map_id for map_id in map_ids if map_id not in SUPPORTED_MAP_IDS]
    if unsupported:
        raise ValueError(f"Unsupported tactical PPO maps: {unsupported}")
    return map_ids


def make_tactical_match_config(
    config: TacticalOnlineConfig, seed: int, map_id: str | None = None
) -> dict[str, Any]:
    match_config = {
        "mode": config.mode,
        "human_player_count": 0,
        "agent_count": config.agents,
        "team_mode": config.mode == "team_2v2",
        "friendly_fire": config.mode != "team_2v2",
        "time_limit": float(config.seconds),
        "score_limit": 0,
        "map_id": map_id or resolve_tactical_map_ids(config)[0],
        "agent_difficulty": "hard",
        "agent_controller": "hybrid",
        "agent_model_id": "hybrid_tactical_v1",
        "reward_profile_id": config.reward_profile_id,
        "random_seed": int(seed),
        "headless": True,
        "record_replay": False,
        "training_fast_mode": False,
        "training_spawn_policy": config.training_spawn_policy,
    }
    if config.opponent_controller == "scripted":
        if config.agents != 2:
            raise ValueError("scripted-opponent tactical PPO requires exactly two agents")
        match_config.update(
            {
                "agent_controller": "scripted",
                "agent_controller_overrides": {"0": "hybrid"},
                "agent_model_id_overrides": {"0": "hybrid_tactical_v1"},
            }
        )
    elif config.opponent_controller != "self_play":
        raise ValueError(f"Unknown opponent_controller: {config.opponent_controller}")
    return match_config


PROFILE_REWARD_COMPONENTS = frozenset(
    {
        "legal_window_damage",
        "legal_window_commitment",
        "actionable_window_entry",
        "authorized_projectile_cost",
        "missed_legal_window",
        "avoidable_override",
        "efficient_damage",
        "unfavorable_exchange",
        "positive_score_margin",
    }
)

MOVEMENT_MODE_NAMES = (
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
)

FIRE_MODE_NAMES = (
    "HOLD_FIRE",
    "CONSERVATIVE",
    "NORMAL",
    "BURST",
    "ALL_IN",
    "USE_SCRIPTED_FIRE_MODE",
)