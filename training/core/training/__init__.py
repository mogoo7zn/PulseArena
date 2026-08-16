"""Training-side helpers: checkpoint archive, swanlab logging, replay quality."""
from training.core.training.league import CheckpointArchive, CheckpointEntry
from training.core.training.replay_quality import (
    audit_tactical_data,
    build_episode_split,
    decision_key,
    episode_group_id,
    is_legal_label,
)
from training.core.training.swanlab import (
    finish,
    init_swanlab,
    log,
    start_dashboard,
)

__all__ = [
    "CheckpointArchive",
    "CheckpointEntry",
    "audit_tactical_data",
    "build_episode_split",
    "decision_key",
    "episode_group_id",
    "finish",
    "init_swanlab",
    "is_legal_label",
    "log",
    "start_dashboard",
]