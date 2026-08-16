"""Backward-compatible shim. See :mod:`training.core.env` for the implementation."""
from training.core.env import (
    GodotStepEnv,
    StageCollectConfig,
    StepIPCUnavailableError,
    build_stage_command,
    resolve_godot,
    run_stage_collection,
)

__all__ = [
    "GodotStepEnv",
    "StageCollectConfig",
    "StepIPCUnavailableError",
    "build_stage_command",
    "resolve_godot",
    "run_stage_collection",
]