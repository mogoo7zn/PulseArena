#!/usr/bin/env python3
"""Audit Hybrid Tactical v2 JSONL replays without loading PyTorch.

The report deliberately measures temporal duplication because the current
Godot recorder writes physics-rate frames while decisions update at a lower
rate.  A high duplicate ratio is a warning about validation leakage, not an
automatic indication that a replay is corrupt.
"""
from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from training.core.replay_integrity import replay_files


DECISION_FIELDS = ("target_slot", "movement_mode", "fire_mode", "skill_mode")
MASK_FIELDS = {
    "target_slot": "target_slot",
    "movement_mode": "movement_mode",
    "fire_mode": "fire_mode",
    "skill_mode": "skill_mode",
}


def percentage(numerator: int, denominator: int) -> float:
    return float(numerator) / float(denominator) if denominator else 0.0


def is_legal_label(row: dict[str, Any]) -> bool:
    decision = row.get("teacher_decision")
    masks = row.get("action_masks")
    if not isinstance(decision, dict) or not isinstance(masks, dict):
        return False
    for field in DECISION_FIELDS:
        index = decision.get(field)
        mask = masks.get(MASK_FIELDS[field])
        if not isinstance(index, int) or not isinstance(mask, list) or index < 0 or index >= len(mask) or not bool(mask[index]):
            return False
    return True


def decision_key(row: dict[str, Any]) -> str:
    decision = row.get("teacher_decision")
    if not isinstance(decision, dict):
        return ""
    return json.dumps({field: decision.get(field) for field in DECISION_FIELDS}, sort_keys=True, separators=(",", ":"))


def audit(replay_dir: Path) -> dict[str, Any]:
    # Keep this audit's dataset boundary identical to offline training: recovery
    # artifacts live in replay_dir/quarantine and are never valid samples.
    files = list(replay_files(replay_dir)) if replay_dir.exists() else []
    files = [path for path in files if path.name.endswith(".hybrid_v2.jsonl")]
    counts: Counter[str] = Counter()
    maps: Counter[str] = Counter()
    modes: Counter[str] = Counter()
    labels: dict[str, Counter[str]] = {field: Counter() for field in DECISION_FIELDS}
    last_by_stream: dict[tuple[str, str], str] = {}
    rows = 0
    parsed = 0
    parse_errors = 0
    schema_errors = 0
    illegal_labels = 0
    duplicate_pairs = 0
    compared_pairs = 0
    per_file: list[dict[str, Any]] = []

    for path in files:
        file_rows = 0
        file_errors = 0
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                rows += 1
                file_rows += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    file_errors += 1
                    continue
                if not isinstance(row, dict):
                    parse_errors += 1
                    file_errors += 1
                    continue
                parsed += 1
                if row.get("replay_schema") != "hybrid_replay_v2":
                    schema_errors += 1
                    continue
                counts["hybrid_rows"] += 1
                maps[str(row.get("map_id", "unknown"))] += 1
                modes[str(row.get("mode_id", "unknown"))] += 1
                if bool(row.get("fallback_used", False)):
                    counts["fallback_rows"] += 1
                if bool(row.get("safety_override", False)):
                    counts["safety_override_rows"] += 1
                if not is_legal_label(row):
                    illegal_labels += 1
                decision = row.get("teacher_decision", {})
                if isinstance(decision, dict):
                    for field in DECISION_FIELDS:
                        labels[field][str(decision.get(field, "missing"))] += 1

                stream = (str(row.get("episode_id", row.get("match_id", path.name))), str(row.get("player_id", "unknown")))
                key = decision_key(row)
                if stream in last_by_stream:
                    compared_pairs += 1
                    if last_by_stream[stream] == key:
                        duplicate_pairs += 1
                last_by_stream[stream] = key
        per_file.append({"path": str(path), "rows": file_rows, "parse_errors": file_errors})

    hybrid_rows = counts["hybrid_rows"]
    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "replay_dir": str(replay_dir),
        "files": per_file,
        "summary": {
            "file_count": len(files),
            "raw_rows": rows,
            "parsed_rows": parsed,
            "hybrid_rows": hybrid_rows,
            "parse_errors": parse_errors,
            "schema_errors": schema_errors,
            "illegal_teacher_labels": illegal_labels,
            "fallback_rows": counts["fallback_rows"],
            "fallback_rate": percentage(counts["fallback_rows"], hybrid_rows),
            "safety_override_rows": counts["safety_override_rows"],
            "safety_override_rate": percentage(counts["safety_override_rows"], hybrid_rows),
            "consecutive_equal_decision_pairs": duplicate_pairs,
            "consecutive_equal_decision_rate": percentage(duplicate_pairs, compared_pairs),
            "compared_decision_pairs": compared_pairs,
        },
        "map_distribution": dict(sorted(maps.items())),
        "mode_distribution": dict(sorted(modes.items())),
        "teacher_label_distribution": {field: dict(sorted(counter.items())) for field, counter in labels.items()},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--min-rows", type=int, default=1)
    parser.add_argument("--max-parse-errors", type=int, default=0)
    args = parser.parse_args()

    report = audit(args.replay_dir)
    summary = report["summary"]
    failures: list[str] = []
    if summary["hybrid_rows"] < args.min_rows:
        failures.append(f"hybrid_rows={summary['hybrid_rows']} is below min_rows={args.min_rows}")
    if summary["parse_errors"] > args.max_parse_errors:
        failures.append(f"parse_errors={summary['parse_errors']} exceeds max_parse_errors={args.max_parse_errors}")
    if summary["illegal_teacher_labels"]:
        failures.append(f"illegal_teacher_labels={summary['illegal_teacher_labels']}")
    report["result"] = "pass" if not failures else "fail"
    report["failures"] = failures
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
