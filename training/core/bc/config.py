"""Configuration dataclass for the tactical behavior cloning trainer."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


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