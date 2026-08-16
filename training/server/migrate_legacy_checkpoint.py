#!/usr/bin/env python3
"""Rewrite a legacy PyTorch checkpoint without platform-specific pathlib values."""
from __future__ import annotations

import argparse
import pathlib
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

import torch


@contextmanager
def legacy_path_compat(error: Exception) -> Iterator[None]:
    """Temporarily map the serialized foreign path class to the local class."""
    message = str(error).lower()
    if "windowspath" in message:
        original = pathlib.WindowsPath
        pathlib.WindowsPath = pathlib.PosixPath  # type: ignore[misc,assignment]
        try:
            yield
        finally:
            pathlib.WindowsPath = original  # type: ignore[misc,assignment]
        return
    if "posixpath" in message:
        original = pathlib.PosixPath
        pathlib.PosixPath = pathlib.WindowsPath  # type: ignore[misc,assignment]
        try:
            yield
        finally:
            pathlib.PosixPath = original  # type: ignore[misc,assignment]
        return
    raise error


def load_checkpoint(path: Path, device: str, allow_legacy_pickle: bool) -> dict[str, Any]:
    try:
        checkpoint = torch.load(path, map_location=device, weights_only=True)
    except Exception as exc:
        if not allow_legacy_pickle:
            raise SystemExit(
                "Checkpoint needs legacy pickle loading. Only run with "
                "--allow-legacy-pickle after verifying that the file is trusted."
            ) from exc
        try:
            checkpoint = torch.load(path, map_location=device, weights_only=False)
        except NotImplementedError as path_error:
            with legacy_path_compat(path_error):
                checkpoint = torch.load(path, map_location=device, weights_only=False)
    if not isinstance(checkpoint, dict):
        raise SystemExit("Checkpoint root must be a dictionary")
    if "model_state" not in checkpoint:
        raise SystemExit("Checkpoint does not contain model_state")
    return checkpoint


def portable(value: Any) -> Any:
    if isinstance(value, pathlib.PurePath):
        return value.as_posix()
    if isinstance(value, dict):
        return {str(key): portable(item) for key, item in value.items()}
    if isinstance(value, list):
        return [portable(item) for item in value]
    if isinstance(value, tuple):
        return tuple(portable(item) for item in value)
    if isinstance(value, set):
        return sorted(portable(item) for item in value)
    if value is None or isinstance(value, (bool, int, float, str, bytes, torch.Tensor)):
        return value
    raise TypeError(f"Unsupported checkpoint value: {type(value).__name__}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Trusted legacy checkpoint path.")
    parser.add_argument("--output", required=True, type=Path, help="New portable checkpoint path.")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--allow-legacy-pickle", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.input.is_file():
        raise SystemExit(f"Input checkpoint does not exist: {args.input}")
    if args.output.exists() and not args.overwrite:
        raise SystemExit(f"Output exists: {args.output}. Pass --overwrite to replace it.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checkpoint = portable(load_checkpoint(args.input, args.device, args.allow_legacy_pickle))
    torch.save(checkpoint, args.output)
    verified = torch.load(args.output, map_location=args.device, weights_only=True)
    if not isinstance(verified, dict) or "model_state" not in verified:
        raise SystemExit("Converted checkpoint verification failed")
    print(f"Converted portable checkpoint: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
