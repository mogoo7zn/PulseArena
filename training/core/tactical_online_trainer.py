"""Backward-compatible shim. See :mod:`training.core.online` for the implementation."""
from training.core.online import (
    PROFILE_REWARD_COMPONENTS,
    SUPPORTED_MAP_IDS,
    TacticalOnlineConfig,
    _collect_rollout,
    _load_resume_checkpoint,
    _save_checkpoint,
    _update_cumulative_audit,
    initial_rollout_audit,
    make_tactical_match_config,
    resolve_tactical_map_ids,
    train_tactical_ppo,
    update_transition_audit,
)

__all__ = [
    "PROFILE_REWARD_COMPONENTS",
    "SUPPORTED_MAP_IDS",
    "TacticalOnlineConfig",
    "_collect_rollout",
    "_load_resume_checkpoint",
    "_save_checkpoint",
    "_update_cumulative_audit",
    "initial_rollout_audit",
    "make_tactical_match_config",
    "resolve_tactical_map_ids",
    "train_tactical_ppo",
    "update_transition_audit",
]