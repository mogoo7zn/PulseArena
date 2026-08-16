"""Generalized advantage estimation (GAE) for the tactical PPO loop."""
from __future__ import annotations

import torch


def compute_gae(
    rewards: torch.Tensor,
    values: torch.Tensor,
    terminated: torch.Tensor,
    truncated: torch.Tensor,
    bootstrap_value: torch.Tensor | float,
    gamma: float = 0.99,
    gae_lambda: float = 0.95,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Compute GAE returns and advantages with proper terminal bootstrap semantics."""
    if rewards.ndim != 1 or values.ndim != 1:
        raise ValueError("GAE expects one-dimensional rewards and values")
    if rewards.shape != values.shape or rewards.shape != terminated.shape or rewards.shape != truncated.shape:
        raise ValueError("GAE inputs must have the same shape")
    if rewards.numel() == 0:
        return rewards.clone(), rewards.clone()

    bootstrap = torch.as_tensor(bootstrap_value, dtype=values.dtype, device=values.device)
    advantages = torch.zeros_like(rewards)
    gae = torch.zeros((), dtype=values.dtype, device=values.device)
    next_value = bootstrap
    for index in range(rewards.numel() - 1, -1, -1):
        terminal = terminated[index].to(dtype=torch.bool)
        timeout = truncated[index].to(dtype=torch.bool)
        bootstrap_allowed = (~terminal).to(values.dtype)
        trace_continues = (~(terminal | timeout)).to(values.dtype)
        delta = rewards[index] + gamma * next_value * bootstrap_allowed - values[index]
        gae = delta + gamma * gae_lambda * trace_continues * gae
        advantages[index] = gae
        next_value = values[index]
    return advantages + values, advantages