"""Masked tactical PPO trainer."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Iterable

import torch
from torch import nn

from training.core.models import TacticalActorCritic
from training.core.ppo.advantages import compute_gae
from training.core.ppo.sampling import tactical_log_prob_and_entropy
from training.core.ppo.types import (
    _BC_HEAD_PREFIXES,
    _MODEL_HEAD_ATTRS,
    TACTICAL_HEADS,
    TacticalActionBatch,
    TacticalPPOConfig,
)


class MaskedTacticalPPOTrainer:
    """PPO trainer with per-head masking for the tactical protocol."""

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
        loaded.update(self._load_bc_encoder(state))
        for head in TACTICAL_HEADS:
            weight_key = ""
            bias_key = ""
            for source_prefix in _BC_HEAD_PREFIXES[head]:
                candidate_weight = f"{source_prefix}.weight"
                candidate_bias = f"{source_prefix}.bias"
                if candidate_weight in state and candidate_bias in state:
                    weight_key = candidate_weight
                    bias_key = candidate_bias
                    break
            if weight_key not in state or bias_key not in state:
                raise ValueError(f"BC checkpoint is missing {head} actor head")
            target = getattr(self.model, _MODEL_HEAD_ATTRS[head])
            if (
                tuple(state[weight_key].shape) != tuple(target.weight.shape)
                or tuple(state[bias_key].shape) != tuple(target.bias.shape)
            ):
                raise ValueError(f"BC checkpoint {head} head shape does not match tactical actor")
            target.load_state_dict({"weight": state[weight_key], "bias": state[bias_key]})
            loaded[head] = "loaded"
        return loaded

    def _load_bc_encoder(self, state: dict[str, Any]) -> dict[str, str]:
        mapping = {
            "trunk.0.weight": "encoder.0.weight",
            "trunk.0.bias": "encoder.0.bias",
            "trunk.1.weight": "encoder.1.weight",
            "trunk.1.bias": "encoder.1.bias",
            "trunk.3.weight": "encoder.3.weight",
            "trunk.3.bias": "encoder.3.bias",
        }
        model_state = self.model.state_dict()
        if not all(source in state and target in model_state for source, target in mapping.items()):
            return {}
        if any(
            tuple(state[source].shape) != tuple(model_state[target].shape)
            for source, target in mapping.items()
        ):
            return {}
        patch = dict(model_state)
        for source, target in mapping.items():
            patch[target] = state[source]
        self.model.load_state_dict(patch)
        return {"encoder": "loaded"}

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
                    log_probs, entropy = tactical_log_prob_and_entropy(
                        outputs, _slice_masks(masks, index), _slice_actions(actions, index)
                    )
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


def _slice_masks(masks: dict[str, torch.Tensor], index: torch.Tensor) -> dict[str, torch.Tensor]:
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