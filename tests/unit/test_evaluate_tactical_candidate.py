from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.evaluate_tactical_candidate import (
    evaluate_candidate,
    evaluate_gate_summary,
    selected_seeds,
)


class TacticalCandidateEvaluationTests(unittest.TestCase):
    def test_gate_report_fails_when_holdout_environment_death_rate_is_too_high(self) -> None:
        report = evaluate_gate_summary(
            metrics={"holdout_environment_death_rate": 0.07},
            gates={"holdout_max_environment_death_rate": 0.06},
        )
        self.assertEqual(report["result"], "fail")
        self.assertEqual(report["gates"]["holdout_max_environment_death_rate"]["actual"], 0.07)

    def test_evaluator_uses_only_configured_holdout_seeds(self) -> None:
        matrix = {"fixed_seed_sets": {"holdout": [91, 92, 93], "dev": [1]}}
        self.assertEqual(selected_seeds(matrix, "holdout"), [91, 92, 93])

    def test_evaluate_candidate_writes_json_and_chinese_markdown_without_promoting_catalog(self) -> None:
        calls = []

        def fake_runner(job):
            calls.append(job)
            return {
                "win_rate": 0.8,
                "top1_rate": 0.5,
                "environment_death_rate": 0.01,
                "empty_fire_rate": 0.02,
            }

        matrix = {
            "fixed_seed_sets": {"holdout": [101, 102], "dev": [1]},
            "maps": ["dungeon"],
            "modes": [{"id": "ffa_1v1", "mode": "ffa", "agents": 2, "seconds": 3}],
            "promotion_gates": {
                "scripted_hard_all_maps_min_win_rate_1v1": 0.72,
                "scripted_hard_all_maps_min_top1_rate_ffa": 0.40,
                "holdout_max_environment_death_rate": 0.06,
                "holdout_max_empty_fire_rate": 0.10,
            },
        }
        with TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            manifest = output_dir / "candidate.json"
            manifest.write_text(json.dumps({"model_id": "candidate", "checkpoint": "candidate.pt"}), encoding="utf-8")
            result = evaluate_candidate(manifest, matrix, output_dir, match_runner=fake_runner)

            self.assertEqual(result["result"], "pass")
            self.assertEqual([call["seed"] for call in calls], [101, 102])
            self.assertTrue((output_dir / "evaluation.json").exists())
            report_text = (output_dir / "evaluation_report_zh.md").read_text(encoding="utf-8")
            self.assertIn("固定 seed 评测报告", report_text)
            self.assertIn("不执行 catalog 晋级", report_text)
            self.assertFalse((output_dir / "model_catalog.json").exists())


if __name__ == "__main__":
    unittest.main()
