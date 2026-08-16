#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from training.core.replay_integrity import inspect_replay_directory
from training.core.godot_env import StageCollectConfig, StepIPCUnavailableError, build_stage_command, run_stage_collection
from training.core.tactical_bc_trainer import TacticalBehaviorCloneConfig, train_tactical_behavior_clone
from training.core.tactical_online_trainer import TacticalOnlineConfig, train_tactical_ppo
from training.server.multi_gpu_orchestrator import (
    build_tasks,
    format_dry_run,
    load_config as load_multi_gpu_config,
    run_tasks,
)


PROFILES_DIR = ROOT / "training" / "configs" / "profiles"
PLANS_DIR = ROOT / "training" / "configs" / "training_plans"
MULTI_GPU_DIR = ROOT / "training" / "configs" / "multi_gpu"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_profile(profile_id: str) -> dict[str, Any]:
    path = PROFILES_DIR / f"{profile_id}.json"
    if not path.exists():
        known = ", ".join(sorted(p.stem for p in PROFILES_DIR.glob("*.json")))
        raise SystemExit(f"Unknown profile '{profile_id}'. Known profiles: {known}")
    return load_json(path)


def resolve_plan(plan: str | None, profile_id: str) -> dict[str, Any]:
    if plan:
        path = Path(plan)
        if not path.exists():
            path = PLANS_DIR / f"{plan}.json"
    else:
        default_name = "hybrid_tactical_local" if profile_id == "local_constrained" else "hybrid_tactical_full"
        path = PLANS_DIR / f"{default_name}.json"
    if not path.exists():
        known = ", ".join(sorted(p.stem for p in PLANS_DIR.glob("*.json")))
        raise SystemExit(f"Unknown plan '{plan}'. Known plans: {known}")
    return load_json(path)


def resolve_multi_gpu_config(value: str | None, plan: dict[str, Any]) -> Path:
    configured = value or plan.get("multi_gpu", {}).get("config")
    if not configured:
        raise SystemExit("No multi-GPU config specified; use --multi-gpu-config or plan.multi_gpu.config")
    path = Path(configured)
    if not path.exists():
        path = ROOT / str(configured)
    if not path.exists():
        path = MULTI_GPU_DIR / f"{configured}.json"
    if not path.exists():
        known = ", ".join(sorted(p.stem for p in MULTI_GPU_DIR.glob("*.json")))
        raise SystemExit(f"Unknown multi-GPU config '{configured}'. Known configs: {known}")
    return path


