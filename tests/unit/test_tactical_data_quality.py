from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np

from training.core.encoding import HybridReplayArrays
from training.core.tactical_bc_trainer import split_data
from training.server.tactical_data_quality import audit_tactical_data, build_episode_split


def valid_row(episode_id: str = "episode-1") -> dict[str, object]:
    return {
        "replay_schema": "hybrid_replay_v2",
        "episode_id": episode_id,
        "random_seed": 7,
        "map_id": 1,
        "mode_id": 2,
        "tactical_features": [0.0] * 142,
        "action_masks": {
            "target_slot": [True] + [False] * 6,
            "movement_mode": [True] + [False] * 11,
            "fire_mode": [True] + [False] * 5,
            "skill_mode": [True] + [False] * 5,
        },
        "teacher_decision": {
            "target_slot": 0,
            "movement_mode": 0,
            "fire_mode": 0,
            "skill_mode": 0,
        },
        "fallback_used": False,
    }


def replay_arrays() -> HybridReplayArrays:
    size = 4
    return HybridReplayArrays(
        tactical_features=np.asarray([[float(index)] * 142 for index in range(size)], dtype=np.float32),
        target_slots=np.zeros(size, dtype=np.int64),
        movement_modes=np.zeros(size, dtype=np.int64),
        fire_modes=np.zeros(size, dtype=np.int64),
        skill_modes=np.zeros(size, dtype=np.int64),
        target_masks=np.ones((size, 7), dtype=np.bool_),
        movement_masks=np.ones((size, 12), dtype=np.bool_),
        fire_masks=np.ones((size, 6), dtype=np.bool_),
        skill_masks=np.ones((size, 6), dtype=np.bool_),
        label_weights=np.ones(size, dtype=np.float32),
        confidence_targets=np.ones(size, dtype=np.float32),
        action_masks=[{} for _ in range(size)],
        files=[],
    )


class TacticalDataQualityTests(unittest.TestCase):
    def test_episode_split_never_places_one_episode_in_two_partitions(self):
        rows = [{"episode_id": "e1"}, {"episode_id": "e1"}, {"episode_id": "e2"}]
        split = build_episode_split(rows, holdout_ratio=0.5, seed=7)
        self.assertTrue(split["train"].isdisjoint(split["dev"]))
        self.assertTrue("e1" in split["train"] or "e1" in split["dev"])

    def test_audit_fails_when_a_head_has_no_label_coverage(self):
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            report = audit_tactical_data(replay_dir, replay_dir / "report.json")
        self.assertEqual(report["result"], "fail")

    def test_audit_writes_coverage_rates_and_label_histograms(self):
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            replay_file = replay_dir / "sample.hybrid_v2.jsonl"
            replay_file.write_text(json.dumps(valid_row()) + "\n", encoding="utf-8")
            output = replay_dir / "reports" / "quality.json"
            report = audit_tactical_data(replay_dir, output)
            written = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(report["result"], "pass")
        self.assertEqual(written, report)
        self.assertEqual(report["summary"]["episode_count"], 1)
        self.assertEqual(report["summary"]["fallback_rate"], 0.0)
        self.assertEqual(report["teacher_label_distribution"]["target_slot"], {"0": 1})

    def test_audit_rejects_non_boolean_mask_elements_as_malformed(self):
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            row = valid_row()
            row["action_masks"]["target_slot"][1] = "yes"
            (replay_dir / "sample.hybrid_v2.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
            report = audit_tactical_data(replay_dir, replay_dir / "report.json")

        self.assertEqual(report["result"], "fail")
        self.assertIn("malformed_rows=1", report["failures"])

    def test_audit_keeps_legal_head_coverage_when_skill_label_is_illegal(self):
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            row = valid_row()
            row["teacher_decision"].pop("skill_mode")
            (replay_dir / "sample.hybrid_v2.jsonl").write_text(json.dumps(row) + "\n", encoding="utf-8")
            report = audit_tactical_data(replay_dir, replay_dir / "report.json")

        labels = report["teacher_label_distribution"]
        self.assertEqual(labels["target_slot"], {"0": 1})
        self.assertEqual(labels["movement_mode"], {"0": 1})
        self.assertEqual(labels["fire_mode"], {"0": 1})
        self.assertEqual(labels["skill_mode"], {})
        self.assertIn("absent_head_coverage=skill_mode", report["failures"])

    def test_audit_ignores_nested_replays_that_bc_loader_does_not_read(self):
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            nested = replay_dir / "nested"
            nested.mkdir()
            (nested / "sample.hybrid_v2.jsonl").write_text(json.dumps(valid_row()) + "\n", encoding="utf-8")
            report = audit_tactical_data(replay_dir, replay_dir / "report.json")

        self.assertEqual(report["summary"]["file_count"], 0)
        self.assertEqual(report["result"], "fail")

    def test_bc_split_data_keeps_an_episode_entirely_in_one_dataset(self):
        train, dev = split_data(replay_arrays(), val_ratio=0.5, seed=7, episode_ids=["e1", "e1", "e2", "e2"])
        train_episodes = {"e1" if int(row[0]) < 2 else "e2" for row in train.tensors[0].numpy()}
        dev_episodes = {"e1" if int(row[0]) < 2 else "e2" for row in dev.tensors[0].numpy()}
        self.assertTrue(train_episodes.isdisjoint(dev_episodes))


if __name__ == "__main__":
    unittest.main()
