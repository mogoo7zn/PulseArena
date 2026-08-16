from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.evaluation.evaluate_tactical_candidate import (
    _evaluation_jobs,
    _service_match_config,
    _service_step_count,
    aggregate_tactical_snapshots,
    evaluate_candidate,
    evaluate_gate_summary,
    selected_seeds,
    validate_inference_device,
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

    def test_service_step_count_includes_countdown_before_match_clock(self) -> None:
        self.assertGreaterEqual(_service_step_count(seconds=12, ticks=8), 120)

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
            self.assertTrue(all(str(call["service_log_path"]).startswith(str(output_dir / "service_logs")) for call in calls))
            self.assertTrue((output_dir / "evaluation.json").exists())
            report_text = (output_dir / "evaluation_report_zh.md").read_text(encoding="utf-8")
            self.assertIn("固定 seed 评测报告", report_text)
            self.assertIn("不执行 catalog 晋级", report_text)
            self.assertFalse((output_dir / "model_catalog.json").exists())

    def test_aggregate_tactical_snapshots_reports_fire_conservatism_and_fallback_deltas(self) -> None:
        snapshots = [
            {
                "players": {
                    "0": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 1, "fire_name": "CONSERVATIVE"},
                        "reward_components": {"damage_dealt": 1.0, "environment_death": -0.75},
                        "diagnostics": {
                            "script_fallback": False,
                            "safety_override": False,
                            "fire_block_reason": "",
                            "fallback_counts": {"no_target_fire": 1},
                        },
                    },
                    "1": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 3, "fire_name": "BURST"},
                        "reward_components": {"damage_dealt": 2.0},
                        "diagnostics": {
                            "script_fallback": True,
                            "safety_override": True,
                            "fire_block_reason": "cooldown",
                            "fallback_counts": {"no_target_fire": 0},
                        },
                    },
                }
            },
            {
                "players": {
                    "0": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 2, "fire_name": "NORMAL"},
                        "reward_components": {"damage_dealt": 4.0, "environment_death": -0.75},
                        "diagnostics": {
                            "script_fallback": False,
                            "safety_override": True,
                            "fire_block_reason": "no_line_of_sight",
                            "fallback_counts": {"no_target_fire": 3},
                        },
                    },
                    "1": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 1, "fire_name": "CONSERVATIVE"},
                        "reward_components": {"damage_dealt": 2.0},
                        "diagnostics": {
                            "script_fallback": False,
                            "safety_override": False,
                            "fire_block_reason": "",
                            "fallback_counts": {"no_target_fire": 0},
                        },
                    },
                }
            },
        ]

        metrics = aggregate_tactical_snapshots(snapshots)

        self.assertEqual(metrics["samples"], 4.0)
        self.assertEqual(metrics["fire_mode_CONSERVATIVE_rate"], 0.5)
        self.assertEqual(metrics["fire_mode_NORMAL_rate"], 0.25)
        self.assertEqual(metrics["fire_mode_BURST_rate"], 0.25)
        self.assertEqual(metrics["fallback_rate"], 0.25)
        self.assertEqual(metrics["safety_override_rate"], 0.5)
        self.assertEqual(metrics["fire_blocked_rate"], 0.5)
        self.assertEqual(metrics["fire_block_reason_cooldown_rate"], 0.25)
        self.assertEqual(metrics["fire_block_reason_no_line_of_sight_rate"], 0.25)
        self.assertEqual(metrics["empty_fire_rate"], 0.75)
        self.assertEqual(metrics["environment_death_rate"], 0.25)
        self.assertEqual(metrics["damage_dealt"], 6.0)

    def test_aggregate_tactical_snapshots_reports_candidate_match_result_metrics(self) -> None:
        snapshots = [
            {
                "terminated": True,
                "info": {
                    "tactical_player_ids": [0],
                    "match_result": {
                        "mode": "ffa",
                        "team_mode": False,
                        "winner_player_id": 0,
                        "standings": [
                            {"player_id": 0, "team_id": 0, "score": 2, "kills": 1, "deaths": 0},
                            {"player_id": 1, "team_id": 1, "score": -1, "kills": 0, "deaths": 1},
                        ],
                        "team_scores": {"0": 2, "1": -1},
                    },
                },
                "players": {
                    "0": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 2, "fire_name": "NORMAL"},
                        "reward_components": {"win": 5.0},
                        "diagnostics": {"fallback_counts": {}},
                    },
                    "1": {"supports_tactical_decisions": False, "reward_components": {}},
                },
            }
        ]

        metrics = aggregate_tactical_snapshots(snapshots)

        self.assertEqual(metrics["win_rate"], 1.0)
        self.assertEqual(metrics["top1_rate"], 1.0)
        self.assertEqual(metrics["top2_rate"], 1.0)
        self.assertEqual(metrics["candidate_rank"], 1.0)
        self.assertEqual(metrics["candidate_score"], 2.0)
        self.assertEqual(metrics["candidate_score_margin"], 3.0)

    def test_aggregate_tactical_snapshots_does_not_count_score_tie_as_candidate_win(self) -> None:
        snapshots = [
            {
                "terminated": True,
                "info": {
                    "tactical_player_ids": [0],
                    "match_result": {
                        "mode": "ffa",
                        "team_mode": False,
                        "winner_player_id": 0,
                        "standings": [
                            {"player_id": 0, "team_id": 0, "score": 0, "kills": 0, "deaths": 0},
                            {"player_id": 1, "team_id": 1, "score": 0, "kills": 0, "deaths": 0},
                        ],
                        "team_scores": {"0": 0, "1": 0},
                    },
                },
                "players": {
                    "0": {
                        "supports_tactical_decisions": True,
                        "executed_decision": {"fire_mode": 1, "fire_name": "CONSERVATIVE"},
                        "reward_components": {"win": 5.0},
                        "diagnostics": {"fallback_counts": {}},
                    },
                    "1": {"supports_tactical_decisions": False, "reward_components": {}},
                },
            }
        ]

        metrics = aggregate_tactical_snapshots(snapshots)

        self.assertEqual(metrics["win_rate"], 0.0)
        self.assertEqual(metrics["top1_rate"], 0.0)
        self.assertEqual(metrics["top2_rate"], 1.0)
        self.assertEqual(metrics["candidate_score_margin"], 0.0)

    def test_aggregate_tactical_snapshots_does_not_count_team_score_tie_as_win(self) -> None:
        snapshots = [{
            "terminated": True,
            "info": {
                "tactical_player_ids": [0],
                "match_result": {
                    "mode": "team_2v2",
                    "team_mode": True,
                    "winner_player_id": -1,
                    "winner_team_id": -1,
                    "standings": [
                        {"player_id": 0, "team_id": 0, "score": 0},
                        {"player_id": 1, "team_id": 1, "score": 0},
                    ],
                    "team_scores": {"0": 0, "1": 0},
                },
            },
            "players": {
                "0": {"supports_tactical_decisions": True, "diagnostics": {"fallback_counts": {}}},
                "1": {"supports_tactical_decisions": False},
            },
        }]

        metrics = aggregate_tactical_snapshots(snapshots)

        self.assertEqual(metrics["team_win_rate"], 0.0)
        self.assertEqual(metrics["candidate_team_score_margin"], 0.0)

    def test_service_match_config_pairs_candidate_player_zero_against_scripted_baseline(self) -> None:
        config = _service_match_config(
            {
                "mode": "ffa",
                "agents": 2,
                "seconds": 12,
                "map_id": "dungeon",
                "model_id": "candidate-model",
                "seed": 90210,
            },
            model_port=18888,
        )

        self.assertEqual(config["agent_controller"], "scripted")
        self.assertEqual(config["agent_controller_overrides"], {"0": "hybrid"})
        self.assertEqual(config["agent_model_id_overrides"], {"0": "candidate-model"})
        self.assertEqual(config["agent_model_port"], 18888)

    def test_pressure_manifest_profile_reaches_service_match_config(self) -> None:
        jobs = _evaluation_jobs(
            Path("training/models/candidate.json"),
            {"model_id": "candidate-model", "reward_profile_id": "legal_window_pressure"},
            {"maps": ["dungeon"], "modes": [{"id": "ffa", "mode": "ffa", "agents": 2, "seconds": 12}]},
            [90210],
            None,
        )

        config = _service_match_config(jobs[0], model_port=18888)

        self.assertEqual(config["reward_profile_id"], "legal_window_pressure")

    def test_explicit_cuda_device_is_preserved_for_service_runner(self) -> None:
        self.assertEqual(validate_inference_device("cuda:4"), "cuda:4")


if __name__ == "__main__":
    unittest.main()
