"""Backward-compatible shim. See :mod:`training.core.models` for the implementation."""
from training.core.models import (
    ActorCriticNet,
    BehaviorPolicyNet,
    TacticalActorCritic,
    TacticalPolicyNet,
)

__all__ = [
    "ActorCriticNet",
    "BehaviorPolicyNet",
    "TacticalActorCritic",
    "TacticalPolicyNet",
]