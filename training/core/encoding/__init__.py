"""Observation, tactical, and replay-row encoding primitives.

Split into focused modules:

- :mod:`.observation` — raw observation -> flat feature vector
- :mod:`.tactical` — decision labels, masks, tactical feature projection
- :mod:`.replay_loader` — JSONL replay rows -> numpy training tensors
"""
from training.core.encoding.observation import (
    ACTION_DIM,
    HYBRID_PROTOCOL_VERSION,
    MAX_OTHER_PLAYERS,
    MAX_PROJECTILES,
    RAY_COUNT,
    TACTICAL_FEATURE_SCHEMA_VERSION,
    b,
    flatten_observation,
    vec2,
)
from training.core.encoding.replay_loader import (
    HybridReplayArrays,
    count_replay_rows,
    load_hybrid_replay_arrays,
)
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
    tactical_features_from_observation,
)

__all__ = [
    "ACTION_DIM",
    "HYBRID_PROTOCOL_VERSION",
    "HybridReplayArrays",
    "MAX_OTHER_PLAYERS",
    "MAX_PROJECTILES",
    "RAY_COUNT",
    "TACTICAL_FEATURE_DIM",
    "TACTICAL_FEATURE_SCHEMA_VERSION",
    "TACTICAL_FIRE_MODES",
    "TACTICAL_MOVEMENTS",
    "TACTICAL_SKILL_MODES",
    "TACTICAL_TARGETS",
    "b",
    "count_replay_rows",
    "flatten_observation",
    "load_hybrid_replay_arrays",
    "normalize_tactical_features",
    "normalize_tactical_mask",
    "tactical_action_masks_from_observation",
    "tactical_decision_is_scripted_delegate",
    "tactical_decision_to_indices",
    "tactical_features_from_observation",
    "vec2",
]