from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from training.pipelines.train_pipeline import run_collect, run_tactical_ppo
from training.core.godot_env import StageCollectConfig, build_stage_command
from training.pipelines.run_stage import stage_jobs


class TrainPipelineTests(unittest.TestCase):
    def test_pressure_plan_uses_reachable_long_match_resource_curriculum(self) -> None:
        plan = json.loads(
            (Path.cwd() / "training/configs/training_plans/tactical_legal_window_pressure.json").read_text(encoding="utf-8")
        )

        self.assertEqual(plan["collect"]["training_spawn_policy"], "pressure_curriculum")
        self.assertEqual(plan["collect"]["seconds"], 60)
        self.assertEqual(plan["tactical_ppo"]["training_spawn_policy"], "pressure_curriculum")
        self.assertEqual(plan["tactical_ppo"]["seconds"], 60)
        self.assertEqual(plan["tactical_ppo"]["stage"], "pressure_curriculum_resource_60s")
        self.assertEqual(plan["tactical_ppo"]["total_env_steps"], 32768)

    def test_four_map_pressure_plan_keeps_one_common_training_contract(self) -> None:
        plan = json.loads(
            (Path.cwd() / "training/configs/training_plans/tactical_legal_window_pressure_four_map.json").read_text(encoding="utf-8")
        )

        tactical = plan["tactical_ppo"]
        self.assertEqual(plan["collect"]["stage"], "08_mixed_ffa_league")
        self.assertEqual(plan["collect"]["matches"] % 4, 0)
        self.assertEqual(tactical["map_ids"], ["dungeon", "sky_city", "jungle", "mist_world"])
        self.assertEqual(tactical["reward_profile_id"], "legal_window_pressure")
        self.assertEqual(tactical["opponent_controller"], "scripted")
        self.assertIn("four_map_foundation", tactical["output_dir"])
        self.assertIn("four_map_foundation", tactical["bc_checkpoint"])

    def test_repair_diagnostic_plan_keeps_high_playability_profile_on_gpu4(self) -> None:
        plan = json.loads(
            (
                Path.cwd()
                / "training/configs/training_plans/tactical_legal_window_pressure_four_map_repair_diagnostic.json"
            ).read_text(encoding="utf-8")
        )

        tactical = plan["tactical_ppo"]
        self.assertEqual(tactical["reward_profile_id"], "legal_window_pressure")
        self.assertEqual(tactical["map_ids"], ["dungeon", "sky_city", "jungle", "mist_world"])
        self.assertEqual(tactical["training_spawn_policy"], "pressure_curriculum")
        self.assertEqual(tactical["total_env_steps"], 32768)
        self.assertEqual(tactical["port"], 18945)
        self.assertIn("four_map_repair_diagnostic_gpu4", tactical["output_dir"])
        self.assertFalse(plan["multi_gpu"]["enabled"])

    def test_post_mask_diagnostic_keeps_four_maps_and_fresh_bc_artifacts(self) -> None:
        plan = json.loads(
            (
                Path.cwd()
                / "training/configs/training_plans/tactical_legal_window_pressure_four_map_post_mask_diagnostic.json"
            ).read_text(encoding="utf-8")
        )

        tactical = plan["tactical_ppo"]
        self.assertEqual(tactical["reward_profile_id"], "legal_window_pressure")
        self.assertEqual(tactical["map_ids"], ["dungeon", "sky_city", "jungle", "mist_world"])
        self.assertEqual(plan["collect"]["matches"], 32)
        self.assertIn("post_mask_diagnostic_bc", plan["collect"]["replay_dir"])
        self.assertIn("post_mask_diagnostic_bc", tactical["bc_checkpoint"])
        self.assertIn("post_mask_diagnostic_gpu4", tactical["output_dir"])
        self.assertEqual(tactical["total_env_steps"], 32768)

    def test_ballistic_repair_plan_uses_fresh_four_map_bc(self) -> None:
        plan = json.loads(
            (Path.cwd() / "training/configs/training_plans/tactical_legal_window_pressure_four_map_ballistic_repair.json").read_text(encoding="utf-8")
        )
        self.assertEqual(plan["collect"]["matches"], 32)
        self.assertEqual(plan["tactical_ppo"]["map_ids"], ["dungeon", "sky_city", "jungle", "mist_world"])
        self.assertIn("ballistic_repair_bc", plan["collect"]["replay_dir"])
        self.assertIn("ballistic_repair_bc", plan["tactical_ppo"]["bc_checkpoint"])
        self.assertEqual(plan["tactical_ppo"]["total_env_steps"], 16384)

    def test_resource_contest_plan_is_four_map_and_uses_only_the_training_curriculum(self) -> None:
        plan = json.loads(
            (Path.cwd() / "training/configs/training_plans/tactical_resource_contest_four_map_diagnostic.json").read_text(encoding="utf-8")
        )

        self.assertEqual(plan["collect"]["training_spawn_policy"], "resource_contest")
        self.assertEqual(plan["tactical_ppo"]["training_spawn_policy"], "resource_contest")
        self.assertEqual(plan["tactical_ppo"]["map_ids"], ["dungeon", "sky_city", "jungle", "mist_world"])
        self.assertEqual(plan["tactical_ppo"]["bc_checkpoint"], "training/artifacts/runs/four_map_foundation_bc/best_tactical_policy.pt")
        self.assertEqual(plan["tactical_ppo"]["total_env_steps"], 16384)

    def test_engagement_window_collection_forwards_profile_spawn_policy_and_isolated_replay_dir(self) -> None:
        command = build_stage_command(
            StageCollectConfig(
                profile="local_constrained",
                stage="03_cover_tactics",
                agents=4,
                reward_profile_id="legal_window_pressure",
                training_spawn_policy="engagement_window",
                godot=".tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64",
                replay_dir="training/data/replays/engagement_window_pressure_bc",
            ),
            execute=False,
        )

        self.assertIn("--reward-profile", command)
        self.assertIn("legal_window_pressure", command)
        self.assertIn("--replay-dir", command)
        self.assertIn("--training-spawn-policy", command)
        self.assertIn("engagement_window", command)
        self.assertIn(".tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64", command)
        self.assertIn("training/data/replays/engagement_window_pressure_bc", command)
        self.assertIn("--agents", command)
        self.assertIn("4", command)

    def test_tactical_ppo_dry_run_includes_reward_profile_id(self) -> None:
        plan = {
            "profile_id": "local_constrained",
            "tactical_ppo": {
                "enabled": True,
                "reward_profile_id": "legal_window_pressure",
                "output_dir": "training/artifacts/runs/pipeline-test",
                "require_cuda": False,
            },
        }

        stream = io.StringIO()
        with redirect_stdout(stream):
            code = run_tactical_ppo(plan, execute=False)

        self.assertEqual(code, 0)
        rendered = json.loads(stream.getvalue())
        self.assertEqual(rendered["tactical_ppo"]["reward_profile_id"], "legal_window_pressure")

    def test_stage_launcher_forwards_engagement_window_policy_to_godot(self) -> None:
        args = SimpleNamespace(
            seconds=20,
            matches=1,
            seed=31,
            difficulty=None,
            godot="godot",
            agents=2,
            agent_controller="hybrid",
            agent_model_id="hybrid_tactical_v1",
            agent_model_host=None,
            agent_model_port=None,
            agent_model_timeout_ms=None,
            record_replay=True,
            replay_dir="training/data/replays/engagement_window_pressure_bc",
            reward_profile="legal_window_pressure",
            training_spawn_policy="engagement_window",
        )
        commands = stage_jobs(
            {"id": "03_cover_tactics", "maps": ["dungeon"], "agents": 2, "seconds": 20, "mode": "ffa"},
            {"profile_id": "local_constrained"},
            args,
        )

        self.assertIn("--training-spawn-policy=engagement_window", commands[0])

    def test_tactical_ppo_dry_run_includes_bc_checkpoint(self) -> None:
        plan = {
            "profile_id": "local_constrained",
            "tactical_ppo": {
                "enabled": True,
                "output_dir": "training/artifacts/runs/pipeline-test",
                "bc_checkpoint": "training/artifacts/runs/hybrid_tactical_bc/best_tactical_policy.pt",
                "require_cuda": False,
            },
        }

        stream = io.StringIO()
        with redirect_stdout(stream):
            code = run_tactical_ppo(plan, execute=False)

        self.assertEqual(code, 0)
        rendered = json.loads(stream.getvalue())
        self.assertEqual(
            rendered["tactical_ppo"]["bc_checkpoint"],
            str(Path.cwd() / "training/artifacts/runs/hybrid_tactical_bc/best_tactical_policy.pt"),
        )

    def test_collect_uses_plan_pinned_godot_binary(self) -> None:
        plan = {
            "collect": {
                "godot": ".tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64",
                "training_spawn_policy": "engagement_window",
            }
        }
        with patch("training.pipelines.train_pipeline.run_stage_collection", return_value=0) as collect:
            self.assertEqual(run_collect("local_constrained", plan, execute=True), 0)

        self.assertEqual(
            collect.call_args.args[0].godot,
            ".tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64",
        )

    def test_tactical_ppo_dry_run_includes_resume_checkpoint_override(self) -> None:
        plan = {
            "profile_id": "local_constrained",
            "tactical_ppo": {
                "enabled": True,
                "output_dir": "training/artifacts/runs/pipeline-test",
                "bc_checkpoint": "training/artifacts/runs/hybrid_tactical_bc/best_tactical_policy.pt",
                "require_cuda": False,
            },
        }

        stream = io.StringIO()
        with redirect_stdout(stream):
            code = run_tactical_ppo(
                plan,
                execute=False,
                overrides={
                    "resume_checkpoint": "training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/gpu6/best_tactical_ppo.pt",
                },
            )

        self.assertEqual(code, 0)
        rendered = json.loads(stream.getvalue())
        self.assertEqual(
            rendered["tactical_ppo"]["resume_checkpoint"],
            str(Path.cwd() / "training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/gpu6/best_tactical_ppo.pt"),
        )


if __name__ == "__main__":
    unittest.main()
