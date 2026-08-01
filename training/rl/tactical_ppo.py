from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import torch
from torch import nn

from training.rl.models import TacticalActorCritic


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
    "target_slot": "target_head",
    "movement_mode": "movement_head",
    "fire_mode": "fire_mode_head",
    "skill_mode": "skill_mode_head",
}


@dataclass
class TacticalActionBatch:
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
    return torch.stack(log_probs, dim=0).sum(dim=0), torch.stack(entropies, dim=0).sum(dim=0)


def compute_gae(
    rewards: torch.Tensor,
    values: torch.Tensor,
    terminated: torch.Tensor,
    truncated: torch.Tensor,
    bootstrap_value: torch.Tensor | float,
    gamma: float = 0.99,
    gae_lambda: float = 0.95,
) -> tuple[torch.Tensor, torch.Tensor]:
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


class MaskedTacticalPPOTrainer:
    def __init__(
        self,
        model: TacticalActorCritic,
        config: TacticalPPOConfig | None = None,
        device: torch.device | None = None,
    ) -> None:
        self.model = model
        self.config = config or TacticalPPOConfig()
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self.model.to(self.device)
        self.optimizer = torch.optim.AdamW(
            self.model.parameters(),
            lr=self.config.lr,
            weight_decay=1e-4,
        )
        self.scaler = torch.amp.GradScaler(
            "cuda",
            enabled=self.config.mixed_precision and self.device.type == "cuda",
        )

    def load_bc_checkpoint(self, checkpoint: str | Path | dict[str, Any]) -> dict[str, str]:
        payload = (
            torch.load(checkpoint, map_location="cpu", weights_only=False)
            if isinstance(checkpoint, (str, Path))
            else checkpoint
        )
        input_dim = int(payload.get("input_dim", payload.get("config", {}).get("input_dim", -1)))
        if input_dim != self.model.input_dim:
            raise ValueError(
                f"BC checkpoint input_dim {input_dim} does not match {self.model.input_dim}"
            )
        state = payload.get("model_state", payload.get("state_dict", payload))
        loaded: dict[str, str] = {}
        for head in TACTICAL_HEADS:
            source_prefix = _BC_HEAD_PREFIXES[head]
            weight_key = f"{source_prefix}.weight"
            bias_key = f"{source_prefix}.bias"
            if weight_key not in state or bias_key not in state:
                raise ValueError(f"BC checkpoint is missing {head} actor head")
            target = getattr(self.model, _MODEL_HEAD_ATTRS[head])
            if tuple(state[weight_key].shape) != tuple(target.weight.shape) or tuple(state[bias_key].shape) != tuple(target.bias.shape):
                raise ValueError(f"BC checkpoint {head} head shape does not match tactical actor")
            target.load_state_dict({"weight": state[weight_key], "bias": state[bias_key]})
            loaded[head] = "loaded"
        return loaded

    def update(self, batch: dict[str, Any]) -> dict[str, float]:
        features = batch["features"].to(self.device)
        masks = {
            head: batch["masks"][head].to(self.device)
            for head in TACTICAL_HEADS
        }
        actions = _actions_to_device(batch["actions"], self.device)
        old_log_probs = batch["old_log_probs"].to(self.device)
        returns = batch["returns"].to(self.device)
        advantages = batch["advantages"].to(self.device)
        old_values = batch["old_values"].to(self.device)
        sequence_hidden_states = batch.get("sequence_hidden_states")
        advantages = (advantages - advantages.mean()) / (advantages.std(unbiased=False) + 1e-8)

        totals = {
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
            "approx_kl": 0.0,
            "clip_fraction": 0.0,
        }
        seen = 0
        for _ in range(self.config.update_epochs):
            for indices, sequence_mode, sequence_number in self._minibatches(
                features.shape[0],
                batch.get("sequence_boundaries"),
            ):
                self.optimizer.zero_grad(set_to_none=True)
                index = indices.to(self.device)
                model_features = features[index].unsqueeze(0) if sequence_mode else features[index]
                hidden_state = None
                if sequence_mode and sequence_hidden_states is not None and sequence_number is not None:
                    hidden_state = sequence_hidden_states[sequence_number]
                    if hidden_state is not None:
                        hidden_state = hidden_state.to(self.device)
                with torch.amp.autocast(
                    "cuda",
                    enabled=self.config.mixed_precision and self.device.type == "cuda",
                ):
                    outputs = self.model(model_features, hidden_state)
                    if sequence_mode:
                        outputs = _flatten_sequence_outputs(outputs)
                    log_probs, entropy = tactical_log_prob_and_entropy(outputs, _slice_masks(masks, index), _slice_actions(actions, index))
                    values = outputs["value"]
                    if not isinstance(values, torch.Tensor):
                        raise ValueError("Tactical actor-critic did not return values")
                    ratio = torch.exp(log_probs - old_log_probs[index])
                    unclipped = ratio * advantages[index]
                    clipped = torch.clamp(
                        ratio,
                        1.0 - self.config.clip_ratio,
                        1.0 + self.config.clip_ratio,
                    ) * advantages[index]
                    policy_loss = -torch.min(unclipped, clipped).mean()
                    value_clipped = old_values[index] + torch.clamp(
                        values - old_values[index],
                        -self.config.clip_ratio,
                        self.config.clip_ratio,
                    )
                    value_loss = torch.max(
                        (values - returns[index]).pow(2),
                        (value_clipped - returns[index]).pow(2),
                    ).mean()
                    entropy_mean = entropy.mean()
                    loss = (
                        policy_loss
                        + self.config.value_coef * value_loss
                        - self.config.entropy_coef * entropy_mean
                    )
                self.scaler.scale(loss).backward()
                self.scaler.unscale_(self.optimizer)
                nn.utils.clip_grad_norm_(self.model.parameters(), self.config.max_grad_norm)
                self.scaler.step(self.optimizer)
                self.scaler.update()

                batch_size = int(index.numel())
                seen += batch_size
                with torch.no_grad():
                    approx_kl = torch.clamp(
                        0.5 * (old_log_probs[index] - log_probs).pow(2).mean(),
                        min=0.0,
                    )
                    clip_fraction = (
                        (ratio - 1.0).abs() > self.config.clip_ratio
                    ).to(torch.float32).mean()
                totals["policy_loss"] += float(policy_loss.detach()) * batch_size
                totals["value_loss"] += float(value_loss.detach()) * batch_size
                totals["entropy"] += float(entropy_mean.detach()) * batch_size
                totals["approx_kl"] += float(approx_kl.detach()) * batch_size
                totals["clip_fraction"] += float(clip_fraction.detach()) * batch_size
                if self.config.target_kl is not None and float(approx_kl) > self.config.target_kl:
                    break
        return {key: value / max(seen, 1) for key, value in totals.items()}

    def _minibatches(
        self,
        size: int,
        sequence_boundaries: Iterable[tuple[int, int]] | None,
    ) -> list[tuple[torch.Tensor, bool, int | None]]:
        if self.model.recurrent and sequence_boundaries:
            boundaries = list(sequence_boundaries)
            order = torch.randperm(len(boundaries))
            return [
                (
                    torch.arange(
                        boundaries[int(position)][0],
                        boundaries[int(position)][1],
                        dtype=torch.long,
                    ),
                    True,
                    int(position),
                )
                for position in order
            ]
        order = torch.randperm(size)
        return [
            (chunk, False, None)
            for chunk in order.split(max(1, self.config.minibatch_size))
            if chunk.numel()
        ]


