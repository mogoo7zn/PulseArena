#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from training.rl.bc_trainer import BehaviorCloneConfig, train_behavior_clone
from training.rl.encoding import count_replay_rows
from training.rl.godot_env import StageCollectConfig, StepIPCUnavailableError, build_stage_command, run_stage_collection
from training.rl.online_trainer import OnlinePPOConfig, train_online_ppo
from training.rl.ppo import PPOHyperParams
from training.rl.tactical_bc_trainer import TacticalBehaviorCloneConfig, train_tactical_behavior_clone
from training.rl.tactical_online_trainer import TacticalOnlineConfig, train_tactical_ppo


PROFILES_DIR = ROOT / "training" / "configs" / "profiles"
PLANS_DIR = ROOT / "training" / "configs" / "training_plans"


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
    replay_files, replay_rows, replay_bytes = count_replay_rows(replay_dir) if replay_dir.exists() else (0, 0, 0)
    online = plan.get("online_self_play", {})
    tactical_ppo = plan.get("tactical_ppo", {})
    return {
        "profile_id": profile.get("profile_id"),
        "plan_id": plan.get("plan_id"),
        "bc_enabled": bool(bc.get("enabled", False)),
        "tactical_bc_enabled": bool(tactical_bc.get("enabled", False)),
        "online_self_play_enabled": bool(online.get("enabled", False)),
        "tactical_ppo_enabled": bool(tactical_ppo.get("enabled", False)),
        "online_requires_step_ipc": bool(online.get("requires_step_ipc", True)),
        "replay_dir": str(replay_dir),
        "replay_files": replay_files,
        "replay_rows": replay_rows,
        "replay_bytes": replay_bytes,
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
        agent_controller=collect.get("agent_controller"),
        agent_model_id=collect.get("agent_model_id"),
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
            output_dir=abs_path(tactical_bc.get("output_dir", "training/runs/hybrid_tactical_bc")),
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
    if not bc.get("enabled", False):
        print("Behavior clone phase disabled by plan.")
        return 0
    config = BehaviorCloneConfig(
        replay_dir=abs_path(bc.get("replay_dir", "training/replays")),
        output_dir=abs_path(bc.get("output_dir", "training/runs/bc")),
        epochs=int(bc.get("epochs", 20)),
        batch_size=int(bc.get("batch_size", 512)),
        hidden=int(bc.get("hidden", 256)),
        lr=float(bc.get("lr", 3e-4)),
        val_ratio=float(bc.get("val_ratio", 0.2)),
        seed=int(bc.get("seed", 20260627)),
        max_samples=bc.get("max_samples"),
        swanlab_mode=swanlab_mode or str(bc.get("swanlab_mode", "offline")),
        swanlab_project=str(bc.get("swanlab_project", "pulsearena")),
        run_name=str(bc.get("run_name", "bc")),
    )
    if not execute:
        print(json.dumps({"behavior_clone": config.__dict__}, default=str, ensure_ascii=False, indent=2))
        return 0
    result = train_behavior_clone(config)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def run_online_self_play(profile: dict[str, Any], plan: dict[str, Any], execute: bool, swanlab_mode: str | None) -> int:
    online = plan.get("online_self_play", {})
    if not online.get("enabled", False):
        print("Online self-play phase disabled by plan. PPO/MAPPO config is present but not active.")
        return 0
    if not execute:
        print(json.dumps({"online_self_play": online}, ensure_ascii=False, indent=2))
        return 0
    ppo = online.get("ppo", {})
    algo = profile.get("algorithm", {})
    model = algo.get("model", {})
    config = OnlinePPOConfig(
        output_dir=abs_path(online.get("output_dir", "training/runs/online_ppo")),
        profile_id=str(profile.get("profile_id")),
        stage=str(online.get("stages", ["01_foundation_combat"])[0]),
        map_id=str(online.get("map_id", "dungeon")),
        mode=str(online.get("mode", "ffa")),
        agents=int(online.get("agents", 2)),
        seconds=int(online.get("seconds", 20)),
        seed=int(online.get("seed", 30000)),
        rollout_steps=int(online.get("rollout_steps", algo.get("rollout_length", 128))),
        total_env_steps=int(online.get("total_env_steps", 2048)),
        tick_skip=int(online.get("tick_skip", 4)),
        hidden=int(model.get("entity_hidden_size", 256)),
        rnn_hidden=int(model.get("rnn_hidden_size", 128)),
        value_hidden=int(model.get("critic_hidden_size", 256)),
        swanlab_mode=swanlab_mode or str(online.get("swanlab_mode", "offline")),
        swanlab_project="pulsearena-online",
        run_name=f"{plan.get('plan_id')}_online_ppo",
    )
    params = PPOHyperParams(
        clip_ratio=float(ppo.get("clip_ratio", 0.2)),
        value_coef=float(ppo.get("value_coef", 0.5)),
        entropy_coef=float(ppo.get("entropy_coef", 0.01)),
        max_grad_norm=float(ppo.get("max_grad_norm", 0.5)),
        update_epochs=int(algo.get("update_epochs", 4)),
        minibatch_size=int(algo.get("minibatch_size", 1024)),
        mixed_precision=bool(algo.get("mixed_precision", True)),
    )
    result = train_online_ppo(config, params)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def run_tactical_ppo(plan: dict[str, Any], execute: bool) -> int:
    tactical = plan.get("tactical_ppo", {})
    if not tactical.get("enabled", False):
        print("Tactical PPO phase disabled by plan.")
        return 0
    config = TacticalOnlineConfig(
        output_dir=abs_path(tactical.get("output_dir", "training/runs/hybrid_tactical_v2_ppo_pilot")),
        profile_id=str(plan.get("profile_id", "local_constrained")),
        stage=str(tactical.get("stage", "01_foundation_combat")),
        map_id=str(tactical.get("map_id", "dungeon")),
        mode=str(tactical.get("mode", "ffa")),
        agents=int(tactical.get("agents", 2)),
        seconds=int(tactical.get("seconds", 20)),
        seed=int(tactical.get("seed", 20260801)),
        rollout_steps=int(tactical.get("rollout_steps", 32)),
        total_env_steps=int(tactical.get("total_env_steps", 512)),
        tick_skip=int(tactical.get("tick_skip", 4)),
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
        godot=tactical.get("godot"),
        port=int(tactical.get("port", 8767)),
        require_cuda=bool(tactical.get("require_cuda", True)),
    )
    if not execute:
        print(json.dumps({"tactical_ppo": asdict_for_json(config)}, ensure_ascii=False, indent=2))
        return 0
    result = train_tactical_ppo(config)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


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
    parser.add_argument("--phase", choices=["validate", "collect", "bc", "ppo", "all"], default="validate")
    parser.add_argument("--execute", action="store_true", help="Actually run mutating phases. Without this, print dry-run information.")
    parser.add_argument("--swanlab-mode", choices=["disabled", "offline", "online", "local"], default=None)
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
        if args.phase in ("ppo", "all"):
            if plan.get("tactical_ppo", {}).get("enabled", False):
                return run_tactical_ppo(plan, args.execute)
            return run_online_self_play(profile, plan, args.execute, args.swanlab_mode)
    except StepIPCUnavailableError as exc:
        print(json.dumps({"error": "step_ipc_unavailable", "message": str(exc)}, ensure_ascii=False, indent=2))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
