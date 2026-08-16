"""Checkpoint save/load + environment/device runtime helpers for online training."""
from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable

import torch

from training.core.models import TacticalActorCritic
from training.core.online.config import TacticalOnlineConfig


def _resolve_device(config: TacticalOnlineConfig) -> torch.device:
    if config.device:
        device = torch.device(config.device)
    else:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if config.require_cuda and device.type != "cuda":
        raise RuntimeError("Tactical PPO pilot requires CUDA, but no CUDA device is available")
    return device


def _make_env(env_factory: Callable[..., Any], config: TacticalOnlineConfig) -> Any:
    return env_factory(port=config.port, godot=config.godot)


def _load_resume_checkpoint(
    model: TacticalActorCritic, checkpoint: str | Path
) -> dict[str, Any]:
    payload = torch.load(checkpoint, map_location="cpu", weights_only=False)
    input_dim = int(
        payload.get("input_dim", payload.get("config", {}).get("input_dim", model.input_dim))
    )
    if input_dim != model.input_dim:
        raise ValueError(
            f"PPO checkpoint input_dim {input_dim} does not match {model.input_dim}"
        )
    state = payload.get("model_state", payload.get("state_dict"))
    if not isinstance(state, dict):
        raise ValueError("PPO checkpoint is missing model_state")
    model.load_state_dict(state)
    return payload


def _save_checkpoint(
    model: TacticalActorCritic,
    config: TacticalOnlineConfig,
    device: torch.device,
    path: Path,
    *,
    bc_warm_start: str = "",
    resume_checkpoint: str = "",
) -> None:
    torch.save(
        {
            "model_state": model.state_dict(),
            "config": {
                **asdict(config),
                "output_dir": str(config.output_dir),
                "bc_checkpoint": str(config.bc_checkpoint) if config.bc_checkpoint is not None else None,
                "resume_checkpoint": str(config.resume_checkpoint) if config.resume_checkpoint is not None else None,
                "device": str(device),
            },
            "input_dim": model.input_dim,
            "bc_warm_start": bc_warm_start,
            "resume_checkpoint": resume_checkpoint,
        },
        path,
    )