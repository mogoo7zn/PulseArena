"""Load hybrid replay JSONL rows into a numpy container for training."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from training.core.encoding.tactical import (
    TACTICAL_FEATURE_DIM,
    TACTICAL_FIRE_MODES,
    TACTICAL_MOVEMENTS,
    TACTICAL_SKILL_MODES,
    TACTICAL_TARGETS,
    normalize_tactical_features,
    normalize_tactical_mask,
    tactical_action_masks_from_observation,
    tactical_decision_is_scripted_delegate,
    tactical_decision_to_indices,
)
from training.core.replay_integrity import require_valid_replays


@dataclass(frozen=True)
class HybridReplayArrays:
    """Numpy bundle of one hybrid tactical dataset.

    Each ``*_modes``/``*_masks`` array shares its first axis with
    ``tactical_features``. ``action_masks`` retains the original raw mask
    dictionaries for diagnostics.
    """

    tactical_features: np.ndarray
    target_slots: np.ndarray
    movement_modes: np.ndarray
    fire_modes: np.ndarray
    skill_modes: np.ndarray
    target_masks: np.ndarray
    movement_masks: np.ndarray
    fire_masks: np.ndarray
    skill_masks: np.ndarray
    label_weights: np.ndarray
    confidence_targets: np.ndarray
    action_masks: list[dict[str, Any]]
    files: list[Path]

    @property
    def feature_dim(self) -> int:
        return int(self.tactical_features.shape[1])


def load_hybrid_replay_arrays(
    replay_dir: Path,
    max_samples: int | None = None,
    decision_key: str = "teacher_decision",
) -> HybridReplayArrays:
    """Validate ``replay_dir`` then materialize training-ready numpy arrays."""
    require_valid_replays(replay_dir)
    files = sorted(replay_dir.glob("*.hybrid_v2.jsonl"))
    if not files:
        files = sorted(replay_dir.glob("*.jsonl"))
    if not files:
        raise FileNotFoundError(f"No replay JSONL files found in {replay_dir}")
    features: list[list[float]] = []
    target_slots: list[int] = []
    movement_modes: list[int] = []
    fire_modes: list[int] = []
    skill_modes: list[int] = []
    target_masks: list[list[bool]] = []
    movement_masks: list[list[bool]] = []
    fire_masks: list[list[bool]] = []
    skill_masks: list[list[bool]] = []
    label_weights: list[float] = []
    confidence_targets: list[float] = []
    masks: list[dict[str, Any]] = []
    used_files: list[Path] = []
    for path in files:
        loaded_from_file = 0
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("replay_schema") != "hybrid_replay_v2":
                    continue
                decision = row.get(decision_key) or row.get("executed_decision") or {}
                target, movement, fire, skill = tactical_decision_to_indices(decision)
                action_mask = dict(row.get("action_masks") or tactical_action_masks_from_observation(row.get("observation", {})))
                weight = float(row.get("label_weight", 1.0))
                if tactical_decision_is_scripted_delegate(decision) and not row.get("label_source"):
                    weight = min(weight, 0.15)
                if bool(row.get("fallback_used", False)):
                    weight *= 0.70
                if bool(row.get("safety_override", False)):
                    weight *= 0.85
                features.append(normalize_tactical_features(row.get("tactical_features", [])))
                target_slots.append(target)
                movement_modes.append(movement)
                fire_modes.append(fire)
                skill_modes.append(skill)
                target_masks.append(normalize_tactical_mask(action_mask.get("target_slot"), len(TACTICAL_TARGETS), target))
                movement_masks.append(normalize_tactical_mask(action_mask.get("movement_mode"), len(TACTICAL_MOVEMENTS), movement))
                fire_masks.append(normalize_tactical_mask(action_mask.get("fire_mode"), len(TACTICAL_FIRE_MODES), fire))
                skill_masks.append(normalize_tactical_mask(action_mask.get("skill_mode"), len(TACTICAL_SKILL_MODES), skill))
                label_weights.append(float(np.clip(weight, 0.05, 1.0)))
                confidence_targets.append(float(np.clip(row.get("label_confidence", decision.get("confidence", 1.0)), 0.0, 1.0)))
                masks.append(action_mask)
                loaded_from_file += 1
                if max_samples is not None and len(features) >= max_samples:
                    break
        if loaded_from_file:
            used_files.append(path)
        if max_samples is not None and len(features) >= max_samples:
            break
    if not features:
        raise FileNotFoundError(f"No hybrid_replay_v2 rows found in {replay_dir}")
    return HybridReplayArrays(
        tactical_features=np.asarray(features, dtype=np.float32),
        target_slots=np.asarray(target_slots, dtype=np.int64),
        movement_modes=np.asarray(movement_modes, dtype=np.int64),
        fire_modes=np.asarray(fire_modes, dtype=np.int64),
        skill_modes=np.asarray(skill_modes, dtype=np.int64),
        target_masks=np.asarray(target_masks, dtype=np.bool_),
        movement_masks=np.asarray(movement_masks, dtype=np.bool_),
        fire_masks=np.asarray(fire_masks, dtype=np.bool_),
        skill_masks=np.asarray(skill_masks, dtype=np.bool_),
        label_weights=np.asarray(label_weights, dtype=np.float32),
        confidence_targets=np.asarray(confidence_targets, dtype=np.float32),
        action_masks=masks,
        files=used_files,
    )


def count_replay_rows(replay_dir: Path) -> tuple[int, int, int]:
    """Return ``(file_count, row_count, byte_count)`` for a replay directory."""
    files = sorted(replay_dir.glob("*.jsonl"))
    rows = 0
    bytes_total = 0
    for path in files:
        bytes_total += path.stat().st_size
        with path.open("r", encoding="utf-8") as handle:
            rows += sum(1 for line in handle if line.strip())
    return len(files), rows, bytes_total