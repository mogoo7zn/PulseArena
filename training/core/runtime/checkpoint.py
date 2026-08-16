"""Checkpoint loading utilities for the runtime agent policy.

Centralizes the awkward ``weights_only=True`` vs ``weights_only=False`` dance
needed to read legacy checkpoints that pickled platform-specific pathlib
classes on Windows or POSIX.
"""
from __future__ import annotations

import math
import pathlib
from pathlib import Path

import torch


ROOT = Path(__file__).resolve().parents[3]


def resolve_path(value: str | Path, base_dir: Path | None = None) -> Path:
    """Resolve ``value`` against the project root or ``base_dir`` when relative."""
    path = Path(value)
    if path.is_absolute():
        return path
    if base_dir is not None and (base_dir / path).exists():
        return (base_dir / path).resolve()
    return (ROOT / path).resolve()


def _safe_load_checkpoint(path: Path, device: torch.device) -> dict:
    try:
        return torch.load(path, map_location=device, weights_only=True)
    except Exception:
        # Local manifests point to checkpoints created by this project. The
        # fallback is needed for older checkpoints that stored pathlib objects.
        try:
            return torch.load(path, map_location=device, weights_only=False)
        except NotImplementedError as exc:
            # Historical checkpoints may pickle a platform-specific pathlib
            # class. Map only that class while reading the legacy artifact.
            error = str(exc).lower()
            if "windowspath" in error:
                original_windows_path = pathlib.WindowsPath
                try:
                    pathlib.WindowsPath = pathlib.PosixPath  # type: ignore[misc,assignment]
                    return torch.load(path, map_location=device, weights_only=False)
                finally:
                    pathlib.WindowsPath = original_windows_path  # type: ignore[misc,assignment]
            if "posixpath" in error:
                original_posix_path = pathlib.PosixPath
                try:
                    pathlib.PosixPath = pathlib.WindowsPath  # type: ignore[misc,assignment]
                    return torch.load(path, map_location=device, weights_only=False)
                finally:
                    pathlib.PosixPath = original_posix_path  # type: ignore[misc,assignment]
            raise


def _unit_vector(x: float, y: float, fallback_x: float = 1.0, fallback_y: float = 0.0) -> tuple[float, float]:
    length = math.hypot(x, y)
    if length <= 1e-6:
        return fallback_x, fallback_y
    return x / length, y / length