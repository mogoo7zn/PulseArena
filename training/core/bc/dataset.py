"""Episode-aware dataset split + DataLoader construction for tactical BC."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, TensorDataset

from training.core.encoding import HybridReplayArrays
from training.core.training.replay_quality import build_episode_split, episode_group_id


def split_data(
    data: HybridReplayArrays,
    val_ratio: float,
    seed: int,
    episode_ids: list[str],
) -> tuple[TensorDataset, TensorDataset]:
    """Split a replay dataset deterministically by episode group."""
    if len(episode_ids) != len(data.tactical_features):
        raise ValueError("episode_ids must align one-to-one with tactical replay rows")
    split = build_episode_split(
        ({"episode_id": episode_id} for episode_id in episode_ids),
        val_ratio,
        seed,
    )
    train_idx = np.asarray(
        [index for index, episode_id in enumerate(episode_ids) if episode_id in split["train"]],
        dtype=np.int64,
    )
    val_idx = np.asarray(
        [index for index, episode_id in enumerate(episode_ids) if episode_id in split["dev"]],
        dtype=np.int64,
    )
    if not len(train_idx) or not len(val_idx):
        raise ValueError(
            "episode group split requires at least two episodes and a positive validation ratio"
        )

    def _dataset(indices: np.ndarray) -> TensorDataset:
        return TensorDataset(
            torch.from_numpy(data.tactical_features[indices]),
            torch.from_numpy(data.target_slots[indices]),
            torch.from_numpy(data.movement_modes[indices]),
            torch.from_numpy(data.fire_modes[indices]),
            torch.from_numpy(data.skill_modes[indices]),
            torch.from_numpy(data.target_masks[indices]),
            torch.from_numpy(data.movement_masks[indices]),
            torch.from_numpy(data.fire_masks[indices]),
            torch.from_numpy(data.skill_masks[indices]),
            torch.from_numpy(data.label_weights[indices]),
            torch.from_numpy(data.confidence_targets[indices]),
        )

    return _dataset(train_idx), _dataset(val_idx)


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
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        drop_last=False,
        pin_memory=torch.cuda.is_available(),
    )