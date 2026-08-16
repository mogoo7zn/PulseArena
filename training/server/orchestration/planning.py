"""Static GPU + task planning for the multi-GPU orchestrator."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Iterable

from training.server.orchestration.types import GPUAllocationError, GPUTask


ROOT = Path(__file__).resolve().parents[3]


def parse_gpu_ids(value: str | int | Iterable[int]) -> tuple[int, ...]:
    """Parse a GPU list such as ``0,2-4`` and return sorted unique IDs."""
    if isinstance(value, int):
        raw_parts = [str(value)]
    elif isinstance(value, str):
        raw_parts = [part.strip() for part in value.split(",") if part.strip()]
    else:
        raw_parts = [str(item).strip() for item in value]
    if not raw_parts:
        raise GPUAllocationError("gpu_ids must contain at least one GPU id")

    parsed: set[int] = set()
    for part in raw_parts:
        if "-" in part:
            bounds = part.split("-")
            if len(bounds) != 2 or not all(bound.strip().isdigit() for bound in bounds):
                raise GPUAllocationError(f"Invalid GPU range: {part!r}")
            start, end = (int(bound) for bound in bounds)
            if start > end:
                raise GPUAllocationError(f"GPU range must be ascending: {part!r}")
            parsed.update(range(start, end + 1))
        elif part.isdigit():
            parsed.add(int(part))
        else:
            raise GPUAllocationError(f"Invalid GPU id: {part!r}")
    if any(gpu_id < 0 for gpu_id in parsed):
        raise GPUAllocationError("GPU ids must be non-negative")
    return tuple(sorted(parsed))


def _render_token(
    token: Any, *, root: Path, python_executable: str, task_id: str
) -> str:
    return (
        str(token)
        .replace("{root}", str(root))
        .replace("{python}", str(python_executable))
        .replace("{task_id}", task_id)
    )


def _shell_quote(value: str) -> str:
    if value and all(
        character.isalnum() or character in "/._-=:-=" for character in value
    ):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


def build_tasks(
    config: dict[str, Any],
    *,
    root: Path = ROOT,
    python_executable: str | None = None,
) -> list[GPUTask]:
    """Validate and materialize generic GPU subprocess tasks from JSON config."""
    python_executable = python_executable or sys.executable
    log_dir = Path(config.get("log_dir", "training/artifacts/runs/multi_gpu/logs"))
    if not log_dir.is_absolute():
        log_dir = root / log_dir
    tasks: list[GPUTask] = []
    seen_task_ids: set[str] = set()
    claimed_gpus: dict[int, str] = {}
    global_env = dict(config.get("env", {}))

    raw_tasks = config.get("tasks")
    if not isinstance(raw_tasks, list) or not raw_tasks:
        raise GPUAllocationError("config.tasks must be a non-empty list")

    for raw_task in raw_tasks:
        if not isinstance(raw_task, dict):
            raise GPUAllocationError("each task must be an object")
        task_id = str(raw_task.get("task_id", "")).strip()
        if not task_id:
            raise GPUAllocationError("each task requires a non-empty task_id")
        if task_id in seen_task_ids:
            raise GPUAllocationError(f"duplicate task_id: {task_id}")
        seen_task_ids.add(task_id)

        gpu_ids = parse_gpu_ids(raw_task.get("gpu_ids", ""))
        for gpu_id in gpu_ids:
            previous = claimed_gpus.get(gpu_id)
            if previous is not None:
                raise GPUAllocationError(
                    f"GPU {gpu_id} is assigned to both {previous!r} and {task_id!r}"
                )
            claimed_gpus[gpu_id] = task_id

        raw_command = raw_task.get("command")
        if not isinstance(raw_command, list) or not raw_command:
            raise GPUAllocationError(f"task {task_id!r} command must be a non-empty list")
        command = tuple(
            _render_token(
                token, root=root, python_executable=python_executable, task_id=task_id
            )
            for token in raw_command
        )
        raw_cwd = Path(str(raw_task.get("cwd", root)))
        cwd = raw_cwd if raw_cwd.is_absolute() else root / raw_cwd
        raw_log_path = raw_task.get("log_path", str(log_dir / f"{task_id}.log"))
        log_path = Path(str(raw_log_path))
        if not log_path.is_absolute():
            log_path = root / log_path
        env = {
            str(key): _render_token(
                value, root=root, python_executable=python_executable, task_id=task_id
            )
            for key, value in global_env.items()
        }
        env.update(
            {
                str(key): _render_token(
                    value,
                    root=root,
                    python_executable=python_executable,
                    task_id=task_id,
                )
                for key, value in dict(raw_task.get("env", {})).items()
            }
        )
        env["CUDA_VISIBLE_DEVICES"] = ",".join(str(gpu_id) for gpu_id in gpu_ids)
        env.setdefault("PYTHONUNBUFFERED", "1")
        tasks.append(
            GPUTask(
                task_id=task_id,
                gpu_ids=gpu_ids,
                command=command,
                cwd=cwd,
                env=env,
                log_path=log_path,
            )
        )
    return tasks


def format_dry_run(tasks: list[GPUTask]) -> str:
    lines = []
    for task in tasks:
        command = " ".join(_shell_quote(token) for token in task.command)
        env_items = [
            f"{key}={_shell_quote(value)}"
            for key, value in sorted(task.env.items())
            if key != "PYTHONUNBUFFERED"
        ]
        lines.append(
            f"[{task.task_id}] {' '.join(env_items)} cwd={task.cwd} log={task.log_path}\n"
            f"  {command}"
        )
    return "\n".join(lines)