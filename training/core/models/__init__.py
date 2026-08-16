"""Neural network architectures for the training pipeline."""
from training.core.models.architectures import ActorCriticNet, BehaviorPolicyNet
from training.core.models.tactical import TacticalActorCritic, TacticalPolicyNet

__all__ = [
    "ActorCriticNet",
    "BehaviorPolicyNet",
    "TacticalActorCritic",
    "TacticalPolicyNet",
]