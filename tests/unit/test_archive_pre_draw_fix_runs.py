from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.server.archive_pre_draw_fix_runs import apply_archive_plan, build_archive_plan


def _make_training_tree(root: Path) -> None:
    for relative in (
        "training/runs/hybrid_tactical_v2_ppo_pilot/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu0/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_reward_diagnostic_2048/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_8gpu_foundation_diagnostic_8192/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_audit_explainability_smoke/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_audit_explainability_smoke_v2/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/metrics.jsonl",
        "training/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/metrics.jsonl",
        "training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_paired_dev8/evaluation.json",
        "training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260804_paired_dev8/evaluation.json",
        "training/models/model_catalog.json",
        "training/artifacts/checkpoints/hybrid/hybrid_tactical_v2_ppo_resume_candidate_20260802.pt",
    ):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture", encoding="utf-8")


class ArchivePreDrawFixRunsTests(unittest.TestCase):
    def test_archive_plan_moves_only_pre_draw_fix_runs(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            _make_training_tree(root)

            plan = build_archive_plan(root)
            sources = {source.relative_to(root).as_posix() for source, _destination in plan}

            self.assertIn("training/runs/hybrid_tactical_v2_ppo_pilot", sources)
            self.assertIn(
                "training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_paired_dev8",
                sources,
            )
            self.assertTrue(all("20260804" not in source for source in sources))

    def test_archive_plan_never_targets_catalog_or_checkpoint(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            _make_training_tree(root)

            plan = build_archive_plan(root)

            self.assertTrue(all("training/models" not in str(source) for source, _destination in plan))
            self.assertTrue(all("training/checkpoints" not in str(source) for source, _destination in plan))

    def test_apply_refuses_an_existing_archive_destination(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            _make_training_tree(root)
            plan = build_archive_plan(root)
            source, destination = plan[0]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.mkdir()

            with self.assertRaises(FileExistsError):
                apply_archive_plan([(source, destination)])
            self.assertTrue(source.exists())


if __name__ == "__main__":
    unittest.main()
