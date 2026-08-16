"""Rollout collection and GAE return/advantage computation for online PPO."""
from __future__ import annotations

from typing import Any

import torch

from training.core.models import TacticalActorCritic
from training.core.online.config import TacticalOnlineConfig
from training.core.online.decoders import (
    _actions_to_decisions,
    _reward_totals,
    _slice_action,
)
from training.core.ppo.advantages import compute_gae
from training.core.ppo.sampling import sample_masked_tactical_actions
from training.core.ppo.types import TACTICAL_HEADS


def _stack_hidden_states(
    hidden_by_player: dict[str, torch.Tensor],
    player_ids: list[str],
    model: TacticalActorCritic,
    device: torch.device,
) -> torch.Tensor | None:
    if not model.recurrent:
        return None
    zeros = torch.zeros(
        model.rnn.num_layers,
        len(player_ids),
        model.rnn.hidden_size,
        device=device,
    )
    for index, player_id in enumerate(player_ids):
        if player_id in hidden_by_player:
            zeros[:, index : index + 1] = hidden_by_player[player_id].to(device)
    return zeros


def _collect_rollout(
    env: Any,
    model: TacticalActorCritic,
    snapshot: dict[str, Any],
    previous_rewards: dict[str, float],
    hidden_by_player: dict[str, torch.Tensor],
    config: TacticalOnlineConfig,
    device: torch.device,
    steps: int,
    audit: dict[str, Any],
    map_id: str,
) -> dict[str, Any]:
    from training.core.online.audit import update_transition_audit

    per_player_transitions: dict[str, list[dict[str, Any]]] = {}
    initial_hidden_states: dict[str, torch.Tensor | None] = {}
    next_snapshot = snapshot
    next_rewards = previous_rewards
    total_env_steps = 0
    terminated = False
    for _ in range(steps):
        player_ids = [
            str(value)
            for value in next_snapshot.get("info", {}).get("tactical_player_ids", [])
        ]
        if not player_ids:
            break
        features = torch.tensor(
            [
                next_snapshot["players"][player_id]["tactical_features"]
                for player_id in player_ids
            ],
            dtype=torch.float32,
            device=device,
        )
        masks = {
            head: torch.tensor(
                [
                    next_snapshot["players"][player_id]["action_masks"][head]
                    for player_id in player_ids
                ],
                dtype=torch.bool,
                device=device,
            )
            for head in TACTICAL_HEADS
        }
        hidden_inputs = _stack_hidden_states(hidden_by_player, player_ids, model, device)
        with torch.no_grad():
            outputs = model(features, hidden_inputs)
            actions = sample_masked_tactical_actions(outputs, masks)
        decisions = _actions_to_decisions(actions, player_ids, audit)
        next_snapshot = env.step_tactical(decisions, ticks=config.tick_skip)
        audit["tactical_step_calls"] += 1
        current_rewards = _reward_totals(next_snapshot)
        next_hidden = outputs.get("hidden_state")
        if isinstance(next_hidden, torch.Tensor):
            for index, player_id in enumerate(player_ids):
                hidden_by_player[player_id] = next_hidden[:, index : index + 1].detach()
        for index, player_id in enumerate(player_ids):
            if player_id not in per_player_transitions:
                per_player_transitions[player_id] = []
                initial_hidden_states[player_id] = (
                    hidden_inputs[:, index : index + 1].detach()
                    if isinstance(hidden_inputs, torch.Tensor)
                    else None
                )
            player_data = next_snapshot["players"][player_id]
            transition = {
                "features": features[index].detach().cpu(),
                "masks": {
                    head: masks[head][index].detach().cpu() for head in TACTICAL_HEADS
                },
                "actions": _slice_action(actions, index),
                "old_log_prob": actions.log_prob[index].detach().cpu(),
                "old_value": outputs["value"][index].detach().cpu(),
                "reward": float(
                    current_rewards.get(player_id, 0.0) - next_rewards.get(player_id, 0.0)
                ),
                "terminated": bool(next_snapshot.get("terminated", False)),
                "truncated": bool(next_snapshot.get("truncated", False)),
                "player_id": player_id,
                "fallback": bool(player_data.get("diagnostics", {}).get("script_fallback", False)),
                "safety_override": bool(
                    player_data.get("diagnostics", {}).get("safety_override", False)
                ),
            }
            per_player_transitions[player_id].append(transition)
            update_transition_audit(audit, player_id, player_data, map_id=map_id)
        next_rewards = current_rewards
        total_env_steps += config.tick_skip
        terminated = bool(next_snapshot.get("terminated", False))
        if terminated:
            break

    transitions: list[dict[str, Any]] = []
    sequence_boundaries: list[tuple[int, int]] = []
    sequence_hidden_states: list[torch.Tensor | None] = []
    for player_id in sorted(per_player_transitions, key=lambda value: int(value)):
        start = len(transitions)
        transitions.extend(per_player_transitions[player_id])
        sequence_boundaries.append((start, len(transitions)))
        sequence_hidden_states.append(initial_hidden_states[player_id])
    sequence_boundaries = [
        boundary for boundary in sequence_boundaries if boundary[1] > boundary[0]
    ]
    returns_by_transition = _compute_rollout_returns(
        transitions,
        sequence_boundaries,
        next_snapshot,
        model,
        hidden_by_player,
        device,
    )
    for transition, (return_value, advantage) in zip(transitions, returns_by_transition):
        transition["return"] = return_value
        transition["advantage"] = advantage
    return {
        "transitions": transitions,
        "sequence_boundaries": sequence_boundaries,
        "sequence_hidden_states": sequence_hidden_states,
        "snapshot": next_snapshot,
        "previous_rewards": next_rewards,
        "hidden_by_player": hidden_by_player,
        "env_steps": total_env_steps,
        "terminated": terminated,
    }


