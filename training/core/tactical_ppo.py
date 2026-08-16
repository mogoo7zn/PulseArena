"""Backward-compatible shim. See :mod:`training.core.ppo` for the implementation."""
from training.core.models.tactical import TacticalActorCritic
from training.core.ppo import (
    MaskedTacticalPPOTrainer,
    TACTICAL_HEADS,
    TacticalActionBatch,
    TacticalPPOConfig,
    compute_gae,
    sample_masked_tactical_actions,
    tactical_log_prob_and_entropy,
)

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