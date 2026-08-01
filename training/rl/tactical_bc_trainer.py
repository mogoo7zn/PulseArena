from __future__ import annotations

import csv
import json
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from training.rl import swanlab_utils
from training.rl.encoding import HybridReplayArrays, load_hybrid_replay_arrays
from training.rl.models import TacticalPolicyNet
from training.server_agent.tactical_data_quality import build_episode_split, episode_group_id


@dataclass
class TacticalBehaviorCloneConfig:
    replay_dir: Path
    output_dir: Path
    epochs: int = 40
    batch_size: int = 1024
    hidden: int = 192
    lr: float = 3e-4
    val_ratio: float = 0.2
    seed: int = 20260708
    max_samples: int | None = None
    decision_key: str = "teacher_decision"
    swanlab_mode: str = "offline"
    swanlab_project: str = "pulsearena-hybrid"
    run_name: str = "hybrid_tactical_bc"


def split_data(data: HybridReplayArrays, val_ratio: float, seed: int, episode_ids: list[str]) -> tuple[TensorDataset, TensorDataset]:
    if len(episode_ids) != len(data.tactical_features):
        raise ValueError("episode_ids must align one-to-one with tactical replay rows")
    split = build_episode_split(({"episode_id": episode_id} for episode_id in episode_ids), val_ratio, seed)
    train_idx = np.asarray([index for index, episode_id in enumerate(episode_ids) if episode_id in split["train"]], dtype=np.int64)
    val_idx = np.asarray([index for index, episode_id in enumerate(episode_ids) if episode_id in split["dev"]], dtype=np.int64)
    if not len(train_idx) or not len(val_idx):
        raise ValueError("episode group split requires at least two episodes and a positive validation ratio")
    train = TensorDataset(
        torch.from_numpy(data.tactical_features[train_idx]),
        torch.from_numpy(data.target_slots[train_idx]),
        torch.from_numpy(data.movement_modes[train_idx]),
        torch.from_numpy(data.fire_modes[train_idx]),
        torch.from_numpy(data.skill_modes[train_idx]),
        torch.from_numpy(data.target_masks[train_idx]),
        torch.from_numpy(data.movement_masks[train_idx]),
        torch.from_numpy(data.fire_masks[train_idx]),
        torch.from_numpy(data.skill_masks[train_idx]),
        torch.from_numpy(data.label_weights[train_idx]),
        torch.from_numpy(data.confidence_targets[train_idx]),
    )
    val = TensorDataset(
        torch.from_numpy(data.tactical_features[val_idx]),
        torch.from_numpy(data.target_slots[val_idx]),
        torch.from_numpy(data.movement_modes[val_idx]),
        torch.from_numpy(data.fire_modes[val_idx]),
        torch.from_numpy(data.skill_modes[val_idx]),
        torch.from_numpy(data.target_masks[val_idx]),
        torch.from_numpy(data.movement_masks[val_idx]),
        torch.from_numpy(data.fire_masks[val_idx]),
        torch.from_numpy(data.skill_masks[val_idx]),
        torch.from_numpy(data.label_weights[val_idx]),
        torch.from_numpy(data.confidence_targets[val_idx]),
    )
    return train, val


def load_episode_ids(files: list[Path], max_samples: int | None) -> list[str]:
    """Read the episode identity in the exact order used by the replay loader."""
    episode_ids: list[str] = []
    for path in files:
        with path.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("replay_schema") != "hybrid_replay_v2":
                    continue
                episode_ids.append(episode_group_id(row, line_number))
                if max_samples is not None and len(episode_ids) >= max_samples:
                    return episode_ids
    return episode_ids


def make_loader(dataset: TensorDataset, batch_size: int, shuffle: bool) -> DataLoader:
    return DataLoader(dataset, batch_size=batch_size, shuffle=shuffle, drop_last=False, pin_memory=torch.cuda.is_available())


def weighted_mean(values: torch.Tensor, weights: torch.Tensor) -> torch.Tensor:
    weights = weights.to(values.dtype)
    return (values * weights).sum() / weights.sum().clamp_min(1e-6)


