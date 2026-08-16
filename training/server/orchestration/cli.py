"""CLI entry point for the multi-GPU orchestrator."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from training.server.orchestration.execution import run_tasks
from training.server.orchestration.planning import build_tasks, format_dry_run
from training.server.orchestration.types import GPUAllocationError


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run independent Pulse Arena training tasks on disjoint GPUs."
    )
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument(
        "--execute", action="store_true", help="Start subprocesses; default is dry-run."
    )
    parser.add_argument("--max-parallel", type=int, default=None)
    parser.add_argument("--no-fail-fast", action="store_true")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    tasks = build_tasks(config)
    if not args.execute:
        print(format_dry_run(tasks))
        return 0
    configured_parallel = config.get("max_parallel_tasks")
    max_parallel = args.max_parallel or (
        int(configured_parallel) if configured_parallel else None
    )
    result = run_tasks(tasks, max_parallel=max_parallel, fail_fast=not args.no_fail_fast)
    print(
        json.dumps(
            {
                "returncode": result.returncode,
                "results": {
                    task_id: {
                        "returncode": task_result.returncode,
                        "log_path": str(task_result.log_path),
                        "skipped": task_result.skipped,
                    }
                    for task_id, task_result in result.results.items()
                },
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())