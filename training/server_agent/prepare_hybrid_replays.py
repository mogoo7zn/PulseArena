#!/usr/bin/env python3
"""Downsample physics-rate Hybrid Tactical v2 replay rows to decision-rate rows.

The script keeps the first row for each (episode, player, 1/decision_hz time
bucket).  It never overwrites a non-empty output directory; use a new output
directory for every dataset revision so source data remains recoverable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def output_name(source: Path) -> str:
    return f"{source.stem}_{short_hash(str(source.resolve()))}.hybrid_v2.jsonl"


def prepare(input_dir: Path, output_dir: Path, decision_hz: float, max_rows: int | None) -> dict[str, Any]:
    if input_dir.resolve() == output_dir.resolve():
        raise SystemExit("input-dir and output-dir must be different")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"Refusing to overwrite non-empty output directory: {output_dir}")
    sources = sorted(input_dir.rglob("*.hybrid_v2.jsonl")) if input_dir.exists() else []
    if not sources:
        raise SystemExit(f"No hybrid replay files found in: {input_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    total_input = 0
    total_output = 0
    total_invalid = 0
    per_file: list[dict[str, Any]] = []
    limit_hit = False
    for source in sources:
        seen_buckets: set[tuple[str, str, int]] = set()
        kept = 0
        source_rows = 0
        output_path = output_dir / output_name(source)
        with source.open("r", encoding="utf-8", errors="replace") as reader, output_path.open("w", encoding="utf-8") as writer:
            for line in reader:
                if not line.strip():
                    continue
                total_input += 1
                source_rows += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    total_invalid += 1
                    continue
                if not isinstance(row, dict) or row.get("replay_schema") != "hybrid_replay_v2":
                    total_invalid += 1
                    continue
                try:
                    timestamp = float(row.get("timestamp", -1.0))
                except (TypeError, ValueError):
                    total_invalid += 1
                    continue
                if timestamp < 0.0 or not isinstance(row.get("teacher_decision"), dict):
                    total_invalid += 1
                    continue
                episode = str(row.get("episode_id", row.get("match_id", source.name)))
                player = str(row.get("player_id", "unknown"))
                bucket = int(timestamp * decision_hz + 1e-9)
                key = (episode, player, bucket)
                if key in seen_buckets:
                    continue
                seen_buckets.add(key)
                writer.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
                kept += 1
                total_output += 1
                if max_rows is not None and total_output >= max_rows:
                    limit_hit = True
                    break
        if kept == 0:
            output_path.unlink()
        per_file.append({"source": str(source), "output": str(output_path), "input_rows": source_rows, "kept_rows": kept})
        if limit_hit:
            break

    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "decision_hz": decision_hz,
        "input_rows": total_input,
        "output_rows": total_output,
        "dropped_rows": total_input - total_output,
        "invalid_rows": total_invalid,
        "limit_hit": limit_hit,
        "files": per_file,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--decision-hz", type=float, default=15.0)
    parser.add_argument("--max-rows", type=int, default=None)
    parser.add_argument("--output", type=Path, default=None, help="Optional dataset manifest JSON path.")
    args = parser.parse_args()
    if args.decision_hz <= 0:
        raise SystemExit("decision-hz must be positive")
    if args.max_rows is not None and args.max_rows <= 0:
        raise SystemExit("max-rows must be positive when supplied")

    report = prepare(args.input_dir, args.output_dir, args.decision_hz, args.max_rows)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
