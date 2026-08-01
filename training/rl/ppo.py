from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from training.rl.models import ActorCriticNet


@dataclass
class PPOHyperParams:
    clip_ratio: float = 0.2
    value_coef: float = 0.5
    entropy_coef: float = 0.01
    max_grad_norm: float = 0.5
    update_epochs: int = 4
    minibatch_size: int = 1024
    lr: float = 3e-4
    mixed_precision: bool = True


@dataclass
class PPOBatch:
    observations: torch.Tensor
    actions: torch.Tensor
    old_log_probs: torch.Tensor
    returns: torch.Tensor
    advantages: torch.Tensor
    old_values: torch.Tensor


def action_log_prob_and_entropy(logits: torch.Tensor, log_std: torch.Tensor, actions: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    continuous_mean = torch.tanh(logits[:, 0:4])
    continuous_dist = torch.distributions.Normal(continuous_mean, log_std.exp().expand_as(continuous_mean))
    continuous_log_prob = continuous_dist.log_prob(actions[:, 0:4]).sum(dim=-1)
    continuous_entropy = continuous_dist.entropy().sum(dim=-1)

    button_dist = torch.distributions.Bernoulli(logits=logits[:, 4:7])
    button_log_prob = button_dist.log_prob(actions[:, 4:7]).sum(dim=-1)
    button_entropy = button_dist.entropy().sum(dim=-1)
    return continuous_log_prob + button_log_prob, continuous_entropy + button_entropy


class PPOTrainer:
    def __init__(self, model: ActorCriticNet, params: PPOHyperParams, device: torch.device | None = None) -> None:
        self.model = model
        self.params = params
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self.model.to(self.device)
        self.optimizer = torch.optim.AdamW(self.model.parameters(), lr=params.lr, weight_decay=1e-4)
        self.scaler = torch.amp.GradScaler("cuda", enabled=params.mixed_precision and self.device.type == "cuda")

    def update(self, batch: PPOBatch) -> dict[str, float]:
        observations = batch.observations.to(self.device)
        actions = batch.actions.to(self.device)
        old_log_probs = batch.old_log_probs.to(self.device)
        returns = batch.returns.to(self.device)
        advantages = batch.advantages.to(self.device)
        old_values = batch.old_values.to(self.device)
        advantages = (advantages - advantages.mean()) / (advantages.std(unbiased=False) + 1e-8)

        dataset = TensorDataset(observations, actions, old_log_probs, returns, advantages, old_values)
        loader = DataLoader(dataset, batch_size=self.params.minibatch_size, shuffle=True, drop_last=False)
        totals: dict[str, float] = {
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
            "approx_kl": 0.0,
            "clip_fraction": 0.0,
        }
        seen = 0
        for _ in range(self.params.update_epochs):
            for obs_mb, act_mb, old_logp_mb, ret_mb, adv_mb, old_value_mb in loader:
                obs_mb = obs_mb.to(self.device, non_blocking=True)
                act_mb = act_mb.to(self.device, non_blocking=True)
                old_logp_mb = old_logp_mb.to(self.device, non_blocking=True)
                ret_mb = ret_mb.to(self.device, non_blocking=True)
                adv_mb = adv_mb.to(self.device, non_blocking=True)
                old_value_mb = old_value_mb.to(self.device, non_blocking=True)
                self.optimizer.zero_grad(set_to_none=True)
                with torch.amp.autocast("cuda", enabled=self.params.mixed_precision and self.device.type == "cuda"):
                    logits, values, _ = self.model(obs_mb)
                    if values.dim() > 1:
                        values = values.reshape(-1)
                    log_probs, entropy = action_log_prob_and_entropy(logits, self.model.log_std, act_mb)
                    ratio = torch.exp(log_probs - old_logp_mb)
                    unclipped = ratio * adv_mb
                    clipped = torch.clamp(ratio, 1.0 - self.params.clip_ratio, 1.0 + self.params.clip_ratio) * adv_mb
                    policy_loss = -torch.min(unclipped, clipped).mean()
                    value_clipped = old_value_mb + torch.clamp(values - old_value_mb, -self.params.clip_ratio, self.params.clip_ratio)
                    value_loss = torch.max((values - ret_mb).pow(2), (value_clipped - ret_mb).pow(2)).mean()
                    entropy_loss = entropy.mean()
                    loss = policy_loss + self.params.value_coef * value_loss - self.params.entropy_coef * entropy_loss
                self.scaler.scale(loss).backward()
                self.scaler.unscale_(self.optimizer)
                nn.utils.clip_grad_norm_(self.model.parameters(), self.params.max_grad_norm)
                self.scaler.step(self.optimizer)
                self.scaler.update()

                batch_size = int(obs_mb.shape[0])
                seen += batch_size
                with torch.no_grad():
                    approx_kl = (old_logp_mb - log_probs).mean()
                    clip_fraction = ((ratio - 1.0).abs() > self.params.clip_ratio).float().mean()
                totals["policy_loss"] += float(policy_loss.detach()) * batch_size
                totals["value_loss"] += float(value_loss.detach()) * batch_size
                totals["entropy"] += float(entropy_loss.detach()) * batch_size
                totals["approx_kl"] += float(approx_kl.detach()) * batch_size
                totals["clip_fraction"] += float(clip_fraction.detach()) * batch_size
        return {key: value / max(seen, 1) for key, value in totals.items()}


def hyperparams_from_profile(profile: dict[str, Any]) -> PPOHyperParams:
    algo = profile.get("algorithm", {})
    return PPOHyperParams(
        update_epochs=int(algo.get("update_epochs", 4)),
        minibatch_size=int(algo.get("minibatch_size", 1024)),
        mixed_precision=bool(algo.get("mixed_precision", True)),
    )
