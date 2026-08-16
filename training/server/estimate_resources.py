#!/usr/bin/env python3
"""Print curriculum step budgets and GPU profiles."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CURRICULUM = ROOT / "training" / "configs" / "curriculum.json"
ESTIMATE = ROOT / "training" / "configs" / "gpu_resource_estimate.json"
PROFILES_DIR = ROOT / "training" / "configs" / "profiles"


def fmt_steps(value: int) -> str:
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    return str(value)


def load_profile(profile_id: str | None) -> dict | None:
    if not profile_id:
        return None
    path = PROFILES_DIR / f"{profile_id}.json"
    if not path.exists():
        raise SystemExit(f"Unknown profile: {profile_id}")
    return json.loads(path.read_text(encoding="utf-8"))


def effective_stage(stage: dict, profile: dict | None) -> dict:
    merged = dict(stage)
    overrides = (profile or {}).get("stage_overrides", {}).get(stage["id"], {})
    merged.update(overrides)
    return merged


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", help="Training profile id from training/configs/profiles")
    args = parser.parse_args()

    curriculum = json.loads(CURRICULUM.read_text(encoding="utf-8"))
    estimate = json.loads(ESTIMATE.read_text(encoding="utf-8"))
    selected_profile = load_profile(args.profile)

    base_total_steps = sum(int(stage["target_env_steps"]) for stage in curriculum["stages"])
    effective_stages = [effective_stage(stage, selected_profile) for stage in curriculum["stages"]]
    effective_total_steps = sum(int(stage["target_env_steps"]) for stage in effective_stages)
    print(f"Base curriculum target env steps: {fmt_steps(base_total_steps)}")
    if selected_profile:
        print(f"Selected profile target env steps: {fmt_steps(effective_total_steps)} ({selected_profile['profile_id']})")
    print()
    print("Stages:")
    for stage in effective_stages:
        print(f"- {stage['id']}: {fmt_steps(int(stage['target_env_steps']))} steps, maps={','.join(stage['maps'])}, mode={stage['mode']}")
    print()
    print("GPU profiles:")
    for profile in estimate["profiles"]:
        print(f"- {profile['profile_id']}: {profile['hardware_class']}; {profile['expected_wall_time']}")
    print()
    print("Recommendation:")
    rec = estimate["recommendation"]
    print(f"- Start here: {rec['start_here']}")
    print(f"- Local target: {rec['local_target']}")
    print(f"- Full target: {rec['full_target']}")
    print(f"- First benchmark: {rec['first_benchmark']}")
    print()
    print("Training profile configs:")
    for path in sorted(PROFILES_DIR.glob("*.json")):
        profile = json.loads(path.read_text(encoding="utf-8"))
        algo = profile.get("algorithm", {})
        hardware = profile.get("hardware_class", {})
        print(f"- {profile['profile_id']}: {hardware.get('kind', 'unknown')}, rollout={algo.get('rollout_length')}, minibatch={algo.get('minibatch_size')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
