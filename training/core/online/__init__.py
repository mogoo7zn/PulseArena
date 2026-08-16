"""Tactical PPO online training pipeline."""
from training.core.online.audit import (
    initial_rollout_audit,
    update_transition_audit,
)
from training.core.online.audit_helpers import _update_cumulative_audit
from training.core.online.config import (
    FIRE_MODE_NAMES,
    MOVEMENT_MODE_NAMES,
    PROFILE_REWARD_COMPONENTS,
    SUPPORTED_MAP_IDS,
    TacticalOnlineConfig,
    make_tactical_match_config,
    resolve_tactical_map_ids,
)
from training.core.online.decoders import (
    _actions_to_decisions,
    _reward_totals,
    _slice_action,
)
from training.core.online.rollout import (
    _build_training_batch,
    _collect_rollout,
    _compute_rollout_returns,
    _stack_hidden_states,
)
from training.core.online.runtime import (
    _load_resume_checkpoint,
    _save_checkpoint,
)
from training.core.online.trainer import train_tactical_ppo

__all__ = [
    "FIRE_MODE_NAMES",
    "MOVEMENT_MODE_NAMES",
    "PROFILE_REWARD_COMPONENTS",
    "SUPPORTED_MAP_IDS",
    "TacticalOnlineConfig",
    "_actions_to_decisions",
    "_build_training_batch",
    "_collect_rollout",
    "_compute_rollout_returns",
    "_load_resume_checkpoint",
    "_reward_totals",
    "_save_checkpoint",
    "_slice_action",
    "_stack_hidden_states",
    "_update_cumulative_audit",
    "initial_rollout_audit",
    "make_tactical_match_config",
    "resolve_tactical_map_ids",
    "train_tactical_ppo",
    "update_transition_audit",
]