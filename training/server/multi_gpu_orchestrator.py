"""Backward-compatible shim. See :mod:`training.server.orchestration` for the implementation."""
from training.server.orchestration import (
    GPUAllocationError,
    GPUTask,
    OrchestrationResult,
    TaskResult,
    build_tasks,
    format_dry_run,
    parse_gpu_ids,
    run_tasks,
)
from training.server.orchestration.cli import load_config, main

__all__ = [
    "GPUAllocationError",
    "GPUTask",
    "OrchestrationResult",
    "TaskResult",
    "build_tasks",
    "format_dry_run",
    "load_config",
    "main",
    "parse_gpu_ids",
    "run_tasks",
]


if __name__ == "__main__":
    raise SystemExit(main())