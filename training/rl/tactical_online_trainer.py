from __future__ import annotations

import json
import math
import random
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable

import numpy as np
import torch

from training.rl.godot_env import GodotStepEnv
from training.rl.tactical_ppo import (
    TACTICAL_HEADS,
    MaskedTacticalPPOTrainer,
    TacticalActionBatch,
    TacticalPPOConfig,
    compute_gae,
    sample_masked_tactical_actions,
)
from training.rl.models import TacticalActorCritic


@dataclass
class TacticalOnlineConfig:
    output_dir: Path
    profile_id: str = "local_constrained"
    stage: str = "01_foundation_combat"
    map_id: str = "dungeon"
    mode: str = "ffa"
    agents: int = 2
    seconds: int = 20
    seed: int = 30000
    rollout_steps: int = 128
    total_env_steps: int = 2048
    tick_skip: int = 4
    hidden: int = 192
    recurrent: bool = True
    rnn_hidden: int | None = None
    lr: float = 3e-4
    ppo_clip_ratio: float = 0.2
    ppo_value_coef: float = 0.5
    ppo_entropy_coef: float = 0.01
    ppo_max_grad_norm: float = 0.5
    ppo_update_epochs: int = 4
    ppo_minibatch_size: int = 1024
    ppo_mixed_precision: bool = True
    device: str | None = None
    godot: str | None = None
    port: int = 8765
    require_cuda: bool = False


def make_tactical_match_config(config: TacticalOnlineConfig, seed: int) -> dict[str, Any]:
    return {
        "mode": config.mode,
        "human_player_count": 0,
        "agent_count": config.agents,
        "team_mode": config.mode == "team_2v2",
        "friendly_fire": config.mode != "team_2v2",
        "time_limit": float(config.seconds),
        "score_limit": 0,
        "map_id": config.map_id,
        "agent_difficulty": "hard",
        "agent_controller": "hybrid",
        "agent_model_id": "hybrid_tactical_v1",
        "random_seed": int(seed),
        "headless": True,
        "record_replay": False,
        "training_fast_mode": False,
    }