def _compute_rollout_returns(
    transitions: list[dict[str, Any]],
    sequence_boundaries: list[tuple[int, int]],
    snapshot: dict[str, Any],
    model: TacticalActorCritic,
    hidden_by_player: dict[str, torch.Tensor],
    device: torch.device,
) -> list[tuple[torch.Tensor, torch.Tensor]]:
    results: list[tuple[torch.Tensor, torch.Tensor] | None] = [None] * len(transitions)
    bootstrap_by_player: dict[str, torch.Tensor] = {}
    if not snapshot.get("terminated", False):
        player_ids = [
            str(value)
            for value in snapshot.get("info", {}).get("tactical_player_ids", [])
        ]
        if player_ids:
            features = torch.tensor(
                [
                    snapshot["players"][player_id]["tactical_features"]
                    for player_id in player_ids
                ],
                dtype=torch.float32,
                device=device,
            )
            masks = {
                head: torch.tensor(
                    [
                        snapshot["players"][player_id]["action_masks"][head]
                        for player_id in player_ids
                    ],
                    dtype=torch.bool,
                    device=device,
                )
                for head in TACTICAL_HEADS
            }
            hidden = _stack_hidden_states(hidden_by_player, player_ids, model, device)
            with torch.no_grad():
                outputs = model(features, hidden)
            for index, player_id in enumerate(player_ids):
                bootstrap_by_player[player_id] = outputs["value"][index].detach().cpu()
    for start, end in sequence_boundaries:
        rows = transitions[start:end]
        rewards = torch.stack(
            [
                row["reward"] if isinstance(row["reward"], torch.Tensor)
                else torch.tensor(row["reward"])
                for row in rows
            ]
        )
        values = torch.stack([row["old_value"] for row in rows]).float()
        terminated = torch.tensor([row["terminated"] for row in rows], dtype=torch.bool)
        truncated = torch.tensor([row["truncated"] for row in rows], dtype=torch.bool)
        bootstrap = bootstrap_by_player.get(rows[0]["player_id"], torch.tensor(0.0))
        returns, advantages = compute_gae(rewards, values, terminated, truncated, bootstrap)
        for offset, index in enumerate(range(start, end)):
            results[index] = (returns[offset], advantages[offset])
    return [item for item in results if item is not None]


def _build_training_batch(rollout: dict[str, Any], device: torch.device) -> dict[str, Any]:
    from training.core.ppo.types import TacticalActionBatch

    transitions = rollout["transitions"]
    actions = TacticalActionBatch(
        target_slot=torch.stack([row["actions"].target_slot for row in transitions]).long(),
        movement_mode=torch.stack([row["actions"].movement_mode for row in transitions]).long(),
        fire_mode=torch.stack([row["actions"].fire_mode for row in transitions]).long(),
        skill_mode=torch.stack([row["actions"].skill_mode for row in transitions]).long(),
        log_prob=torch.stack([row["actions"].log_prob for row in transitions]).float(),
        entropy=torch.stack([row["actions"].entropy for row in transitions]).float(),
    )
    return {
        "features": torch.stack([row["features"] for row in transitions]).to(device),
        "masks": {
            head: torch.stack([row["masks"][head] for row in transitions]).to(device)
            for head in TACTICAL_HEADS
        },
        "actions": actions,
        "old_log_probs": torch.stack([row["old_log_prob"] for row in transitions]).to(device),
        "old_values": torch.stack([row["old_value"] for row in transitions]).to(device),
        "returns": torch.stack([row["return"] for row in transitions]).to(device),
        "advantages": torch.stack([row["advantage"] for row in transitions]).to(device),
        "sequence_boundaries": rollout["sequence_boundaries"],
        "sequence_hidden_states": rollout["sequence_hidden_states"],
    }