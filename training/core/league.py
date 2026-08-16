"""Backward-compatible shim. See :mod:`training.core.training.league` for the implementation."""
from training.core.training.league import CheckpointArchive, CheckpointEntry

__all__ = ["CheckpointArchive", "CheckpointEntry"]