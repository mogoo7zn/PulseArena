"""Thin wrappers around the optional ``swanlab`` logging dependency."""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def init_swanlab(mode: str, project: str, name: str, log_dir: Path, config: dict[str, Any]):
    if mode == "disabled":
        return None
    os.environ["PYTHONIOENCODING"] = "utf-8"
    os.environ["PYTHONUTF8"] = "1"
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    import swanlab

    return swanlab.init(project=project, name=name, mode=mode, log_dir=str(log_dir), config=config)


def log(metrics: dict[str, float], step: int, enabled: bool) -> None:
    if not enabled:
        return
    import swanlab

    swanlab.log(metrics, step=step)


def finish(enabled: bool) -> None:
    if not enabled:
        return
    import swanlab

    swanlab.finish()


def start_dashboard(
    log_dir: Path, port: int = 5092, host: str = "127.0.0.1"
) -> subprocess.Popen:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    stdout = (log_dir.parent / "swanlab_watch.out.log").open("ab")
    stderr = (log_dir.parent / "swanlab_watch.err.log").open("ab")
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    process = subprocess.Popen(
        [sys.executable, "-m", "swanlab", "watch", str(log_dir), "--host", host, "--port", str(port)],
        stdout=stdout,
        stderr=stderr,
        env=env,
        creationflags=flags,
    )
    time.sleep(3)
    return process