def _actions_to_device(actions: TacticalActionBatch, device: torch.device) -> TacticalActionBatch:
    return TacticalActionBatch(
        target_slot=actions.target_slot.to(device),
        movement_mode=actions.movement_mode.to(device),
        fire_mode=actions.fire_mode.to(device),
        skill_mode=actions.skill_mode.to(device),
        log_prob=actions.log_prob.to(device),
        entropy=actions.entropy.to(device),
    )


def _slice_actions(actions: TacticalActionBatch, index: torch.Tensor) -> TacticalActionBatch:
    return TacticalActionBatch(
        target_slot=actions.target_slot[index],
        movement_mode=actions.movement_mode[index],
        fire_mode=actions.fire_mode[index],
        skill_mode=actions.skill_mode[index],
        log_prob=actions.log_prob[index],
        entropy=actions.entropy[index],
    )


def _slice_masks(
    masks: dict[str, torch.Tensor],
    index: torch.Tensor,
) -> dict[str, torch.Tensor]:
    return {head: masks[head][index] for head in TACTICAL_HEADS}


def _flatten_sequence_outputs(
    outputs: dict[str, torch.Tensor | None],
) -> dict[str, torch.Tensor | None]:
    flattened = dict(outputs)
    for head in TACTICAL_HEADS:
        logits = flattened[head]
        if isinstance(logits, torch.Tensor):
            flattened[head] = logits.reshape(-1, logits.shape[-1])
    values = flattened["value"]
    if isinstance(values, torch.Tensor):
        flattened["value"] = values.reshape(-1)
    return flattened
