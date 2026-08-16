from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.core.replay_integrity import ReplayIntegrityError, inspect_replay_directory, require_valid_replays


def hybrid_row(map_id: int) -> dict[str, object]:
    return {
        "replay_schema": "hybrid_replay_v2",
        "observation": {"map": {"map_id": map_id}},
        "tactical_features": [0.0] * 142,
        "teacher_decision": {},
    }


class ReplayIntegrityTests(unittest.TestCase):
    def test_reports_valid_rows_and_map_distribution(self) -> None:
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            (replay_dir / "dungeon.hybrid_v2.jsonl").write_text(
                "\n".join(json.dumps(hybrid_row(map_id)) for map_id in (0, 0, 1)) + "\n",
                encoding="utf-8",
            )

            report = inspect_replay_directory(replay_dir)

            self.assertTrue(report.is_valid)
            self.assertEqual(report.file_count, 1)
            self.assertEqual(report.row_count, 3)
            self.assertEqual(report.map_row_counts, {"dungeon": 2, "sky_city": 1})
            self.assertEqual(report.schema_row_counts, {"hybrid_replay_v2": 3})

    def test_rejects_truncated_final_json_line_before_training(self) -> None:
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            (replay_dir / "truncated.hybrid_v2.jsonl").write_text(
                json.dumps(hybrid_row(0)) + "\n{\"replay_schema\":",
                encoding="utf-8",
            )

            report = inspect_replay_directory(replay_dir)

            self.assertFalse(report.is_valid)
            self.assertEqual(report.row_count, 1)
            self.assertEqual(report.invalid_line_count, 1)
            with self.assertRaisesRegex(ReplayIntegrityError, "truncated.hybrid_v2.jsonl:2"):
                require_valid_replays(replay_dir)

    def test_ignores_quarantine_directory(self) -> None:
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            (replay_dir / "complete.hybrid_v2.jsonl").write_text(json.dumps(hybrid_row(2)) + "\n", encoding="utf-8")
            quarantine = replay_dir / "quarantine"
            quarantine.mkdir()
            (quarantine / "corrupt.hybrid_v2.jsonl").write_text("{bad", encoding="utf-8")

            report = inspect_replay_directory(replay_dir)

            self.assertTrue(report.is_valid)
            self.assertEqual(report.file_count, 1)
            self.assertEqual(report.map_row_counts, {"jungle": 1})

