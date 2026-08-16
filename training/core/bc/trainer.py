"""Top-level tactical behavior cloning trainer."""
from __future__ import annotations

import json
import math
import random
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch

from training.core import swanlab_utils
from training.core.bc.config import TacticalBehaviorCloneConfig
from training.core.bc.dataset import load_episode_ids, make_loader, split_data
from training.core.bc.losses import compute_loss, evaluate
from training.core.bc.reporting import plot_metrics, write_metrics_csv
from training.core.encoding import load_hybrid_replay_arrays
from training.core.models import TacticalPolicyNet
from training.core.training.replay_quality import build_episode_split


def train_tactical_behavior_clone(config: TacticalBehaviorCloneConfig) -> dict[str, Any]:
    random.seed(config.seed)
    np.random.seed(config.seed)
    torch.manual_seed(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)

    data = load_hybrid_replay_arrays(
        config.replay_dir, config.max_samples, decision_key=config.decision_key
    )
    episode_ids = load_episode_ids(data.files, config.max_samples)
    train_dataset, val_dataset = split_data(data, config.val_ratio, config.seed, episode_ids)
    episode_split = build_episode_split(
        ({"episode_id": episode_id} for episode_id in episode_ids),
        config.val_ratio,
        config.seed,
    )
    train_loader = make_loader(train_dataset, config.batch_size, shuffle=True)
    val_loader = make_loader(val_dataset, config.batch_size, shuffle=False)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = TacticalPolicyNet(data.feature_dim, hidden=config.hidden).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=config.lr, weight_decay=1e-4)
    scaler = torch.amp.GradScaler("cuda", enabled=device.type == "cuda")

    swan_config = {
        "samples": int(len(data.tactical_features)),
        "train_samples": int(len(train_dataset)),
        "val_samples": int(len(val_dataset)),
        "train_episode_count": len(episode_split["train"]),
        "val_episode_count": len(episode_split["dev"]),
        "split_strategy": "episode_group",
        "input_dim": data.feature_dim,
        "device": str(device),
        "epochs": config.epochs,
        "batch_size": config.batch_size,
        "hidden": config.hidden,
        "lr": config.lr,
        "decision_key": config.decision_key,
        "mean_label_weight": float(data.label_weights.mean()),
        "min_label_weight": float(data.label_weights.min()),
        "mean_confidence_target": float(data.confidence_targets.mean()),
        "trainer": "mask_aware_tactical_bc_v2",
        "replay_files": [str(path) for path in data.files],
    }
    swan_run = swanlab_utils.init_swanlab(
        config.swanlab_mode,
        config.swanlab_project,
        config.run_name,
        config.output_dir / "swanlab",
        swan_config,
    )
    use_swanlab = swan_run is not None and config.swanlab_mode != "disabled"

    history: list[dict[str, float]] = []
    best_val = math.inf
    start_time = time.perf_counter()
    for epoch in range(1, config.epochs + 1):
        epoch_start = time.perf_counter()
        model.train()
        seen = 0
        train_sums = {
            "loss": 0.0,
            "target_loss": 0.0,
            "movement_loss": 0.0,
            "fire_loss": 0.0,
            "skill_loss": 0.0,
            "confidence_loss": 0.0,
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
        ) in train_loader:
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
            optimizer.zero_grad(set_to_none=True)
            with torch.amp.autocast("cuda", enabled=device.type == "cuda"):
                outputs = model(xb)
                loss, parts = compute_loss(outputs, labels, masks, weights, confidence_targets)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            batch = xb.shape[0]
            seen += batch
            train_sums["loss"] += float(loss.detach()) * batch
            for key, value in parts.items():
                train_sums[key] += float(value.detach()) * batch
        train_metrics = {key: value / max(seen, 1) for key, value in train_sums.items()}
        val_metrics = evaluate(model, val_loader, device)
        row = {
            "epoch": float(epoch),
            "train/loss": train_metrics["loss"],
            "train/target_loss": train_metrics["target_loss"],
            "train/movement_loss": train_metrics["movement_loss"],
            "train/fire_loss": train_metrics["fire_loss"],
            "train/skill_loss": train_metrics["skill_loss"],
            "train/confidence_loss": train_metrics["confidence_loss"],
            "val/loss": val_metrics["loss"],
            "val/target_acc": val_metrics["target_acc"],
            "val/movement_acc": val_metrics["movement_acc"],
            "val/fire_acc": val_metrics["fire_acc"],
            "val/skill_acc": val_metrics["skill_acc"],
            "epoch_seconds": time.perf_counter() - epoch_start,
        }
        history.append(row)
        swanlab_utils.log(row, epoch, use_swanlab)
        print(json.dumps(row, ensure_ascii=False))
        if val_metrics["loss"] < best_val:
            best_val = val_metrics["loss"]
            torch.save(
                {
                    "model_state": model.state_dict(),
                    "config": swan_config,
                    "input_dim": data.feature_dim,
                },
                config.output_dir / "best_tactical_policy.pt",
            )

    total_seconds = time.perf_counter() - start_time
    write_metrics_csv(config.output_dir / "metrics.csv", history)
    plot_metrics(config.output_dir / "metrics.png", history)
    torch.save(
        {
            "model_state": model.state_dict(),
            "config": swan_config,
            "input_dim": data.feature_dim,
        },
        config.output_dir / "last_tactical_policy.pt",
    )
    swanlab_utils.log(
        {"run/total_seconds": total_seconds, "run/best_val_loss": best_val},
        config.epochs + 1,
        use_swanlab,
    )
    swanlab_utils.finish(use_swanlab)
    return {
        "training": "finished",
        "kind": "tactical_policy",
        "device": str(device),
        "samples": int(len(data.tactical_features)),
        "train_samples": int(len(train_dataset)),
        "val_samples": int(len(val_dataset)),
        "train_episode_count": len(episode_split["train"]),
        "val_episode_count": len(episode_split["dev"]),
        "split_strategy": "episode_group",
        "epochs": config.epochs,
        "total_seconds": total_seconds,
        "best_val_loss": best_val,
        "metrics_csv": str(config.output_dir / "metrics.csv"),
        "metrics_png": str(config.output_dir / "metrics.png"),
        "checkpoint": str(config.output_dir / "best_tactical_policy.pt"),
        "swanlab_dir": str(config.output_dir / "swanlab"),
    }