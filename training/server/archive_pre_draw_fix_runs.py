"""Safely archive generated tactical runs produced before the draw outcome fix.

The allowlists below are deliberately closed: this tool never discovers runs by
pattern and never considers deployed model manifests or checkpoints.
"""

from __future__ import annotations

import argparse
from pathlib import Path


RUN_ARCHIVE_SOURCES = (
    "hybrid_tactical_v2_ppo_pilot",
    "hybrid_tactical_v2_8gpu_parallel_pilot",
    "hybrid_tactical_v2_reward_diagnostic_2048",
    "hybrid_tactical_v2_8gpu_foundation_diagnostic_8192",
    "hybrid_tactical_v2_audit_explainability_smoke",
    "hybrid_tactical_v2_audit_explainability_smoke_v2",
    "hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192",
    "hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536",
    "hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144",
)

EVALUATION_ARCHIVE_SOURCES = (
    "hybrid_tactical_v2_ppo_resume_candidate_20260802_service_smoke",
    "hybrid_tactical_v2_ppo_resume_candidate_20260802_service_dev8",
    "hybrid_tactical_v2_ppo_resume_candidate_20260802_paired_smoke1",
    "hybrid_tactical_v2_ppo_resume_candidate_20260802_paired_dev8",
)

ARCHIVE_ROOT = Path("training/artifacts/runs/archived/pre_draw_fix")


def build_archive_plan(root: Path) -> list[tuple[Path, Path]]:
    """Return existing, allowlisted source directories and their archive paths."""
    root = root.resolve()
    archive_root = root / ARCHIVE_ROOT
    plan: list[tuple[Path, Path]] = []

    for name in RUN_ARCHIVE_SOURCES:
        source = root / "training/runs" / name
        if source.is_dir():
            plan.append((source, archive_root / "runs" / name))

    for name in EVALUATION_ARCHIVE_SOURCES:
        source = root / "training/artifacts/runs/evaluations" / name
        if source.is_dir():
            plan.append((source, archive_root / "evaluations" / name))

    return plan


def apply_archive_plan(plan: list[tuple[Path, Path]]) -> None:
    """Move a prevalidated plan, refusing destination collisions before any move."""
    for source, destination in plan:
        if not source.is_dir():
            raise FileNotFoundError(source)
        if destination.exists():
            raise FileExistsError(destination)

    for source, destination in plan:
        destination.parent.mkdir(parents=True, exist_ok=True)
        source.rename(destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root")
    parser.add_argument("--apply", action="store_true", help="perform the reviewed moves")
    args = parser.parse_args()

    plan = build_archive_plan(args.root)
    if not plan:
        print("No allowlisted pre-draw-fix generated runs are pending archive.")
        return 0

    for source, destination in plan:
        print(f"{source} -> {destination}")
    if not args.apply:
        print("Dry run only. Re-run with --apply to move these directories.")
        return 0

    apply_archive_plan(plan)
    print(f"Archived {len(plan)} allowlisted pre-draw-fix directories.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
