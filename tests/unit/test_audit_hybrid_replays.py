from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.server.audit_hybrid_replays import audit


def replay_row(map_id: int = 0) -> dict[str, object]:
    return {
        "replay_schema": "hybrid_replay_v2",
        "map_id": map_id,
        "mode_id": 0,
        "player_id": 0,
        "teacher_decision": {
            "target_slot": 0,
            "movement_mode": 0,
            "fire_mode": 0,
            "skill_mode": 0,
        },
        "action_masks": {
            "target_slot": [True],
            "movement_mode": [True],
            "fire_mode": [True],
            "skill_mode": [True],
        },
    }


class AuditHybridReplaysTests(unittest.TestCase):
    def test_excludes_quarantine_from_audit_dataset(self) -> None:
        with TemporaryDirectory() as temporary:
            replay_dir = Path(temporary)
            (replay_dir / "complete.hybrid_v2.jsonl").write_text(json.dumps(replay_row()) + "\n", encoding="utf-8")
            quarantine = replay_dir / "quarantine"
            quarantine.mkdir()
            (quarantine / "corrupt.hybrid_v2.jsonl").write_text("{broken", encoding="utf-8")

            report = audit(replay_dir)

            self.assertEqual(report["summary"]["file_count"], 1)
            self.assertEqual(report["summary"]["hybrid_rows"], 1)
            self.assertEqual(report["summary"]["parse_errors"], 0)

