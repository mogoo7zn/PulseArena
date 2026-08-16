"""Data carriers and head-name tables for the tactical PPO loop."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import torch


TACTICAL_HEADS = (
    "target_slot",
    "movement_mode",
    "fire_mode",
    "skill_mode",
)

_MODEL_HEAD_ATTRS = {
    "target_slot": "target_head",
    "movement_mode": "movement_head",
    "fire_mode": "fire_head",
    "skill_mode": "skill_head",
}

_BC_HEAD_PREFIXES = {
    "target_slot": ("target_head",),
    "movement_mode": ("movement_head",),
    "fire_mode": ("fire_mode_head", "fire_head"),
    "skill_mode": ("skill_mode_head", "skill_head"),
}


@dataclass
class TacticalActionBatch:
    """A sampled tactical action across the four heads with joint log-prob/entropy."""

    target_slot: torch.Tensor
    movement_mode: torch.Tensor
    fire_mode: torch.Tensor
    skill_mode: torch.Tensor
    log_prob: torch.Tensor
    entropy: torch.Tensor

    def as_dict(self) -> dict[str, torch.Tensor]:
        return {
            "target_slot": self.target_slot,
            "movement_mode": self.movement_mode,
            "fire_mode": self.fire_mode,
            "skill_mode": self.skill_mode,
        }


@dataclass
class TacticalPPOConfig:
    clip_ratio: float = 0.2
    value_coef: float = 0.5
    entropy_coef: float = 0.01
    max_grad_norm: float = 0.5
    update_epochs: int = 4
    minibatch_size: int = 1024
    lr: float = 3e-4
    mixed_precision: bool = True
    target_kl: float | None = None