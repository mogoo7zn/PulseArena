"""Top-level orchestration of the tactical PPO online training loop."""
from __future__ import annotations

import json
import math
import random
from dataclasses import asdict
from typing import Any, Callable

import numpy as np
import torch

from training.core.env.godot_step import GodotStepEnv
from training.core.models import TacticalActorCritic
from training.core.online.audit import initial_rollout_audit
from training.core.online.audit_helpers import _increment_audit_counter
from training.core.online.config import (
    SUPPORTED_MAP_IDS,
    TacticalOnlineConfig,
    make_tactical_match_config,
    resolve_tactical_map_ids,
)
from training.core.online.decoders import _reward_totals
from training.core.online.rollout import (
    _build_training_batch,
    _collect_rollout,
)
from training.core.online.runtime import (
    _load_resume_checkpoint,
    _make_env,
    _resolve_device,
    _save_checkpoint,
)
from training.core.ppo import MaskedTacticalPPOTrainer, TacticalPPOConfig


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
                "bc_checkpoint": str(config.bc_checkpoint) if config.bc_checkpoint is not None else None,
                "resume_checkpoint": str(config.resume_checkpoint) if config.resume_checkpoint is not None else None,
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
    bc_warm_start = ""
    resume_checkpoint = ""
    if config.resume_checkpoint is not None:
        payload = _load_resume_checkpoint(model, config.resume_checkpoint)
        resume_checkpoint = str(config.resume_checkpoint)
        bc_warm_start = str(
            payload.get("bc_warm_start") or payload.get("config", {}).get("bc_checkpoint") or ""
        )
    elif config.bc_checkpoint is not None:
        trainer.load_bc_checkpoint(config.bc_checkpoint)
        bc_warm_start = str(config.bc_checkpoint)

    env = _make_env(env_factory, config)
    metrics_path = config.output_dir / "metrics.jsonl"
    audit = initial_rollout_audit(config.reward_profile_id)
    best_reward = -math.inf
    env_steps = 0
    update_count = 0
    map_ids = resolve_tactical_map_ids(config)
    episode_seed = config.seed
    episode_index = 0
    current_map_id = map_ids[episode_index % len(map_ids)]
    hidden_by_player: dict[str, torch.Tensor] = {}
    try:
        env.reset(make_tactical_match_config(config, episode_seed, current_map_id))
        _increment_audit_counter(audit, "map_episode_counts", current_map_id, 1)
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
                    current_map_id,
                )
                if not rollout["transitions"]:
                    raise RuntimeError("Tactical rollout produced no controllable transitions")
                batch = _build_training_batch(rollout, device)
                metrics = trainer.update(batch)
                env_steps += int(rollout["env_steps"])
                update_count += 1
                rollout_reward = float(
                    sum(transition["reward"] for transition in rollout["transitions"])
                )
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
                if rollout["terminated"] and env_steps < config.total_env_steps:
                    audit["episodes"] += 1
                    episode_seed += 1
                    episode_index += 1
                    current_map_id = map_ids[episode_index % len(map_ids)]
                    env.reset(make_tactical_match_config(config, episode_seed, current_map_id))
                    _increment_audit_counter(audit, "map_episode_counts", current_map_id, 1)
                    snapshot = env.observe_tactical()
                    previous_rewards = _reward_totals(snapshot)
                    hidden_by_player.clear()
                if rollout_reward > best_reward:
                    best_reward = rollout_reward
                    _save_checkpoint(
                        model,
                        config,
                        device,
                        config.output_dir / "best_tactical_ppo.pt",
                        bc_warm_start=bc_warm_start,
                        resume_checkpoint=resume_checkpoint,
                    )
        _save_checkpoint(
            model,
            config,
            device,
            config.output_dir / "last_tactical_ppo.pt",
            bc_warm_start=bc_warm_start,
            resume_checkpoint=resume_checkpoint,
        )
    finally:
        env.close()

    audit_path = config.output_dir / "rollout_audit.json"
    persisted_audit = {
        key: value for key, value in audit.items() if not key.startswith("_")
    }
    audit_path.write_text(
        json.dumps(persisted_audit, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return {
        "training": "finished",
        "kind": "tactical_ppo",
        "device": str(device),
        "env_steps": env_steps,
        "updates": update_count,
        "episodes": audit["episodes"],
        "best_rollout_reward": best_reward,
        "bc_warm_start": bc_warm_start,
        "resume_checkpoint": resume_checkpoint,
        "checkpoint": str(config.output_dir / "best_tactical_ppo.pt"),
        "metrics": str(metrics_path),
        "rollout_audit": str(audit_path),
    }


def _increment_audit_counter(
    audit: dict[str, Any], public_key: str, counter_key: str, amount: int | float
) -> None:
    counters = audit.setdefault(public_key, {})
    counters[counter_key] = counters.get(counter_key, 0) + amount


__all__ = [
    "SUPPORTED_MAP_IDS",
    "TacticalOnlineConfig",
    "initial_rollout_audit",
    "make_tactical_match_config",
    "resolve_tactical_map_ids",
    "train_tactical_ppo",
]