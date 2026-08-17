"""Masked categorical sampling + log-prob/entropy helpers for the tactical heads."""
from __future__ import annotations

from typing import Any

import torch

from training.core.ppo.types import TACTICAL_HEADS, TacticalActionBatch


STRENGTH_PROFILES: dict[str, dict[str, float]] = {
    "easy":    {"temperature": 1.6, "mask_soften": 0.30, "safety_override_threshold": 0.55},
    "casual":  {"temperature": 1.1, "mask_soften": 0.20, "safety_override_threshold": 0.65},
    "normal":  {"temperature": 0.85, "mask_soften": 0.10, "safety_override_threshold": 0.75},
    "strong":  {"temperature": 0.55, "mask_soften": 0.05, "safety_override_threshold": 0.85},
    "elite":   {"temperature": 0.25, "mask_soften": 0.0,  "safety_override_threshold": 0.95},
}
DEFAULT_STRENGTH = "normal"


def resolve_strength_profile(strength: str | None) -> dict[str, float]:
    """Map a strength name (or None) to its inference parameter dict."""
    if strength is None:
        return dict(STRENGTH_PROFILES[DEFAULT_STRENGTH])
    if strength not in STRENGTH_PROFILES:
        raise ValueError(
            f"Unknown strength profile {strength!r}; expected one of {sorted(STRENGTH_PROFILES)}"
        )
    return dict(STRENGTH_PROFILES[strength])


def _masked_distribution(
    logits: torch.Tensor,
    mask: torch.Tensor | list,
    temperature: float = 1.0,
    mask_soften: float = 0.0,
) -> torch.distributions.Categorical:
    if not isinstance(mask, torch.Tensor):
        mask = torch.as_tensor(mask)
    legal = mask.to(device=logits.device, dtype=torch.bool)
    if logits.dim() == 1:
        legal = legal.unsqueeze(0)
        logits = logits.unsqueeze(0)
    elif logits.dim() == 2 and legal.dim() == 1:
        # Mask is missing the batch dimension; broadcast it across the batch.
        legal = legal.unsqueeze(0).expand(logits.shape[0], -1)
    if logits.shape != legal.shape:
        raise ValueError(
            f"Mask shape {tuple(legal.shape)} does not match logits {tuple(logits.shape)}"
        )
    if not torch.all(legal.any(dim=-1)):
        raise ValueError("Every tactical action head must have at least one legal action")
    if temperature <= 0.0:
        raise ValueError(f"temperature must be > 0; got {temperature}")
    if temperature != 1.0:
        logits = logits / temperature
    if mask_soften > 0.0:
        illegal_penalty = mask_soften * logits.masked_fill(legal, torch.finfo(logits.dtype).min).masked_fill(~legal, 0.0).max(dim=-1, keepdim=True).values
        illegal_logits = torch.finfo(logits.dtype).min
        logits = torch.where(legal, logits, illegal_logits + illegal_penalty)
    masked_logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
    return torch.distributions.Categorical(logits=masked_logits)


def sample_masked_tactical_actions(
    outputs: dict[str, torch.Tensor | None],
    masks: dict[str, torch.Tensor],
    deterministic: bool = False,
    temperature: float = 1.0,
    mask_soften: float = 0.0,
) -> TacticalActionBatch:
    """Sample a joint action across the four tactical heads, respecting masks."""
    actions: dict[str, torch.Tensor] = {}
    log_probs: list[torch.Tensor] = []
    entropies: list[torch.Tensor] = []
    for head in TACTICAL_HEADS:
        logits = outputs[head]
        if not isinstance(logits, torch.Tensor):
            raise ValueError(f"Missing logits for tactical head {head}")
        distribution = _masked_distribution(logits, masks[head], temperature=temperature, mask_soften=mask_soften)
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


def sample_with_strength_profile(
    outputs: dict[str, torch.Tensor | None],
    masks: dict[str, torch.Tensor],
    strength: str | None,
    deterministic: bool = False,
) -> TacticalActionBatch:
    """Convenience wrapper: pick a strength profile, then sample."""
    profile = resolve_strength_profile(strength)
    return sample_masked_tactical_actions(
        outputs,
        masks,
        deterministic=deterministic,
        temperature=profile["temperature"],
        mask_soften=profile["mask_soften"],
    )


def tactical_log_prob_and_entropy(
    outputs: dict[str, torch.Tensor | None],
    masks: dict[str, torch.Tensor],
    actions: TacticalActionBatch,
    temperature: float = 1.0,
    mask_soften: float = 0.0,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Recompute the joint log-prob/entropy of a previously sampled action."""
    log_probs: list[torch.Tensor] = []
    entropies: list[torch.Tensor] = []
    action_dict = actions.as_dict()
    for head in TACTICAL_HEADS:
        logits = outputs[head]
        if not isinstance(logits, torch.Tensor):
            raise ValueError(f"Missing logits for tactical head {head}")
        distribution = _masked_distribution(logits, masks[head], temperature=temperature, mask_soften=mask_soften)
        log_probs.append(distribution.log_prob(action_dict[head]))
        entropies.append(distribution.entropy())
    return (
        torch.stack(log_probs, dim=0).sum(dim=0),
        torch.stack(entropies, dim=0).sum(dim=0),
    )