#!/usr/bin/env python3
"""Validate the server prerequisites for a Hybrid Tactical v2 pilot run.

The script is deliberately dependency-light except for checking the runtime
packages that the actual trainer needs.  It writes a machine-readable report
so a remote coding agent can make a stop/go decision from evidence.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]

REQUIRED_FILES = (
    "project.godot",
    "training/train_pipeline.py",
    "training/tactical_bc_trainer.py",
    "training/configs/training_plans/hybrid_tactical_v2_server_pilot_bc.json",
    "scripts/controllers/hybrid_agent_controller.gd",
    "scripts/agents/hybrid_combat_executor.gd",
)


def run_command(command: list[str], timeout: int = 20) -> dict[str, Any]:
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc), "command": command}
    return {
        "ok": completed.returncode == 0,
        "command": command,
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def module_present(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def torch_info() -> dict[str, Any]:
    if not module_present("torch"):
        return {"installed": False, "cuda_available": False, "devices": []}
    try:
        import torch

        available = bool(torch.cuda.is_available())
        devices = []
        if available:
            for index in range(torch.cuda.device_count()):
                devices.append({
                    "index": index,
                    "name": torch.cuda.get_device_name(index),
                    "capability": list(torch.cuda.get_device_capability(index)),
                    "total_memory_bytes": int(torch.cuda.get_device_properties(index).total_memory),
                })
        return {
            "installed": True,
            "version": torch.__version__,
            "cuda_build": torch.version.cuda,
            "cuda_available": available,
            "device_count": torch.cuda.device_count() if available else 0,
            "devices": devices,
        }
    except Exception as exc:  # pragma: no cover - defensive for broken CUDA installs
        return {"installed": True, "cuda_available": False, "devices": [], "error": repr(exc)}


def resolve_godot(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    if os.environ.get("GODOT_BIN"):
        return os.environ["GODOT_BIN"]
    for candidate in ("godot", "godot4", "godot4.4", "godot4.3"):
        path = shutil.which(candidate)
        if path:
            return path
    return None


def build_report(args: argparse.Namespace) -> tuple[dict[str, Any], list[str]]:
    missing_files = [path for path in REQUIRED_FILES if not (ROOT / path).is_file()]
    module_status = {name: module_present(name) for name in ("numpy", "matplotlib", "torch")}
    torch_status = torch_info()
    godot = resolve_godot(args.godot)
    godot_status = run_command([godot, "--version"]) if godot else {"ok": False, "error": "Godot executable was not found"}
    nvidia_status = run_command(["nvidia-smi", "-L"]) if shutil.which("nvidia-smi") else {"ok": False, "error": "nvidia-smi was not found"}
    cuda_requirements = {
        "nvidia_smi_ok": bool(nvidia_status.get("ok", False)),
        "torch_cuda_available": bool(torch_status.get("cuda_available", False)),
    }

    failures: list[str] = []
    if sys.version_info < (3, 10):
        failures.append(f"Python 3.10+ is required; got {sys.version.split()[0]}")
    if missing_files:
        failures.append("Missing required project files: " + ", ".join(missing_files))
    for name, present in module_status.items():
        if not present:
            failures.append(f"Missing Python dependency: {name}")
    if not godot_status.get("ok", False):
        failures.append("Godot 4 headless/console executable is unavailable")
    if args.require_cuda and not cuda_requirements["nvidia_smi_ok"]:
        failures.append("NVIDIA driver is unavailable; nvidia-smi must succeed before GPU training")
    if args.require_cuda and not cuda_requirements["torch_cuda_available"]:
        failures.append("PyTorch CUDA is not available; do not run the A100 training pilot")

    report = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "root": str(ROOT),
        "python": {"version": sys.version, "executable": sys.executable},
        "required_files_missing": missing_files,
        "python_modules": module_status,
        "torch": torch_status,
        "godot": {"path": godot, **godot_status},
        "nvidia_smi": nvidia_status,
        "cuda_requirements": cuda_requirements,
        "result": "pass" if not failures else "fail",
        "failures": failures,
    }
    return report, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=None, help="Godot 4 console/headless executable. Defaults to GODOT_BIN or PATH.")
    parser.add_argument("--output", type=Path, default=None, help="Optional JSON report path.")
    parser.add_argument("--require-cuda", action="store_true", help="Fail when PyTorch cannot access a CUDA GPU.")
    args = parser.parse_args()

    report, failures = build_report(args)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
