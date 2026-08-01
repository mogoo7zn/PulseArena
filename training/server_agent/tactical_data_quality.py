#!/usr/bin/env python3
"""Audit Hybrid Tactical v2 replay data before tactical behavior cloning."""
from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping


DECISION_FIELDS = ("target_slot", "movement_mode", "fire_mode", "skill_mode")
MASK_SIZES = {"target_slot": 7, "movement_mode": 12, "fire_mode": 6, "skill_mode": 6}


def percentage(numerator: int, denominator: int) -> float:
    return float(numerator) / float(denominator) if denominator else 0.0


def episode_group_id(row: Mapping[str, Any], row_index: int = 0) -> str:
    """Return a stable episode group, falling back to the recorded seed."""
    episode_id = row.get("episode_id")
    if isinstance(episode_id, str) and episode_id.strip():
        return episode_id
    random_seed = row.get("random_seed")
    if isinstance(random_seed, int) and not isinstance(random_seed, bool):
        return f"seed:{random_seed}"
    return f"missing:{row_index}"


def build_episode_split(rows: Iterable[Mapping[str, Any]], holdout_ratio: float, seed: int) -> dict[str, set[str]]:
    """Split complete replay episodes deterministically; never shuffle rows."""
    if not 0.0 <= holdout_ratio < 1.0:
        raise ValueError("holdout_ratio must be in [0.0, 1.0)")
    episode_ids = sorted({episode_group_id(row, index) for index, row in enumerate(rows)})
    shuffled = list(episode_ids)
    random.Random(seed).shuffle(shuffled)
    dev_count = int(len(shuffled) * holdout_ratio)
    if holdout_ratio > 0.0 and len(shuffled) > 1:
        dev_count = max(1, dev_count)
        dev_count = min(dev_count, len(shuffled) - 1)
    dev = set(shuffled[:dev_count])
    return {"train": set(shuffled[dev_count:]), "dev": dev}


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _has_required_fields(row: Mapping[str, Any]) -> bool:
    if not isinstance(row.get("episode_id"), str) or not row["episode_id"].strip():
        return False
    if not _is_int(row.get("random_seed")):
        return False
    if not isinstance(row.get("tactical_features"), list) or len(row["tactical_features"]) != 142:
        return False
    if not all(type(value) in (int, float) and math.isfinite(float(value)) for value in row["tactical_features"]):
        return False
    if not isinstance(row.get("fallback_used"), bool):
        return False
    if "map_id" not in row or "mode_id" not in row:
        return False
    if not isinstance(row.get("teacher_decision"), dict) or not isinstance(row.get("action_masks"), dict):
        return False
    for field in DECISION_FIELDS:
        mask = row["action_masks"].get(field)
        if not isinstance(mask, list) or len(mask) != MASK_SIZES[field] or not all(type(value) is bool for value in mask):
            return False
    return True


def is_legal_label(row: Mapping[str, Any]) -> bool:
    decision = row.get("teacher_decision")
    masks = row.get("action_masks")
    if not isinstance(decision, dict) or not isinstance(masks, dict):
        return False
    for field in DECISION_FIELDS:
        label = decision.get(field)
        mask = masks.get(field)
        if not _is_int(label) or not isinstance(mask, list) or len(mask) != MASK_SIZES[field]:
            return False
        if label < 0 or label >= len(mask) or not bool(mask[label]):
            return False
    return True


def decision_key(row: Mapping[str, Any]) -> str:
    decision = row.get("teacher_decision")
    if not isinstance(decision, dict):
        return ""
    return json.dumps({field: decision.get(field) for field in DECISION_FIELDS}, sort_keys=True, separators=(",", ":"))


def _replay_files(replay_dir: Path) -> list[Path]:
    if not replay_dir.exists() or not replay_dir.is_dir():
        return []
    files = sorted(replay_dir.glob("*.hybrid_v2.jsonl"))
    return files or sorted(replay_dir.glob("*.jsonl"))


def audit_tactical_data(replay_dir: Path, output: Path) -> dict[str, Any]:
    """Audit replay JSONL and always write a self-contained JSON report."""
    replay_dir = Path(replay_dir)
    output = Path(output)
    files = _replay_files(replay_dir)
    maps: Counter[str] = Counter()
    modes: Counter[str] = Counter()
    labels = {field: Counter() for field in DECISION_FIELDS}
    failures: list[str] = []
    raw_rows = parsed_rows = valid_rows = malformed_rows = illegal_labels = 0
    fallback_rows = duplicate_pairs = compared_pairs = 0
    episode_ids: set[str] = set()
    last_decision: dict[tuple[str, str], str] = {}
    per_file: list[dict[str, Any]] = []

    if not files:
        failures.append("missing_input: no *.hybrid_v2.jsonl replay files found")

    for path in files:
        file_rows = file_malformed = 0
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                raw_rows += 1
                file_rows += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    malformed_rows += 1
                    file_malformed += 1
                    continue
                if not isinstance(row, dict) or row.get("replay_schema") != "hybrid_replay_v2" or not _has_required_fields(row):
                    malformed_rows += 1
                    file_malformed += 1
                    continue
                parsed_rows += 1
                decision = row["teacher_decision"]
                for field in DECISION_FIELDS:
                    label = decision.get(field)
                    if _is_int(label):
                        labels[field][str(label)] += 1
                if not is_legal_label(row):
                    illegal_labels += 1
                    continue

                valid_rows += 1
                episode_id = episode_group_id(row, line_number)
                episode_ids.add(episode_id)
                maps[str(row["map_id"])] += 1
                modes[str(row["mode_id"])] += 1
                if row["fallback_used"]:
                    fallback_rows += 1
                stream = (episode_id, str(row.get("player_id", "unknown")))
                key = decision_key(row)
                if stream in last_decision:
                    compared_pairs += 1
                    duplicate_pairs += int(last_decision[stream] == key)
                last_decision[stream] = key
        per_file.append({"path": str(path), "rows": file_rows, "malformed_rows": file_malformed})

    if malformed_rows:
        failures.append(f"malformed_rows={malformed_rows}")
    if illegal_labels:
        failures.append(f"missing_legal_labels={illegal_labels}")
    if not valid_rows:
        failures.append("missing_input: no valid hybrid_replay_v2 rows")
    absent_heads = [field for field in DECISION_FIELDS if not labels[field]]
    if absent_heads:
        failures.append(f"absent_head_coverage={','.join(absent_heads)}")

    report = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "replay_dir": str(replay_dir),
        "files": per_file,
        "summary": {
            "file_count": len(files),
            "raw_rows": raw_rows,
            "parsed_rows": parsed_rows,
            "valid_rows": valid_rows,
            "episode_count": len(episode_ids),
            "malformed_rows": malformed_rows,
            "illegal_teacher_labels": illegal_labels,
            "fallback_rows": fallback_rows,
            "fallback_rate": percentage(fallback_rows, valid_rows),
            "consecutive_equal_decision_pairs": duplicate_pairs,
            "compared_decision_pairs": compared_pairs,
            "consecutive_equal_decision_rate": percentage(duplicate_pairs, compared_pairs),
        },
        "map_distribution": dict(sorted(maps.items())),
        "mode_distribution": dict(sorted(modes.items())),
        "teacher_label_distribution": {field: dict(sorted(counter.items())) for field, counter in labels.items()},
        "result": "pass" if not failures else "fail",
        "failures": failures,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = audit_tactical_data(args.replay_dir, args.output)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["result"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
