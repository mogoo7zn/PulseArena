from __future__ import annotations

import json
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch

from training.rl.encoding import flatten_observation
from training.rl.godot_env import GodotStepEnv
from training.rl.models import ActorCriticNet
from training.rl.ppo import PPOBatch, PPOHyperParams, PPOTrainer, action_log_prob_and_entropy
from training.rl import swanlab_utils


@dataclass
class OnlinePPOConfig:
    output_dir: Path
    profile_id: str
    stage: str
    map_id: str
    mode: str
    agents: int
    seconds: int
    seed: int
    rollout_steps: int
    total_env_steps: int
    tick_skip: int = 4
    hidden: int = 256
    rnn_hidden: int = 128
    value_hidden: int = 256
    swanlab_mode: str = "disabled"
    swanlab_project: str = "pulsearena-online"
    run_name: str = "online_ppo"
    port: int = 8765


def make_match_config(config: OnlinePPOConfig, seed: int) -> dict[str, Any]:
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
        "random_seed": int(seed),
        "headless": True,
        "record_replay": False,
        "training_fast_mode": False,
    }


def tensor_to_action_dict(action: torch.Tensor) -> dict[str, Any]:
    values = action.detach().cpu().float().tolist()
    return {
        "move_x": float(np.clip(values[0], -1.0, 1.0)),
        "move_y": float(np.clip(values[1], -1.0, 1.0)),
        "aim_x": float(np.clip(values[2], -1.0, 1.0)),
        "aim_y": float(np.clip(values[3], -1.0, 1.0)),
        "shoot": values[4] > 0.5,
        "dash": values[5] > 0.5,
        "shield": values[6] > 0.5,
    }


@torch.no_grad()
def sample_actions(model: ActorCriticNet, obs_by_player: dict[str, Any], device: torch.device) -> tuple[dict[str, Any], list[torch.Tensor], list[torch.Tensor], list[torch.Tensor], list[torch.Tensor]]:
    player_ids = sorted(obs_by_player.keys(), key=lambda value: int(value))
    obs_rows = [flatten_observation(obs_by_player[player_id]) for player_id in player_ids]
    obs_tensor = torch.tensor(obs_rows, dtype=torch.float32, device=device)
    logits, values, _ = model(obs_tensor)
    means = torch.tanh(logits[:, 0:4])
    continuous_dist = torch.distributions.Normal(means, model.log_std.exp().expand_as(means))
    continuous = continuous_dist.sample().clamp(-1.0, 1.0)
    button_dist = torch.distributions.Bernoulli(logits=logits[:, 4:7])
    buttons = button_dist.sample()
    actions_tensor = torch.cat([continuous, buttons], dim=-1)
    log_probs, _entropy = action_log_prob_and_entropy(logits, model.log_std, actions_tensor)
    actions = {player_id: tensor_to_action_dict(actions_tensor[index]) for index, player_id in enumerate(player_ids)}
    return actions, list(obs_tensor.cpu()), list(actions_tensor.cpu()), list(log_probs.cpu()), list(values.reshape(-1).cpu())


def train_online_ppo(config: OnlinePPOConfig, ppo_params: PPOHyperParams) -> dict[str, Any]:
    random.seed(config.seed)
    np.random.seed(config.seed)
    torch.manual_seed(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    # Observation dim is stable; build it from an empty-ish reset observation at runtime.
    env_steps = 0
    updates = 0
    best_reward = -math.inf
    start = time.perf_counter()
    swan = swanlab_utils.init_swanlab(
        config.swanlab_mode,
        config.swanlab_project,
        config.run_name,
        config.output_dir / "swanlab",
        {"profile_id": config.profile_id, "stage": config.stage, "total_env_steps": config.total_env_steps},
    )
    use_swan = swan is not None and config.swanlab_mode != "disabled"

    with GodotStepEnv(port=config.port) as env:
        response = env.reset(make_match_config(config, config.seed))
        first_obs = next(iter(response["observations"].values()))
        input_dim = len(flatten_observation(first_obs))
        model = ActorCriticNet(input_dim, hidden=config.hidden, rnn_hidden=config.rnn_hidden, value_hidden=config.value_hidden).to(device)
        trainer = PPOTrainer(model, ppo_params, device=device)
        previous_rewards = {str(key): float(value) for key, value in response.get("rewards", {}).items()}
        episode_seed = config.seed
        while env_steps < config.total_env_steps:
            obs_rows: list[torch.Tensor] = []
            action_rows: list[torch.Tensor] = []
            log_prob_rows: list[torch.Tensor] = []
            value_rows: list[torch.Tensor] = []
            reward_rows: list[float] = []
            rollout_reward = 0.0
            for _ in range(config.rollout_steps):
                observations = response["observations"]
                actions, obs_t, act_t, logp_t, value_t = sample_actions(model, observations, device)
                response = env.step(actions, ticks=config.tick_skip)
                current_rewards = {str(key): float(value) for key, value in response.get("rewards", {}).items()}
                for player_id, obs_item, action_item, logp_item, value_item in zip(sorted(observations.keys(), key=lambda value: int(value)), obs_t, act_t, logp_t, value_t):
                    reward_delta = current_rewards.get(str(player_id), 0.0) - previous_rewards.get(str(player_id), 0.0)
                    obs_rows.append(obs_item)
                    action_rows.append(action_item)
                    log_prob_rows.append(logp_item)
                    value_rows.append(value_item)
                    reward_rows.append(reward_delta)
                    rollout_reward += reward_delta
                previous_rewards = current_rewards
                env_steps += config.tick_skip
                if response.get("terminated", False):
                    episode_seed += 1
                    response = env.reset(make_match_config(config, episode_seed))
                    previous_rewards = {str(key): float(value) for key, value in response.get("rewards", {}).items()}
                if env_steps >= config.total_env_steps:
                    break
            rewards = torch.tensor(reward_rows, dtype=torch.float32)
            old_values = torch.stack(value_rows).float()
            returns = rewards
            advantages = rewards - old_values
            batch = PPOBatch(
                observations=torch.stack(obs_rows).float(),
                actions=torch.stack(action_rows).float(),
                old_log_probs=torch.stack(log_prob_rows).float(),
                returns=returns,
                advantages=advantages,
                old_values=old_values,
            )
            metrics = trainer.update(batch)
            updates += 1
            row = {"online/env_steps": float(env_steps), "online/update": float(updates), "online/rollout_reward": rollout_reward, **{f"ppo/{k}": v for k, v in metrics.items()}}
            swanlab_utils.log(row, env_steps, use_swan)
            print(json.dumps(row, ensure_ascii=False))
            if rollout_reward > best_reward:
                best_reward = rollout_reward
                torch.save({"model_state": model.state_dict(), "config": config.__dict__, "input_dim": input_dim}, config.output_dir / "best_online_policy.pt")
        torch.save({"model_state": model.state_dict(), "config": config.__dict__, "input_dim": input_dim}, config.output_dir / "last_online_policy.pt")
    total_seconds = time.perf_counter() - start
    swanlab_utils.log({"online/total_seconds": total_seconds, "online/best_rollout_reward": best_reward}, env_steps + 1, use_swan)
    swanlab_utils.finish(use_swan)
    return {
        "online_training": "finished",
        "device": str(device),
        "env_steps": env_steps,
        "updates": updates,
        "total_seconds": total_seconds,
        "best_rollout_reward": best_reward,
        "checkpoint": str(config.output_dir / "best_online_policy.pt"),
    }
