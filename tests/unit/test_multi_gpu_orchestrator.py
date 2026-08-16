from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.server.multi_gpu_orchestrator import (
    GPUAllocationError,
    build_tasks,
    format_dry_run,
    parse_gpu_ids,
    run_tasks,
)


class MultiGPUOrchestratorTests(unittest.TestCase):
    def test_pressure_curriculum_workers_use_only_gpus_4_through_7(self) -> None:
        config = json.loads(
            (Path.cwd() / "training/configs/multi_gpu/legal_window_pressure_gpu4_7_event_gated.json").read_text(encoding="utf-8")
        )
        tasks = config["tasks"]

        self.assertEqual({task["gpu_ids"][0] for task in tasks}, {4, 5, 6, 7})
        self.assertTrue(all("pressure_curriculum_resource" in task["task_id"] for task in tasks))
        self.assertTrue(all("pressure_curriculum_resource" in " ".join(task["command"]) for task in tasks))

    def test_ballistic_repair_workers_are_isolated_on_gpus_4_through_7(self) -> None:
        config = json.loads(
            (Path.cwd() / "training/configs/multi_gpu/legal_window_pressure_ballistic_repair_gpu4_7.json").read_text(encoding="utf-8")
        )
        tasks = config["tasks"]

        self.assertEqual({task["gpu_ids"][0] for task in tasks}, {4, 5, 6, 7})
        self.assertEqual({task["command"][task["command"].index("--port") + 1] for task in tasks}, {"18961", "18962", "18963", "18964"})
        self.assertTrue(all("--total-env-steps" in task["command"] and "16384" in task["command"] for task in tasks))

    def test_parse_gpu_ids_accepts_csv_ranges_and_lists(self) -> None:
        self.assertEqual(parse_gpu_ids("0,2-4"), (0, 2, 3, 4))
        self.assertEqual(parse_gpu_ids([7, 5, 5]), (5, 7))

    def test_build_tasks_injects_visible_devices_and_rejects_conflicts(self) -> None:
        config = {
            "log_dir": "training/artifacts/runs/orchestrator-test/logs",
            "env": {"MPLCONFIGDIR": "{root}/test-results/matplotlib", "RUN_ID": "{task_id}"},
            "tasks": [
                {
                    "task_id": "worker_a",
                    "gpu_ids": [0, 2],
                    "command": ["{python}", "-c", "print('a')"],
                },
                {
                    "task_id": "worker_b",
                    "gpu_ids": [1],
                    "command": ["{python}", "-c", "print('b')"],
                },
            ],
        }
        tasks = build_tasks(config, root=Path("/tmp/pulsearena-test-root"), python_executable="/opt/python")
        self.assertEqual(tasks[0].gpu_ids, (0, 2))
        self.assertEqual(tasks[0].env["CUDA_VISIBLE_DEVICES"], "0,2")
        self.assertEqual(tasks[0].env["MPLCONFIGDIR"], "/tmp/pulsearena-test-root/test-results/matplotlib")
        self.assertEqual(tasks[0].env["RUN_ID"], "worker_a")
        self.assertEqual(tasks[1].env["RUN_ID"], "worker_b")
        self.assertEqual(tasks[0].command[0], "/opt/python")
        self.assertEqual(tasks[0].log_path, Path("/tmp/pulsearena-test-root/training/artifacts/runs/orchestrator-test/logs/worker_a.log"))

        config["tasks"][1]["gpu_ids"] = [2]
        with self.assertRaises(GPUAllocationError):
            build_tasks(config)

    def test_dry_run_is_explicit_and_contains_each_task(self) -> None:
        config = {
            "tasks": [
                {
                    "task_id": "worker_a",
                    "gpu_ids": "3",
                    "command": ["{python}", "-c", "print('a')"],
                }
            ]
        }
        tasks = build_tasks(config, root=Path("/tmp/root"), python_executable=sys.executable)
        rendered = format_dry_run(tasks)
        self.assertIn("worker_a", rendered)
        self.assertIn("CUDA_VISIBLE_DEVICES=3", rendered)
        self.assertIn(sys.executable, rendered)

    def test_failure_propagates_nonzero_and_stops_pending_tasks(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = {
                "log_dir": "logs",
                "max_parallel_tasks": 1,
                "fail_fast": True,
                "tasks": [
                    {
                        "task_id": "fails",
                        "gpu_ids": [0],
                        "command": ["{python}", "-c", "raise SystemExit(7)"],
                    },
                    {
                        "task_id": "must_not_start",
                        "gpu_ids": [1],
                        "command": ["{python}", "-c", "raise SystemExit(0)"],
                    },
                ],
            }
            tasks = build_tasks(config, root=root, python_executable=sys.executable)
            result = run_tasks(tasks, max_parallel=1, fail_fast=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.results["fails"].returncode, 7)
            self.assertTrue(result.results["must_not_start"].skipped)
            self.assertTrue((root / "logs" / "fails.log").exists())


if __name__ == "__main__":
    unittest.main()
