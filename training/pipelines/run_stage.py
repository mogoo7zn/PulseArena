#!/usr/bin/env python3
"""Run or print staged Pulse Arena headless curriculum jobs.

This script intentionally depends only on the Python standard library. It is a
launcher for Godot smoke/evaluation jobs; full MAPPO training should reuse the
same curriculum JSON and replace the command runner with a vectorized env
driver.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CURRICULUM_PATH = ROOT / "training" / "configs" / "curriculum.json"
PROFILES_DIR = ROOT / "training" / "configs" / "profiles"
LOCAL_SETTINGS_PATH = ROOT / "training" / "local_settings.json"
GODOT_LOG_DIR = ROOT / "training" / "artifacts" / "server_logs" / "logs"


def load_curriculum() -> dict[str, Any]:
    return json.loads(CURRICULUM_PATH.read_text(encoding="utf-8"))


def load_profile(profile_id: str | None) -> dict[str, Any]:
    if not profile_id:
        return {}
    profile_path = Path(profile_id)
    if not profile_path.exists():
        profile_path = PROFILES_DIR / f"{profile_id}.json"
    if not profile_path.exists():
        known = ", ".join(path.stem for path in sorted(PROFILES_DIR.glob("*.json")))
        raise SystemExit(f"Unknown profile '{profile_id}'. Known profiles: {known}")
    return json.loads(profile_path.read_text(encoding="utf-8"))


def merge_stage_profile(stage: dict[str, Any], profile: dict[str, Any]) -> dict[str, Any]:
    merged = dict(stage)
    overrides = profile.get("stage_overrides", {}).get(stage["id"], {})
    merged.update(overrides)
    return merged


def find_stage(curriculum: dict[str, Any], stage_id: str) -> dict[str, Any]:
    for stage in curriculum["stages"]:
        if stage["id"] == stage_id:
            return stage
    known = ", ".join(stage["id"] for stage in curriculum["stages"])
    raise SystemExit(f"Unknown stage '{stage_id}'. Known stages: {known}")


def resolve_godot(explicit: str | None) -> str:
    if explicit:
        return explicit
    env_value = os.environ.get("GODOT_BIN")
    if env_value:
        return env_value
    if LOCAL_SETTINGS_PATH.exists():
        settings = json.loads(LOCAL_SETTINGS_PATH.read_text(encoding="utf-8"))
        local_value = settings.get("godot_bin")
        if local_value:
            candidate = Path(str(local_value)).expanduser()
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate.resolve())
            resolved = shutil.which(str(local_value))
            if resolved:
                return resolved
    for candidate in ("godot4", "godot", "godot4.4", "godot4.3"):
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    return "godot"


def split_matches(total: int, jobs: int) -> list[int]:
    base = total // jobs
    extra = total % jobs
    return [base + (1 if i < extra else 0) for i in range(jobs)]


def stage_jobs(stage: dict[str, Any], profile: dict[str, Any], args: argparse.Namespace) -> list[list[str]]:
    maps = stage["maps"]
    if maps == ["all"]:
        maps = ["all"]
    seconds = int(args.seconds or stage.get("seconds", 90))
    matches = int(args.matches or stage.get("scripted_smoke_matches", 1))
    launcher_defaults = profile.get("launcher_defaults", {})
    seed = int(args.seed if args.seed is not None else launcher_defaults.get("seed", 20000))
    difficulty = args.difficulty or launcher_defaults.get("difficulty", "hard")
    godot = resolve_godot(args.godot)
    profile_id = profile.get("profile_id", "default")
    GODOT_LOG_DIR.mkdir(parents=True, exist_ok=True)
    per_map_matches = split_matches(matches, len(maps))

    commands: list[list[str]] = []
    for index, map_id in enumerate(maps):
        map_matches = max(1, per_map_matches[index])
        command = [
            godot,
            "--headless",
            "--disable-crash-handler",
            "--accessibility",
            "disabled",
            "--log-file",
            str(GODOT_LOG_DIR / f"{profile_id}_{stage['id']}_{map_id}_{seed + index * 10000}.log"),
            "--path",
            str(ROOT),
            "--",
            "--training",
            f"--profile={profile_id}",
            f"--stage={stage['id']}",
            f"--matches={map_matches}",
            f"--agents={int(args.agents or stage.get('agents', 4))}",
            f"--seconds={seconds}",
            f"--seed={seed + index * 10000}",
            f"--map={map_id}",
            f"--mode={stage.get('mode', 'ffa')}",
            f"--difficulty={difficulty}",
        ]
        if args.agent_controller:
            command.append(f"--agent-controller={args.agent_controller}")
        if args.agent_model_id:
            command.append(f"--agent-model-id={args.agent_model_id}")
        if args.agent_model_host:
            command.append(f"--agent-model-host={args.agent_model_host}")
        if args.agent_model_port is not None:
            command.append(f"--agent-model-port={args.agent_model_port}")
        if args.agent_model_timeout_ms is not None:
            command.append(f"--agent-model-timeout-ms={args.agent_model_timeout_ms}")
        if args.record_replay:
            command.append("--record-replay")
        if args.replay_dir:
            command.append(f"--replay-dir={args.replay_dir}")
        if args.reward_profile:
            command.append(f"--reward-profile={args.reward_profile}")
        if args.training_spawn_policy:
            command.append(f"--training-spawn-policy={args.training_spawn_policy}")
        commands.append(command)
    return commands


def print_command(command: list[str]) -> None:
    print(" ".join(quote_arg(part) for part in command))


def quote_arg(value: str) -> str:
    if any(ch.isspace() for ch in value):
        return '"' + value.replace('"', '\\"') + '"'
    return value


def run_commands(commands: list[list[str]]) -> int:
    exit_code = 0
    for command in commands:
        print_command(command)
        completed = subprocess.run(command, cwd=ROOT, check=False)
        if completed.returncode != 0:
            exit_code = completed.returncode
            break
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Pulse Arena curriculum stages.")
    parser.add_argument("--stage", default="all", help="Stage id, or 'all'.")
    parser.add_argument("--profile", default=None, help="Training profile id or JSON path.")
    parser.add_argument("--list", action="store_true", help="List stages and exit.")
    parser.add_argument("--list-profiles", action="store_true", help="List available training profiles and exit.")
    parser.add_argument("--show-profile", action="store_true", help="Print the selected profile JSON and exit.")
    parser.add_argument("--execute", action="store_true", help="Run commands instead of printing them.")
    parser.add_argument("--godot", default=None, help="Path to Godot executable. Defaults to GODOT_BIN or PATH.")
    parser.add_argument("--matches", type=int, default=None, help="Override scripted smoke matches.")
    parser.add_argument("--seconds", type=int, default=None, help="Override match duration.")
    parser.add_argument("--seed", type=int, default=None, help="Base random seed.")
    parser.add_argument("--difficulty", default=None, help="Scripted baseline difficulty.")
    parser.add_argument("--agent-controller", choices=["scripted", "model", "hybrid"], default=None, help="Agent controller type for headless smoke/eval.")
    parser.add_argument("--agents", type=int, default=None, help="Override agents per collected match.")
    parser.add_argument("--agent-model-id", default=None, help="Agent model id selected from training/models/model_catalog.json.")
    parser.add_argument("--agent-model-host", default=None, help="Model inference host.")
    parser.add_argument("--agent-model-port", type=int, default=None, help="Model inference port.")
    parser.add_argument("--agent-model-timeout-ms", type=int, default=None, help="Model inference request timeout.")
    parser.add_argument("--record-replay", action="store_true", help="Record decision JSONL replays for offline training.")
    parser.add_argument("--replay-dir", default=None, help="Repository-relative or res:// replay output directory.")
    parser.add_argument("--reward-profile", default=None, help="Reward and tactical feature profile for collected matches.")
    parser.add_argument("--training-spawn-policy", default=None, help="Training-only spawn curriculum policy forwarded to Godot.")
    args = parser.parse_args()

    curriculum = load_curriculum()
    if args.list_profiles:
        for path in sorted(PROFILES_DIR.glob("*.json")):
            data = json.loads(path.read_text(encoding="utf-8"))
            print(f"{data.get('profile_id', path.stem)}: {data.get('description', '')}")
        return 0
    profile = load_profile(args.profile)
    if args.show_profile:
        print(json.dumps(profile, ensure_ascii=False, indent=2))
        return 0
    if args.list:
        for stage in curriculum["stages"]:
            print(f"{stage['id']}: {stage['title']}")
        return 0

    selected = curriculum["stages"] if args.stage == "all" else [find_stage(curriculum, args.stage)]
    selected = [merge_stage_profile(stage, profile) for stage in selected]
    all_commands: list[list[str]] = []
    for stage in selected:
        all_commands.extend(stage_jobs(stage, profile, args))

    if not args.execute:
        for command in all_commands:
            print_command(command)
        profile_note = f" using profile '{profile.get('profile_id')}'" if profile else ""
        print(f"\nDry run only{profile_note}. Add --execute after GODOT_BIN is configured to launch jobs.")
        return 0
    return run_commands(all_commands)


if __name__ == "__main__":
    sys.exit(main())
