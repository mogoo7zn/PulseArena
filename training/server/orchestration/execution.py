"""Subprocess execution + concurrent scheduling for the multi-GPU orchestrator."""
from __future__ import annotations

import os
import subprocess
import threading
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait

from training.server.orchestration.planning import build_tasks
from training.server.orchestration.types import (
    SKIPPED_RETURN_CODE,
    GPUTask,
    GPUAllocationError,
    OrchestrationResult,
    TaskResult,
)


def _run_task(
    task: GPUTask,
    *,
    stop_event: threading.Event,
    process_lock: threading.Lock,
    active_processes: dict[str, "subprocess.Popen[str]"],
) -> TaskResult:
    task.log_path.parent.mkdir(parents=True, exist_ok=True)
    with process_lock:
        if stop_event.is_set():
            return TaskResult(
                task.task_id, SKIPPED_RETURN_CODE, task.log_path, skipped=True
            )
        merged_env = os.environ.copy()
        merged_env.update(task.env)
        try:
            log_file = task.log_path.open("w", encoding="utf-8")
            process = subprocess.Popen(
                list(task.command),
                cwd=task.cwd,
                env=merged_env,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except OSError as exc:
            task.log_path.write_text(f"Failed to start task: {exc}\n", encoding="utf-8")
            return TaskResult(task.task_id, 127, task.log_path)
        active_processes[task.task_id] = process
    try:
        returncode = process.wait()
        return TaskResult(task.task_id, int(returncode), task.log_path)
    finally:
        with process_lock:
            active_processes.pop(task.task_id, None)
        log_file.close()


def _terminate_active(
    active_processes: dict[str, "subprocess.Popen[str]"],
    process_lock: threading.Lock,
) -> None:
    with process_lock:
        processes = list(active_processes.values())
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def run_tasks(
    tasks: list[GPUTask],
    *,
    max_parallel: int | None = None,
    fail_fast: bool = True,
) -> OrchestrationResult:
    if not tasks:
        raise GPUAllocationError("at least one task is required")
    max_parallel = max_parallel or len(tasks)
    if max_parallel < 1:
        raise GPUAllocationError("max_parallel must be positive")
    max_parallel = min(max_parallel, len(tasks))

    stop_event = threading.Event()
    process_lock = threading.Lock()
    active_processes: dict[str, "subprocess.Popen[str]"] = {}
    results: dict[str, TaskResult] = {}
    next_index = 0
    failed = False

    with ThreadPoolExecutor(max_workers=max_parallel) as executor:
        active_futures: dict[Future[TaskResult], str] = {}
        while next_index < len(tasks) or active_futures:
            while (
                not failed
                and len(active_futures) < max_parallel
                and next_index < len(tasks)
            ):
                task = tasks[next_index]
                next_index += 1
                future = executor.submit(
                    _run_task,
                    task,
                    stop_event=stop_event,
                    process_lock=process_lock,
                    active_processes=active_processes,
                )
                active_futures[future] = task.task_id
            if not active_futures:
                break
            completed, _ = wait(active_futures, return_when=FIRST_COMPLETED)
            for future in completed:
                task_id = active_futures.pop(future)
                result = future.result()
                results[task_id] = result
                if result.returncode != 0 and not result.skipped:
                    failed = True
                    if fail_fast:
                        stop_event.set()
                        _terminate_active(active_processes, process_lock)
            if failed and fail_fast:
                break

    if failed and fail_fast:
        for future, task_id in list(active_futures.items()):
            if future.done():
                results[task_id] = future.result()
        for task in tasks[next_index:]:
            results.setdefault(
                task.task_id,
                TaskResult(
                    task.task_id,
                    SKIPPED_RETURN_CODE,
                    task.log_path,
                    skipped=True,
                ),
            )
        for task in tasks:
            results.setdefault(
                task.task_id,
                TaskResult(
                    task.task_id,
                    SKIPPED_RETURN_CODE,
                    task.log_path,
                    skipped=True,
                ),
            )
    returncode = next(
        (result.returncode for result in results.values() if result.returncode != 0),
        0,
    )
    return OrchestrationResult(returncode=returncode, results=results)


__all__ = [
    "OrchestrationResult",
    "build_tasks",
    "run_tasks",
]