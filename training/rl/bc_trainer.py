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

from training.rl.encoding import ReplayArrays, load_replay_arrays
from training.rl.models import BehaviorPolicyNet
from training.rl import swanlab_utils


@dataclass
class BehaviorCloneConfig:
    replay_dir: Path
    output_dir: Path
    epochs: int = 20
    batch_size: int = 512
    hidden: int = 256
    lr: float = 3e-4
    val_ratio: float = 0.2
    seed: int = 20260627
    max_samples: int | None = None
    swanlab_mode: str = "offline"
    swanlab_project: str = "pulsearena-local"
    run_name: str = "bc_local"


def split_data(data: ReplayArrays, val_ratio: float, seed: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    indices = np.arange(len(data.observations))
    rng.shuffle(indices)
    val_count = max(1, int(len(indices) * val_ratio))
    val_idx = indices[:val_count]
    train_idx = indices[val_count:]
    return data.observations[train_idx], data.actions[train_idx], data.observations[val_idx], data.actions[val_idx]


def make_loader(x: np.ndarray, y: np.ndarray, batch_size: int, shuffle: bool) -> DataLoader:
    dataset = TensorDataset(torch.from_numpy(x), torch.from_numpy(y))
    return DataLoader(dataset, batch_size=batch_size, shuffle=shuffle, drop_last=False, pin_memory=torch.cuda.is_available())


def compute_loss(pred: torch.Tensor, target: torch.Tensor) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    move_loss = nn.functional.mse_loss(torch.tanh(pred[:, 0:2]), target[:, 0:2])
    aim_loss = nn.functional.mse_loss(torch.tanh(pred[:, 2:4]), target[:, 2:4])
    button_loss = nn.functional.binary_cross_entropy_with_logits(pred[:, 4:7], target[:, 4:7])
    loss = move_loss + aim_loss + button_loss
    return loss, {"move_loss": move_loss, "aim_loss": aim_loss, "button_loss": button_loss}


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> dict[str, float]:
    model.eval()
    total = 0
    sums = {"loss": 0.0, "move_loss": 0.0, "aim_loss": 0.0, "button_loss": 0.0, "shoot_acc": 0.0, "dash_acc": 0.0, "shield_acc": 0.0}
    for xb, yb in loader:
        xb = xb.to(device, non_blocking=True)
        yb = yb.to(device, non_blocking=True)
        pred = model(xb)
        loss, parts = compute_loss(pred, yb)
        batch = xb.shape[0]
        total += batch
        sums["loss"] += float(loss) * batch
        for key, value in parts.items():
            sums[key] += float(value) * batch
        buttons = (torch.sigmoid(pred[:, 4:7]) > 0.5).float()
        target_buttons = yb[:, 4:7]
        acc = (buttons == target_buttons).float().mean(dim=0)
        sums["shoot_acc"] += float(acc[0]) * batch
        sums["dash_acc"] += float(acc[1]) * batch
        sums["shield_acc"] += float(acc[2]) * batch
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
    axes[0, 1].plot(epochs, [row["val/shoot_acc"] for row in history], label="shoot")
    axes[0, 1].plot(epochs, [row["val/dash_acc"] for row in history], label="dash")
    axes[0, 1].plot(epochs, [row["val/shield_acc"] for row in history], label="shield")
    axes[0, 1].set_title("Button Accuracy")
    axes[0, 1].legend()
    axes[1, 0].plot(epochs, [row["train/move_loss"] for row in history], label="move")
    axes[1, 0].plot(epochs, [row["train/aim_loss"] for row in history], label="aim")
    axes[1, 0].set_title("Continuous Loss")
    axes[1, 0].legend()
    axes[1, 1].plot(epochs, [row["epoch_seconds"] for row in history], label="seconds")
    axes[1, 1].set_title("Epoch Time")
    axes[1, 1].legend()
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def train_behavior_clone(config: BehaviorCloneConfig) -> dict[str, Any]:
    random.seed(config.seed)
    np.random.seed(config.seed)
    torch.manual_seed(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)

    data = load_replay_arrays(config.replay_dir, config.max_samples)
    train_x, train_y, val_x, val_y = split_data(data, config.val_ratio, config.seed)
    train_loader = make_loader(train_x, train_y, config.batch_size, shuffle=True)
    val_loader = make_loader(val_x, val_y, config.batch_size, shuffle=False)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = BehaviorPolicyNet(data.observation_dim, hidden=config.hidden).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=config.lr, weight_decay=1e-4)
    scaler = torch.amp.GradScaler("cuda", enabled=device.type == "cuda")

    swan_config = {
        "samples": int(len(data.observations)),
        "train_samples": int(len(train_x)),
        "val_samples": int(len(val_x)),
        "input_dim": data.observation_dim,
        "device": str(device),
        "epochs": config.epochs,
        "batch_size": config.batch_size,
        "hidden": config.hidden,
        "lr": config.lr,
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
        train_sums = {"loss": 0.0, "move_loss": 0.0, "aim_loss": 0.0, "button_loss": 0.0}
        seen = 0
        for xb, yb in train_loader:
            xb = xb.to(device, non_blocking=True)
            yb = yb.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.amp.autocast("cuda", enabled=device.type == "cuda"):
                pred = model(xb)
                loss, parts = compute_loss(pred, yb)
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
            "train/move_loss": train_metrics["move_loss"],
            "train/aim_loss": train_metrics["aim_loss"],
            "train/button_loss": train_metrics["button_loss"],
            "val/loss": val_metrics["loss"],
            "val/move_loss": val_metrics["move_loss"],
            "val/aim_loss": val_metrics["aim_loss"],
            "val/button_loss": val_metrics["button_loss"],
            "val/shoot_acc": val_metrics["shoot_acc"],
            "val/dash_acc": val_metrics["dash_acc"],
            "val/shield_acc": val_metrics["shield_acc"],
            "epoch_seconds": time.perf_counter() - epoch_start,
        }
        history.append(row)
        swanlab_utils.log(row, epoch, use_swanlab)
        print(json.dumps(row, ensure_ascii=False))
        if val_metrics["loss"] < best_val:
            best_val = val_metrics["loss"]
            torch.save({"model_state": model.state_dict(), "config": swan_config, "input_dim": data.observation_dim}, config.output_dir / "best_policy.pt")

    total_seconds = time.perf_counter() - start_time
    write_metrics_csv(config.output_dir / "metrics.csv", history)
    plot_metrics(config.output_dir / "metrics.png", history)
    torch.save({"model_state": model.state_dict(), "config": swan_config, "input_dim": data.observation_dim}, config.output_dir / "last_policy.pt")
    swanlab_utils.log({"run/total_seconds": total_seconds, "run/best_val_loss": best_val}, config.epochs + 1, use_swanlab)
    swanlab_utils.finish(use_swanlab)
    return {
        "training": "finished",
        "device": str(device),
        "samples": int(len(data.observations)),
        "epochs": config.epochs,
        "total_seconds": total_seconds,
        "best_val_loss": best_val,
        "metrics_csv": str(config.output_dir / "metrics.csv"),
        "metrics_png": str(config.output_dir / "metrics.png"),
        "checkpoint": str(config.output_dir / "best_policy.pt"),
        "swanlab_dir": str(config.output_dir / "swanlab"),
    }
