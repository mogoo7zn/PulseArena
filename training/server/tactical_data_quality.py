"""Backward-compatible shim.

The implementation moved to :mod:`training.core.training.replay_quality`
because the audit + episode-split logic belongs with the training pipeline,
not with server operations. Old imports like
``from training.server.tactical_data_quality import audit_tactical_data``
continue to resolve.
"""
from training.core.training.replay_quality import (
    DECISION_FIELDS,
    MASK_SIZES,
    audit_tactical_data,
    build_episode_split,
    decision_key,
    episode_group_id,
    is_legal_label,
)

__all__ = [
    "DECISION_FIELDS",
    "MASK_SIZES",
    "audit_tactical_data",
    "build_episode_split",
    "decision_key",
    "episode_group_id",
    "is_legal_label",
]


if __name__ == "__main__":
    from training.core.training.replay_quality import main as _main

    raise SystemExit(_main())