"""Build and run ``run_stage`` collection commands for replay harvesting."""
from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUN_STAGE = ROOT / "training" / "run_stage.py"


@dataclass
class StageCollectConfig:
    profile: str
    stage: str = "all"
    record_replay: bool = True
    matches: int | None = None
    seconds: int | None = None
    seed: int | None = None
    godot: str | None = None
    agent_controller: str | None = None
    agent_model_id: str | None = None
    agents: int | None = None
    reward_profile_id: str | None = None
    training_spawn_policy: str | None = None
    replay_dir: str | None = None


def build_stage_command(config: StageCollectConfig, execute: bool) -> list[str]:
    command = [
        sys.executable,
        str(RUN_STAGE),
        "--profile",
        config.profile,
        "--stage",
        config.stage,
    ]
    if config.record_replay:
        command.append("--record-replay")
    if execute:
        command.append("--execute")
    if config.matches is not None:
        command.extend(["--matches", str(config.matches)])
    if config.seconds is not None:
        command.extend(["--seconds", str(config.seconds)])
    if config.seed is not None:
        command.extend(["--seed", str(config.seed)])
    if config.godot:
        command.extend(["--godot", config.godot])
    if config.agent_controller:
        command.extend(["--agent-controller", config.agent_controller])
    if config.agents is not None:
        command.extend(["--agents", str(config.agents)])
    if config.agent_model_id:
        command.extend(["--agent-model-id", config.agent_model_id])
    if config.reward_profile_id:
        command.extend(["--reward-profile", config.reward_profile_id])
    if config.training_spawn_policy:
        command.extend(["--training-spawn-policy", config.training_spawn_policy])
    if config.replay_dir:
        command.extend(["--replay-dir", config.replay_dir])
    return command


def run_stage_collection(config: StageCollectConfig, execute: bool) -> int:
    command = build_stage_command(config, execute=execute)
    print(" ".join(command))
    if not execute:
        return 0
    completed = subprocess.run(command, cwd=ROOT, check=False)
    return int(completed.returncode)


def resolve_godot(explicit: str | None = None) -> str:
    """Resolve the Godot binary path (delegates to ``training.pipelines.run_stage``)."""
    from training.pipelines.run_stage import resolve_godot as _resolve_godot

    return _resolve_godot(explicit)