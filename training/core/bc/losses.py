"""Masked cross-entropy loss + evaluation metrics for tactical BC."""
from __future__ import annotations

import torch
from torch import nn
from torch.utils.data import DataLoader

from training.core.models import TacticalPolicyNet


def weighted_mean(values: torch.Tensor, weights: torch.Tensor) -> torch.Tensor:
    weights = weights.to(values.dtype)
    return (values * weights).sum() / weights.sum().clamp_min(1e-6)


def masked_cross_entropy(
    logits: torch.Tensor,
    target: torch.Tensor,
    mask: torch.Tensor,
    weights: torch.Tensor,
) -> torch.Tensor:
    legal = mask.to(dtype=torch.bool, device=logits.device)
    masked_logits = logits.masked_fill(~legal, -1e4)
    losses = nn.functional.cross_entropy(masked_logits, target, reduction="none")
    return weighted_mean(losses, weights)


def masked_argmax(logits: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    legal = mask.to(dtype=torch.bool, device=logits.device)
    masked_logits = logits.masked_fill(~legal, -1e4)
    return masked_logits.argmax(dim=1)


def compute_loss(
    outputs: dict[str, torch.Tensor],
    labels: tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor],
    masks: tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor],
    weights: torch.Tensor,
    confidence_targets: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    target, movement, fire, skill = labels
    target_mask, movement_mask, fire_mask, skill_mask = masks
    target_loss = masked_cross_entropy(outputs["target_slot"], target, target_mask, weights)
    movement_loss = masked_cross_entropy(outputs["movement_mode"], movement, movement_mask, weights)
    fire_loss = masked_cross_entropy(outputs["fire_mode"], fire, fire_mask, weights)
    skill_loss = masked_cross_entropy(outputs["skill_mode"], skill, skill_mask, weights)
    confidence_loss = weighted_mean((outputs["confidence"] - confidence_targets).pow(2), weights)
    loss = target_loss + movement_loss + fire_loss + skill_loss + 0.1 * confidence_loss
    return loss, {
        "target_loss": target_loss,
        "movement_loss": movement_loss,
        "fire_loss": fire_loss,
        "skill_loss": skill_loss,
        "confidence_loss": confidence_loss,
    }


@torch.no_grad()
def evaluate(
    model: TacticalPolicyNet, loader: DataLoader, device: torch.device
) -> dict[str, float]:
    model.eval()
    total = 0
    sums = {
        "loss": 0.0,
        "target_loss": 0.0,
        "movement_loss": 0.0,
        "fire_loss": 0.0,
        "skill_loss": 0.0,
        "confidence_loss": 0.0,
        "target_acc": 0.0,
        "movement_acc": 0.0,
        "fire_acc": 0.0,
        "skill_acc": 0.0,
    }
    for (
        xb,
        target,
        movement,
        fire,
        skill,
        target_mask,
        movement_mask,
        fire_mask,
        skill_mask,
        weights,
        confidence_targets,
    ) in loader:
        xb = xb.to(device, non_blocking=True)
        labels = (
            target.to(device, non_blocking=True),
            movement.to(device, non_blocking=True),
            fire.to(device, non_blocking=True),
            skill.to(device, non_blocking=True),
        )
        masks = (
            target_mask.to(device, non_blocking=True),
            movement_mask.to(device, non_blocking=True),
            fire_mask.to(device, non_blocking=True),
            skill_mask.to(device, non_blocking=True),
        )
        weights = weights.to(device, non_blocking=True)
        confidence_targets = confidence_targets.to(device, non_blocking=True)
        outputs = model(xb)
        loss, parts = compute_loss(outputs, labels, masks, weights, confidence_targets)
        batch = xb.shape[0]
        total += batch
        sums["loss"] += float(loss.detach()) * batch
        for key, value in parts.items():
            sums[key] += float(value.detach()) * batch
        sums["target_acc"] += float(
            weighted_mean((masked_argmax(outputs["target_slot"], masks[0]) == labels[0]).float(), weights)
        ) * batch
        sums["movement_acc"] += float(
            weighted_mean(
                (masked_argmax(outputs["movement_mode"], masks[1]) == labels[1]).float(),
                weights,
            )
        ) * batch
        sums["fire_acc"] += float(
            weighted_mean((masked_argmax(outputs["fire_mode"], masks[2]) == labels[2]).float(), weights)
        ) * batch
        sums["skill_acc"] += float(
            weighted_mean((masked_argmax(outputs["skill_mode"], masks[3]) == labels[3]).float(), weights)
        ) * batch
    return {key: value / max(total, 1) for key, value in sums.items()}