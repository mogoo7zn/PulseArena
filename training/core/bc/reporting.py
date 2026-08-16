"""CSV + PNG reporting for the BC training history."""
from __future__ import annotations

import csv
from pathlib import Path

import matplotlib.pyplot as plt


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