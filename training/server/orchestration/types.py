"""Dataclasses + custom exception for the multi-GPU orchestrator."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


class GPUAllocationError(ValueError):
    """Raised when a task configuration would make GPU ownership ambiguous."""


@dataclass(frozen=True)
class GPUTask:
    task_id: str
    gpu_ids: tuple[int, ...]
    command: tuple[str, ...]
    cwd: Path
    env: dict[str, str]
    log_path: Path


@dataclass(frozen=True)
class TaskResult:
    task_id: str
    returncode: int
    log_path: Path
    skipped: bool = False


@dataclass(frozen=True)
class OrchestrationResult:
    returncode: int
    results: dict[str, TaskResult]


SKIPPED_RETURN_CODE = 125