def train_tactical_ppo(
    config: TacticalOnlineConfig,
    env_factory: Callable[..., Any] = GodotStepEnv,
) -> dict[str, Any]:
    random.seed(config.seed)
    np.random.seed(config.seed)
    torch.manual_seed(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)
    device = _resolve_device(config)
    config.output_dir.joinpath("config.json").write_text(
        json.dumps(
            {
                **asdict(config),
                "output_dir": str(config.output_dir),
                "device": str(device),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    model = TacticalActorCritic(
        input_dim=142,
        hidden=config.hidden,
        recurrent=config.recurrent,
        rnn_hidden=config.rnn_hidden,
    ).to(device)
    trainer = MaskedTacticalPPOTrainer(
        model,
        TacticalPPOConfig(
            clip_ratio=config.ppo_clip_ratio,
            value_coef=config.ppo_value_coef,
            entropy_coef=config.ppo_entropy_coef,
            max_grad_norm=config.ppo_max_grad_norm,
            update_epochs=config.ppo_update_epochs,
            minibatch_size=config.ppo_minibatch_size,
            lr=config.lr,
            mixed_precision=config.ppo_mixed_precision,
        ),
        device=device,
    )

    env = _make_env(env_factory, config)
    metrics_path = config.output_dir / "metrics.jsonl"
    audit = {
        "tactical_step_calls": 0,
        "raw_step_calls": 0,
        "transitions": 0,
        "episodes": 0,
        "fallback_count": 0,
        "safety_override_count": 0,
        "decision_ids": [],
    }
    best_reward = -math.inf
    env_steps = 0
    update_count = 0
    episode_seed = config.seed
    hidden_by_player: dict[str, torch.Tensor] = {}
    try:
        env.reset(make_tactical_match_config(config, episode_seed))
        snapshot = env.observe_tactical()
        previous_rewards = _reward_totals(snapshot)
        with metrics_path.open("w", encoding="utf-8") as metrics_file:
            while env_steps < config.total_env_steps:
                rollout = _collect_rollout(
                    env,
                    model,
                    snapshot,
                    previous_rewards,
                    hidden_by_player,
                    config,
                    device,
                    min(config.rollout_steps, config.total_env_steps - env_steps),
                    audit,
                )
                if not rollout["transitions"]:
                    raise RuntimeError("Tactical rollout produced no controllable transitions")
                batch = _build_training_batch(rollout, device)
                metrics = trainer.update(batch)
                env_steps += int(rollout["env_steps"])
                update_count += 1
                rollout_reward = float(sum(transition["reward"] for transition in rollout["transitions"]))
                row = {
                    "env_steps": env_steps,
                    "update": update_count,
                    "rollout_reward": rollout_reward,
                    **{f"ppo/{key}": value for key, value in metrics.items()},
                }
                metrics_file.write(json.dumps(row, ensure_ascii=False) + "\n")
                metrics_file.flush()
                print(json.dumps(row, ensure_ascii=False))
                snapshot = rollout["snapshot"]
                previous_rewards = rollout["previous_rewards"]
                hidden_by_player = rollout["hidden_by_player"]
                if rollout["terminated"]:
                    audit["episodes"] += 1
                    episode_seed += 1
                    env.reset(make_tactical_match_config(config, episode_seed))
                    snapshot = env.observe_tactical()
                    previous_rewards = _reward_totals(snapshot)
                    hidden_by_player.clear()
                if rollout_reward > best_reward:
                    best_reward = rollout_reward
                    _save_checkpoint(model, config, device, config.output_dir / "best_tactical_ppo.pt")
        _save_checkpoint(model, config, device, config.output_dir / "last_tactical_ppo.pt")
    finally:
        env.close()

    audit_path = config.output_dir / "rollout_audit.json"
    audit_path.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    return {
        "training": "finished",
        "kind": "tactical_ppo",
        "device": str(device),
        "env_steps": env_steps,
        "updates": update_count,
        "episodes": audit["episodes"],
        "best_rollout_reward": best_reward,
        "checkpoint": str(config.output_dir / "best_tactical_ppo.pt"),
        "metrics": str(metrics_path),
        "rollout_audit": str(audit_path),
    }


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
) -> dict[str, Any]:
    per_player_transitions: dict[str, list[dict[str, Any]]] = {}
    initial_hidden_states: dict[str, torch.Tensor | None] = {}
    next_snapshot = snapshot
    next_rewards = previous_rewards
    total_env_steps = 0
    terminated = False
    for _ in range(steps):
        player_ids = [str(value) for value in next_snapshot.get("info", {}).get("tactical_player_ids", [])]
        if not player_ids:
            break
        features = torch.tensor(
            [next_snapshot["players"][player_id]["tactical_features"] for player_id in player_ids],
            dtype=torch.float32,
            device=device,
        )
        masks = {
            head: torch.tensor(
                [next_snapshot["players"][player_id]["action_masks"][head] for player_id in player_ids],
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
                "masks": {head: masks[head][index].detach().cpu() for head in TACTICAL_HEADS},
                "actions": _slice_action(actions, index),
                "old_log_prob": actions.log_prob[index].detach().cpu(),
                "old_value": outputs["value"][index].detach().cpu(),
                "reward": float(current_rewards.get(player_id, 0.0) - next_rewards.get(player_id, 0.0)),
                "terminated": bool(next_snapshot.get("terminated", False)),
                "truncated": bool(next_snapshot.get("truncated", False)),
                "player_id": player_id,
                "fallback": bool(player_data.get("diagnostics", {}).get("script_fallback", False)),
                "safety_override": bool(player_data.get("diagnostics", {}).get("safety_override", False)),
            }
            per_player_transitions[player_id].append(transition)
            audit["transitions"] += 1
            audit["fallback_count"] += int(transition["fallback"])
            audit["safety_override_count"] += int(transition["safety_override"])
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
        player_ids = [str(value) for value in snapshot.get("info", {}).get("tactical_player_ids", [])]
        if player_ids:
            features = torch.tensor(
                [snapshot["players"][player_id]["tactical_features"] for player_id in player_ids],
                dtype=torch.float32,
                device=device,
            )
            masks = {
                head: torch.tensor(
                    [snapshot["players"][player_id]["action_masks"][head] for player_id in player_ids],
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
        rewards = torch.stack([row["reward"] if isinstance(row["reward"], torch.Tensor) else torch.tensor(row["reward"]) for row in rows])
        values = torch.stack([row["old_value"] for row in rows]).float()
        terminated = torch.tensor([row["terminated"] for row in rows], dtype=torch.bool)
        truncated = torch.tensor([row["truncated"] for row in rows], dtype=torch.bool)
        bootstrap = bootstrap_by_player.get(rows[0]["player_id"], torch.tensor(0.0))
        returns, advantages = compute_gae(rewards, values, terminated, truncated, bootstrap)
        for offset, index in enumerate(range(start, end)):
            results[index] = (returns[offset], advantages[offset])
    return [item for item in results if item is not None]


def _build_training_batch(rollout: dict[str, Any], device: torch.device) -> dict[str, Any]:
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


def _resolve_device(config: TacticalOnlineConfig) -> torch.device:
    if config.device:
        device = torch.device(config.device)
    else:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if config.require_cuda and device.type != "cuda":
        raise RuntimeError("Tactical PPO pilot requires CUDA, but no CUDA device is available")
    return device


def _make_env(env_factory: Callable[..., Any], config: TacticalOnlineConfig) -> Any:
    return env_factory(port=config.port, godot=config.godot)


def _reward_totals(snapshot: dict[str, Any]) -> dict[str, float]:
    return {
        str(player_id): float(player.get("reward_total", 0.0))
        for player_id, player in snapshot.get("players", {}).items()
    }


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


def _actions_to_decisions(
    actions: TacticalActionBatch,
    player_ids: list[str],
    audit: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    decisions: dict[str, dict[str, Any]] = {}
    for index, player_id in enumerate(player_ids):
        decision_id = len(audit["decision_ids"]) + 1
        audit["decision_ids"].append(decision_id)
        decisions[player_id] = {
            "protocol": 2,
            "target_slot": int(actions.target_slot[index].item()),
            "movement_mode": int(actions.movement_mode[index].item()),
            "fire_mode": int(actions.fire_mode[index].item()),
            "skill_mode": int(actions.skill_mode[index].item()),
            "confidence": 1.0,
            "decision_id": decision_id,
        }
    return decisions


def _slice_action(actions: TacticalActionBatch, index: int) -> TacticalActionBatch:
    return TacticalActionBatch(
        target_slot=actions.target_slot[index].detach().cpu(),
        movement_mode=actions.movement_mode[index].detach().cpu(),
        fire_mode=actions.fire_mode[index].detach().cpu(),
        skill_mode=actions.skill_mode[index].detach().cpu(),
        log_prob=actions.log_prob[index].detach().cpu(),
        entropy=actions.entropy[index].detach().cpu(),
    )


def _save_checkpoint(
    model: TacticalActorCritic,
    config: TacticalOnlineConfig,
    device: torch.device,
    path: Path,
) -> None:
    torch.save(
        {
            "model_state": model.state_dict(),
            "config": {
                **asdict(config),
                "output_dir": str(config.output_dir),
                "device": str(device),
            },
            "input_dim": model.input_dim,
        },
        path,
    )
