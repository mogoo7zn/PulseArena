"""Masked tactical PPO trainer."""
from training.core.models.tactical import TacticalActorCritic  # re-export for backward compat
from training.core.ppo.advantages import compute_gae
from training.core.ppo.sampling import (
    sample_masked_tactical_actions,
    tactical_log_prob_and_entropy,
)
from training.core.ppo.trainer import MaskedTacticalPPOTrainer
from training.core.ppo.types import TACTICAL_HEADS, TacticalActionBatch, TacticalPPOConfig

__all__ = [
    "MaskedTacticalPPOTrainer",
    "TACTICAL_HEADS",
    "TacticalActionBatch",
    "TacticalActorCritic",
    "TacticalPPOConfig",
    "compute_gae",
    "sample_masked_tactical_actions",
    "tactical_log_prob_and_entropy",
]