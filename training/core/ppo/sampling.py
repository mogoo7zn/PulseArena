"""Masked categorical sampling + log-prob/entropy helpers for the tactical heads."""
from __future__ import annotations

from typing import Any

import torch

from training.core.ppo.types import TACTICAL_HEADS, TacticalActionBatch


def _masked_distribution(logits: torch.Tensor, mask: torch.Tensor) -> torch.distributions.Categorical:
    if logits.shape != mask.shape:
        raise ValueError(
            f"Mask shape {tuple(mask.shape)} does not match logits {tuple(logits.shape)}"
        )
    legal = mask.to(device=logits.device, dtype=torch.bool)
    if logits.dim() == 1:
        legal = legal.unsqueeze(0)
        logits = logits.unsqueeze(0)
    if not torch.all(legal.any(dim=-1)):
        raise ValueError("Every tactical action head must have at least one legal action")
    masked_logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
    return torch.distributions.Categorical(logits=masked_logits)


def sample_masked_tactical_actions(
    outputs: dict[str, torch.Tensor | None],
    masks: dict[str, torch.Tensor],
    deterministic: bool = False,
) -> TacticalActionBatch:
    """Sample a joint action across the four tactical heads, respecting masks."""
    actions: dict[str, torch.Tensor] = {}
    log_probs: list[torch.Tensor] = []
    entropies: list[torch.Tensor] = []
    for head in TACTICAL_HEADS:
        logits = outputs[head]
        if not isinstance(logits, torch.Tensor):
            raise ValueError(f"Missing logits for tactical head {head}")
        distribution = _masked_distribution(logits, masks[head])
        action = distribution.probs.argmax(dim=-1) if deterministic else distribution.sample()
        actions[head] = action
        log_probs.append(distribution.log_prob(action))
        entropies.append(distribution.entropy())
    return TacticalActionBatch(
        target_slot=actions["target_slot"],
        movement_mode=actions["movement_mode"],
        fire_mode=actions["fire_mode"],
        skill_mode=actions["skill_mode"],
        log_prob=torch.stack(log_probs, dim=0).sum(dim=0),
        entropy=torch.stack(entropies, dim=0).sum(dim=0),
    )


def tactical_log_prob_and_entropy(
    outputs: dict[str, torch.Tensor | None],
    masks: dict[str, torch.Tensor],
    actions: TacticalActionBatch,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Recompute the joint log-prob/entropy of a previously sampled action."""
    log_probs: list[torch.Tensor] = []
    entropies: list[torch.Tensor] = []
    action_dict = actions.as_dict()
    for head in TACTICAL_HEADS:
        logits = outputs[head]
        if not isinstance(logits, torch.Tensor):
            raise ValueError(f"Missing logits for tactical head {head}")
        distribution = _masked_distribution(logits, masks[head])
        log_probs.append(distribution.log_prob(action_dict[head]))
        entropies.append(distribution.entropy())
    return (
        torch.stack(log_probs, dim=0).sum(dim=0),
        torch.stack(entropies, dim=0).sum(dim=0),
    )