def masked_cross_entropy(logits: torch.Tensor, target: torch.Tensor, mask: torch.Tensor, weights: torch.Tensor) -> torch.Tensor:
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
def evaluate(model: TacticalPolicyNet, loader: DataLoader, device: torch.device) -> dict[str, float]:
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
    for xb, target, movement, fire, skill, target_mask, movement_mask, fire_mask, skill_mask, weights, confidence_targets in loader:
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
        sums["target_acc"] += float(weighted_mean((masked_argmax(outputs["target_slot"], masks[0]) == labels[0]).float(), weights)) * batch
        sums["movement_acc"] += float(weighted_mean((masked_argmax(outputs["movement_mode"], masks[1]) == labels[1]).float(), weights)) * batch
        sums["fire_acc"] += float(weighted_mean((masked_argmax(outputs["fire_mode"], masks[2]) == labels[2]).float(), weights)) * batch
        sums["skill_acc"] += float(weighted_mean((masked_argmax(outputs["skill_mode"], masks[3]) == labels[3]).float(), weights)) * batch
    return {key: value / max(total, 1) for key, value in sums.items()}


def write_metrics_csv(path: Path, history: list[dict[str, float]]) -> None:
    if not history:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(history[0].keys()))
        writer.writeheader()
        writer.writerows(history)


def plot_metrics(path: Path, history: list[dict[str, float]]) -> None:
    if not history:
        return
    epochs = [row["epoch"] for row in history]
    fig, axes = plt.subplots(2, 2, figsize=(11, 7))
    axes[0, 0].plot(epochs, [row["train/loss"] for row in history], label="train")
    axes[0, 0].plot(epochs, [row["val/loss"] for row in history], label="val")
    axes[0, 0].set_title("Loss")
    axes[0, 0].legend()
    axes[0, 1].plot(epochs, [row["val/target_acc"] for row in history], label="target")
    axes[0, 1].plot(epochs, [row["val/movement_acc"] for row in history], label="movement")
    axes[0, 1].plot(epochs, [row["val/fire_acc"] for row in history], label="fire")
    axes[0, 1].plot(epochs, [row["val/skill_acc"] for row in history], label="skill")
    axes[0, 1].set_title("Head Accuracy")
    axes[0, 1].legend()
    axes[1, 0].plot(epochs, [row["train/target_loss"] for row in history], label="target")
    axes[1, 0].plot(epochs, [row["train/movement_loss"] for row in history], label="movement")
    axes[1, 0].plot(epochs, [row["train/fire_loss"] for row in history], label="fire")
    axes[1, 0].plot(epochs, [row["train/skill_loss"] for row in history], label="skill")
    axes[1, 0].set_title("Train Head Loss")
    axes[1, 0].legend()
    axes[1, 1].plot(epochs, [row["epoch_seconds"] for row in history], label="seconds")
    axes[1, 1].set_title("Epoch Time")
    axes[1, 1].legend()
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def train_tactical_behavior_clone(config: TacticalBehaviorCloneConfig) -> dict[str, Any]:
    random.seed(config.seed)
    np.random.seed(config.seed)
    torch.manual_seed(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)

    data = load_hybrid_replay_arrays(config.replay_dir, config.max_samples, decision_key=config.decision_key)
    episode_ids = load_episode_ids(data.files, config.max_samples)
    train_dataset, val_dataset = split_data(data, config.val_ratio, config.seed, episode_ids)
    episode_split = build_episode_split(({"episode_id": episode_id} for episode_id in episode_ids), config.val_ratio, config.seed)
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
        train_sums = {"loss": 0.0, "target_loss": 0.0, "movement_loss": 0.0, "fire_loss": 0.0, "skill_loss": 0.0, "confidence_loss": 0.0}
        for xb, target, movement, fire, skill, target_mask, movement_mask, fire_mask, skill_mask, weights, confidence_targets in train_loader:
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
            torch.save({"model_state": model.state_dict(), "config": swan_config, "input_dim": data.feature_dim}, config.output_dir / "best_tactical_policy.pt")

    total_seconds = time.perf_counter() - start_time
    write_metrics_csv(config.output_dir / "metrics.csv", history)
    plot_metrics(config.output_dir / "metrics.png", history)
    torch.save({"model_state": model.state_dict(), "config": swan_config, "input_dim": data.feature_dim}, config.output_dir / "last_tactical_policy.pt")
    swanlab_utils.log({"run/total_seconds": total_seconds, "run/best_val_loss": best_val}, config.epochs + 1, use_swanlab)
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
