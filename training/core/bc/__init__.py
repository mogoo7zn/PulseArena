"""Tactical behavior cloning training pipeline."""
from training.core.bc.config import TacticalBehaviorCloneConfig
from training.core.bc.dataset import load_episode_ids, make_loader, split_data
from training.core.bc.losses import (
    compute_loss,
    evaluate,
    masked_argmax,
    masked_cross_entropy,
    weighted_mean,
)
from training.core.bc.reporting import plot_metrics, write_metrics_csv
from training.core.bc.trainer import train_tactical_behavior_clone

__all__ = [
    "TacticalBehaviorCloneConfig",
    "compute_loss",
    "evaluate",
    "load_episode_ids",
    "make_loader",
    "masked_argmax",
    "masked_cross_entropy",
    "plot_metrics",
    "split_data",
    "train_tactical_behavior_clone",
    "weighted_mean",
    "write_metrics_csv",
]