#!/usr/bin/env python3
"""Local GPU behavior cloning warm start from Godot replay JSONL files.

This is intentionally a small local trainer. It does not replace the future
PPO/MAPPO learner; it provides immediate curves and validates the observation
and action pipeline on the local machine.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import sys
import time
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPLAY_DIR = ROOT / "training" / "replays"
DEFAULT_RUN_DIR = ROOT / "training" / "runs" / "behavior_clone"

MAX_OTHER_PLAYERS = 3
MAX_PROJECTILES = 24
RAY_COUNT = 16


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def vec2(data: Any) -> tuple[float, float]:
    if isinstance(data, dict):
        return float(data.get("x", 0.0)), float(data.get("y", 0.0))
    return 0.0, 0.0


def b(value: Any) -> float:
    return 1.0 if bool(value) else 0.0


def flatten_observation(obs: dict[str, Any]) -> list[float]:
    self_data = obs.get("self", {})
    pos = vec2(self_data.get("position", {}))
    vel = vec2(self_data.get("velocity", {}))
    aim = vec2(self_data.get("aim_direction", {"x": 1.0, "y": 0.0}))
    out: list[float] = [
        float(self_data.get("player_id", -1)),
        float(self_data.get("team_id", -1)),
        pos[0],
        pos[1],
        vel[0],
        vel[1],
        aim[0],
        aim[1],
        float(self_data.get("health_ratio", 1.0)),
        float(self_data.get("energy_ratio", 1.0)),
        float(self_data.get("shoot_cooldown_ratio", 0.0)),
        float(self_data.get("dash_cooldown_ratio", 0.0)),
        float(self_data.get("shield_cooldown_ratio", 0.0)),
        b(self_data.get("is_alive", True)),
        b(self_data.get("is_shielding", False)),
        b(self_data.get("has_respawn_protection", False)),
        float(self_data.get("score", 0)),
        float(self_data.get("remaining_time_ratio", 1.0)),
    ]

    players = list(obs.get("other_players", []))[:MAX_OTHER_PLAYERS]
    while len(players) < MAX_OTHER_PLAYERS:
        players.append({})
    for player in players:
        rel = vec2(player.get("relative_position", {}))
        rel_vel = vec2(player.get("relative_velocity", {}))
        player_aim = vec2(player.get("aim_direction", {"x": 1.0, "y": 0.0}))
        out.extend([
            rel[0],
            rel[1],
            rel_vel[0],
            rel_vel[1],
            player_aim[0],
            player_aim[1],
            float(player.get("health_ratio", 0.0)),
            b(player.get("is_teammate", False)),
            b(player.get("is_alive", False)),
            b(player.get("is_shielding", False)),
            b(player.get("is_dashing", False)),
            b(player.get("has_respawn_protection", False)),
            b(player.get("valid", False)),
        ])

    projectiles = list(obs.get("projectiles", []))[:MAX_PROJECTILES]
    while len(projectiles) < MAX_PROJECTILES:
        projectiles.append({})
    for projectile in projectiles:
        rel = vec2(projectile.get("relative_position", {}))
        rel_vel = vec2(projectile.get("relative_velocity", {}))
        out.extend([
            rel[0],
            rel[1],
            rel_vel[0],
            rel_vel[1],
            b(projectile.get("is_own", False)),
            b(projectile.get("is_teammate", False)),
            float(projectile.get("lifetime_ratio", 0.0)),
            float(projectile.get("damage_ratio", 0.0)),
            b(projectile.get("valid", False)),
        ])

    map_data = obs.get("map", {})
    boundaries = list(map_data.get("boundary_distances", [1.0, 1.0, 1.0, 1.0]))[:4]
    while len(boundaries) < 4:
        boundaries.append(1.0)
    rays = list(map_data.get("ray_results", []))[:RAY_COUNT]
    while len(rays) < RAY_COUNT:
        rays.append(1.0)
    resource = vec2(map_data.get("nearest_resource_relative_position", {}))
    out.extend(float(x) for x in boundaries)
    out.extend(float(x) for x in rays)
    out.extend([
        resource[0],
        resource[1],
        float(map_data.get("map_id", 0)),
        float(map_data.get("game_mode_id", 0)),
    ])
    return out


def flatten_action(action: dict[str, Any]) -> list[float]:
    return [
        float(action.get("move_x", 0.0)),
        float(action.get("move_y", 0.0)),
        float(action.get("aim_x", 1.0)),
        float(action.get("aim_y", 0.0)),
        b(action.get("shoot", False)),
        b(action.get("dash", False)),
        b(action.get("shield", False)),
    ]


def load_replays(replay_dir: Path, max_samples: int | None = None) -> tuple[np.ndarray, np.ndarray, list[Path]]:
    files = sorted(replay_dir.glob("*.jsonl"))
    if not files:
        raise SystemExit(f"No replay JSONL files found in {replay_dir}")
    observations: list[list[float]] = []
    actions: list[list[float]] = []
    used_files: list[Path] = []
    for path in files:
        loaded_from_file = 0
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                observations.append(flatten_observation(row["observation"]))
                actions.append(flatten_action(row["action"]))
                loaded_from_file += 1
                if max_samples is not None and len(observations) >= max_samples:
                    break
        if loaded_from_file:
            used_files.append(path)
        if max_samples is not None and len(observations) >= max_samples:
            break
    return np.asarray(observations, dtype=np.float32), np.asarray(actions, dtype=np.float32), used_files


class PolicyNet(nn.Module):
    def __init__(self, input_dim: int, hidden: int = 256) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.LayerNorm(input_dim),
            nn.Linear(input_dim, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
            nn.Linear(hidden, 7),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


def split_data(x: np.ndarray, y: np.ndarray, val_ratio: float, seed: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    indices = np.arange(len(x))
    rng.shuffle(indices)
    val_count = max(1, int(len(indices) * val_ratio))
    val_idx = indices[:val_count]
    train_idx = indices[val_count:]
    return x[train_idx], y[train_idx], x[val_idx], y[val_idx]


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


def init_swanlab(args: argparse.Namespace, config: dict[str, Any]):
    if args.swanlab_mode == "disabled":
        return None
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    import swanlab

    return swanlab.init(
        project=args.swanlab_project,
        name=args.run_name,
        mode=args.swanlab_mode,
        log_dir=str(args.output_dir / "swanlab"),
        config=config,
    )


def log_swanlab(metrics: dict[str, float], step: int, enabled: bool) -> None:
    if not enabled:
        return
    import swanlab

    swanlab.log(metrics, step=step)


def finish_swanlab(enabled: bool) -> None:
    if not enabled:
        return
    import swanlab

    swanlab.finish()


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Train a local BC warm-start policy from Pulse Arena replays.")
    parser.add_argument("--replay-dir", type=Path, default=DEFAULT_REPLAY_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_RUN_DIR)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--hidden", type=int, default=256)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=20260627)
    parser.add_argument("--max-samples", type=int, default=None)
    parser.add_argument("--swanlab-mode", choices=["disabled", "offline", "online", "local"], default="offline")
    parser.add_argument("--swanlab-project", default="pulsearena-local")
    parser.add_argument("--run-name", default="bc_local_constrained")
    args = parser.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    x, y, used_files = load_replays(args.replay_dir, args.max_samples)
    train_x, train_y, val_x, val_y = split_data(x, y, args.val_ratio, args.seed)
    train_loader = make_loader(train_x, train_y, args.batch_size, shuffle=True)
    val_loader = make_loader(val_x, val_y, args.batch_size, shuffle=False)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = PolicyNet(x.shape[1], hidden=args.hidden).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scaler = torch.amp.GradScaler("cuda", enabled=device.type == "cuda")

    config = {
        "samples": int(len(x)),
        "train_samples": int(len(train_x)),
        "val_samples": int(len(val_x)),
        "input_dim": int(x.shape[1]),
        "device": str(device),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "hidden": args.hidden,
        "lr": args.lr,
        "replay_files": [str(path.relative_to(ROOT)) for path in used_files],
    }
    swan_run = init_swanlab(args, config)
    use_swanlab = swan_run is not None and args.swanlab_mode != "disabled"

    history: list[dict[str, float]] = []
    best_val = math.inf
    start_time = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
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
        epoch_seconds = time.perf_counter() - epoch_start
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
            "epoch_seconds": epoch_seconds,
        }
        history.append(row)
        log_swanlab(row, epoch, use_swanlab)
        print(json.dumps(row, ensure_ascii=False))
        if val_metrics["loss"] < best_val:
            best_val = val_metrics["loss"]
            torch.save({
                "model_state": model.state_dict(),
                "config": config,
                "input_dim": x.shape[1],
            }, args.output_dir / "best_policy.pt")

    total_seconds = time.perf_counter() - start_time
    write_metrics_csv(args.output_dir / "metrics.csv", history)
    plot_metrics(args.output_dir / "metrics.png", history)
    torch.save({"model_state": model.state_dict(), "config": config, "input_dim": x.shape[1]}, args.output_dir / "last_policy.pt")
    log_swanlab({"run/total_seconds": total_seconds, "run/best_val_loss": best_val}, args.epochs + 1, use_swanlab)
    finish_swanlab(use_swanlab)
    print(json.dumps({
        "training": "finished",
        "device": str(device),
        "samples": len(x),
        "epochs": args.epochs,
        "total_seconds": total_seconds,
        "best_val_loss": best_val,
        "metrics_csv": str(args.output_dir / "metrics.csv"),
        "metrics_png": str(args.output_dir / "metrics.png"),
        "checkpoint": str(args.output_dir / "best_policy.pt"),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
