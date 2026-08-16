"""Backward-compatible shim. See :mod:`training.core.bc` for the implementation."""
from training.core.bc import (
    TacticalBehaviorCloneConfig,
    compute_loss,
    evaluate,
    load_episode_ids,
    make_loader,
    masked_argmax,
    masked_cross_entropy,
    plot_metrics,
    split_data,
    train_tactical_behavior_clone,
    weighted_mean,
    write_metrics_csv,
)

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