def abs_path(value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def validate(profile: dict[str, Any], plan: dict[str, Any]) -> dict[str, Any]:
    if plan.get("profile_id") != profile.get("profile_id"):
        raise SystemExit(f"Plan/profile mismatch: {plan.get('profile_id')} != {profile.get('profile_id')}")
    bc = plan.get("behavior_clone", {})
    tactical_bc = plan.get("tactical_behavior_clone", {})
    replay_dir = abs_path(bc.get("replay_dir", "training/replays"))
    if tactical_bc.get("enabled", False):
        replay_dir = abs_path(tactical_bc.get("replay_dir", "training/replays"))
    replay_report = inspect_replay_directory(replay_dir) if replay_dir.exists() else None
    replay_files = replay_report.file_count if replay_report else 0
    replay_rows = replay_report.row_count if replay_report else 0
    replay_bytes = sum(path.stat().st_size for path in replay_report.files) if replay_report else 0
    online = plan.get("online_self_play", {})
    tactical_ppo = plan.get("tactical_ppo", {})
    multi_gpu = plan.get("multi_gpu", {})
    return {
        "profile_id": profile.get("profile_id"),
        "plan_id": plan.get("plan_id"),
        "bc_enabled": bool(bc.get("enabled", False)),
        "tactical_bc_enabled": bool(tactical_bc.get("enabled", False)),
        "online_self_play_enabled": bool(online.get("enabled", False)),
        "tactical_ppo_enabled": bool(tactical_ppo.get("enabled", False)),
        "multi_gpu_enabled": bool(multi_gpu.get("enabled", False)),
        "multi_gpu_config": multi_gpu.get("config"),
        "online_requires_step_ipc": bool(online.get("requires_step_ipc", True)),
        "replay_dir": str(replay_dir),
        "replay_files": replay_files,
        "replay_rows": replay_rows,
        "replay_bytes": replay_bytes,
        "replay_schema_row_counts": replay_report.schema_row_counts if replay_report else {},
        "replay_map_row_counts": replay_report.map_row_counts if replay_report else {},
        "replay_invalid_line_count": replay_report.invalid_line_count if replay_report else 0,
        "replay_invalid_lines": [line.format() for line in replay_report.invalid_lines] if replay_report else [],
    }


def run_collect(profile_id: str, plan: dict[str, Any], execute: bool) -> int:
    collect = plan.get("collect", {})
    config = StageCollectConfig(
        profile=profile_id,
        stage=collect.get("stage", "all"),
        record_replay=bool(collect.get("record_replay", True)),
        matches=collect.get("matches"),
        seconds=collect.get("seconds"),
        seed=collect.get("seed"),
        godot=collect.get("godot"),
        agent_controller=collect.get("agent_controller"),
        agent_model_id=collect.get("agent_model_id"),
        agents=collect.get("agents"),
        reward_profile_id=collect.get("reward_profile_id"),
        training_spawn_policy=collect.get("training_spawn_policy"),
        replay_dir=collect.get("replay_dir"),
    )
    if not execute:
        print(" ".join(build_stage_command(config, execute=False)))
        return 0
    return run_stage_collection(config, execute=True)


def run_bc(plan: dict[str, Any], execute: bool, swanlab_mode: str | None) -> int:
    bc = plan.get("behavior_clone", {})
    tactical_bc = plan.get("tactical_behavior_clone", {})
    if tactical_bc.get("enabled", False):
        config = TacticalBehaviorCloneConfig(
            replay_dir=abs_path(tactical_bc.get("replay_dir", "training/replays")),
            output_dir=abs_path(tactical_bc.get("output_dir", "training/artifacts/runs/hybrid_tactical_bc")),
            epochs=int(tactical_bc.get("epochs", 40)),
            batch_size=int(tactical_bc.get("batch_size", 1024)),
            hidden=int(tactical_bc.get("hidden", 192)),
            lr=float(tactical_bc.get("lr", 3e-4)),
            val_ratio=float(tactical_bc.get("val_ratio", 0.2)),
            seed=int(tactical_bc.get("seed", 20260708)),
            max_samples=tactical_bc.get("max_samples"),
            decision_key=str(tactical_bc.get("decision_key", "teacher_decision")),
            swanlab_mode=swanlab_mode or str(tactical_bc.get("swanlab_mode", "offline")),
            swanlab_project=str(tactical_bc.get("swanlab_project", "pulsearena-hybrid")),
            run_name=str(tactical_bc.get("run_name", "hybrid_tactical_bc")),
        )
        if not execute:
            print(json.dumps({"tactical_behavior_clone": config.__dict__}, default=str, ensure_ascii=False, indent=2))
            return 0
        result = train_tactical_behavior_clone(config)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if bc.get("enabled", False):
        print("Error: Legacy raw-action behavior cloning is no longer supported.")
        print("Please enable 'tactical_behavior_clone' in your training plan.")
        return 1
    print("Behavior clone phase disabled by plan.")
    return 0


def run_tactical_ppo(
    plan: dict[str, Any],
    execute: bool,
    overrides: dict[str, Any] | None = None,
) -> int:
    tactical = plan.get("tactical_ppo", {})
    if not tactical.get("enabled", False):
        print("Tactical PPO phase disabled by plan.")
        return 0
    overrides = overrides or {}
    config = TacticalOnlineConfig(
        output_dir=abs_path(overrides.get("output_dir", tactical.get("output_dir", "training/artifacts/runs/hybrid_tactical_v2_ppo_pilot"))),
        profile_id=str(plan.get("profile_id", "local_constrained")),
        stage=str(tactical.get("stage", "01_foundation_combat")),
        map_id=str(tactical.get("map_id", "dungeon")),
        map_ids=tuple(str(value) for value in tactical.get("map_ids", [])),
        mode=str(tactical.get("mode", "ffa")),
        agents=int(tactical.get("agents", 2)),
        opponent_controller=str(tactical.get("opponent_controller", "self_play")),
        training_spawn_policy=str(tactical.get("training_spawn_policy", "safe")),
        seconds=int(tactical.get("seconds", 20)),
        seed=int(overrides.get("seed", tactical.get("seed", 20260801))),
        rollout_steps=int(overrides.get("rollout_steps", tactical.get("rollout_steps", 32))),
        total_env_steps=int(overrides.get("total_env_steps", tactical.get("total_env_steps", 512))),
        tick_skip=int(overrides.get("tick_skip", tactical.get("tick_skip", 4))),
        hidden=int(tactical.get("hidden", 192)),
        recurrent=bool(tactical.get("recurrent", True)),
        rnn_hidden=tactical.get("rnn_hidden"),
        lr=float(tactical.get("lr", 3e-4)),
        ppo_clip_ratio=float(tactical.get("clip_ratio", 0.2)),
        ppo_value_coef=float(tactical.get("value_coef", 0.5)),
        ppo_entropy_coef=float(tactical.get("entropy_coef", 0.01)),
        ppo_max_grad_norm=float(tactical.get("max_grad_norm", 0.5)),
        ppo_update_epochs=int(tactical.get("update_epochs", 4)),
        ppo_minibatch_size=int(tactical.get("minibatch_size", 1024)),
        ppo_mixed_precision=bool(tactical.get("mixed_precision", True)),
        device=tactical.get("device"),
        reward_profile_id=str(tactical.get("reward_profile_id", "baseline")),
        bc_checkpoint=abs_path(tactical["bc_checkpoint"]) if tactical.get("bc_checkpoint") else None,
        resume_checkpoint=(
            abs_path(overrides.get("resume_checkpoint", tactical.get("resume_checkpoint")))
            if overrides.get("resume_checkpoint", tactical.get("resume_checkpoint"))
            else None
        ),
        godot=tactical.get("godot"),
        port=int(overrides.get("port", tactical.get("port", 8767))),
        require_cuda=bool(tactical.get("require_cuda", True)),
    )
    if not execute:
        print(json.dumps({"tactical_ppo": asdict_for_json(config)}, ensure_ascii=False, indent=2))
        return 0
    result = train_tactical_ppo(config)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def run_multi_gpu(
    plan: dict[str, Any],
    *,
    config_path: str | None,
    execute: bool,
    max_parallel: int | None,
    fail_fast: bool,
) -> int:
    multi_gpu = plan.get("multi_gpu", {})
    if not multi_gpu.get("enabled", False) and not config_path:
        print("Multi-GPU phase disabled by plan.")
        return 0
    resolved_path = resolve_multi_gpu_config(config_path, plan)
    config = load_multi_gpu_config(resolved_path)
    tasks = build_tasks(config, root=ROOT)
    if not execute:
        print(format_dry_run(tasks))
        return 0
    configured_parallel = config.get("max_parallel_tasks")
    result = run_tasks(
        tasks,
        max_parallel=max_parallel or (int(configured_parallel) if configured_parallel else None),
        fail_fast=fail_fast,
    )
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


def asdict_for_json(config: TacticalOnlineConfig) -> dict[str, Any]:
    return {
        key: str(value) if isinstance(value, Path) else value
        for key, value in config.__dict__.items()
    }


def main() -> int:
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    parser = argparse.ArgumentParser(description="Unified Pulse Arena training pipeline.")
    parser.add_argument("--profile", default="local_constrained")
    parser.add_argument("--plan", default=None, help="Plan id or JSON path. Defaults by profile.")
    parser.add_argument("--phase", choices=["validate", "collect", "bc", "ppo", "ppo-multi", "all"], default="validate")
    parser.add_argument("--execute", action="store_true", help="Actually run mutating phases. Without this, print dry-run information.")
    parser.add_argument("--swanlab-mode", choices=["disabled", "offline", "online", "local"], default=None)
    parser.add_argument("--multi-gpu-config", default=None, help="Multi-GPU task config path or id.")
    parser.add_argument("--max-parallel", type=int, default=None)
    parser.add_argument("--no-fail-fast", action="store_true")
    parser.add_argument("--output-dir", default=None, help="Override tactical PPO output directory.")
    parser.add_argument("--port", type=int, default=None, help="Override tactical PPO Godot worker port.")
    parser.add_argument("--seed", type=int, default=None, help="Override tactical PPO random seed.")
    parser.add_argument("--rollout-steps", type=int, default=None)
    parser.add_argument("--total-env-steps", type=int, default=None)
    parser.add_argument("--tick-skip", type=int, default=None)
    parser.add_argument("--resume-checkpoint", default=None)
    args = parser.parse_args()

    profile = resolve_profile(args.profile)
    plan = resolve_plan(args.plan, profile["profile_id"])
    summary = validate(profile, plan)
    if args.phase == "validate":
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0
    try:
        if args.phase in ("collect", "all"):
            code = run_collect(profile["profile_id"], plan, args.execute)
            if code != 0:
                return code
        if args.phase in ("bc", "all"):
            code = run_bc(plan, args.execute, args.swanlab_mode)
            if code != 0:
                return code
        if args.phase == "ppo-multi":
            return run_multi_gpu(
                plan,
                config_path=args.multi_gpu_config,
                execute=args.execute,
                max_parallel=args.max_parallel,
                fail_fast=not args.no_fail_fast,
            )
        if args.phase in ("ppo", "all"):
            if plan.get("tactical_ppo", {}).get("enabled", False):
                return run_tactical_ppo(
                    plan,
                    args.execute,
                    {
                        key: value
                        for key, value in {
                            "output_dir": args.output_dir,
                            "port": args.port,
                            "seed": args.seed,
                            "rollout_steps": args.rollout_steps,
                            "total_env_steps": args.total_env_steps,
                            "tick_skip": args.tick_skip,
                            "resume_checkpoint": args.resume_checkpoint,
                        }.items()
                        if value is not None
                    },
                )
            print("Error: Legacy raw-action PPO is no longer supported in the active training pipeline.")
            print("Please enable 'tactical_ppo' in your training plan.")
            return 1
    except StepIPCUnavailableError as exc:
        print(json.dumps({"error": "step_ipc_unavailable", "message": str(exc)}, ensure_ascii=False, indent=2))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
