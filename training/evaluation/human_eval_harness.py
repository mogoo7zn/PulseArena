#!/usr/bin/env python3
"""Record human vs Hybrid Tactical matches and write hybrid_replay_v2 JSONL rows.

Stage 6 (docs/plan/06-持续学习闭环.md §2.1) needs a way to convert human
playthroughs back into the same hybrid_replay_v2 format the BC trainer
consumes, so the continual BC re-run can use them as teacher labels.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from training.inference.serve_agent import (  # noqa: E402  (path side-effect)
    ServeAgentProcess,
    StrengthProfileNotSupportedError,
)


DEFAULT_OUTPUT_DIR = ROOT / "training" / "data" / "replays" / "human_eval_continual"


def _append_replay_rows(
    rows: list[dict[str, Any]],
    output_path: Path,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def record_gameplay_as_replay(
    player_id: str,
    game_id: str,
    difficulty: str,
    map_id: str,
    decisions: list[dict[str, Any]],
    label_source: str = "human_playthrough",
    label_weight: float = 1.0,
    output_path: Path | None = None,
) -> Path:
    """Convert a single human gameplay session into hybrid_replay_v2 rows.

    Each `decisions` entry must carry at minimum:
        {"obs": ..., "tactical_features": [...], "action_masks": {...},
         "teacher_decision": {...}, "timestamp": float}
    """
    rows: list[dict[str, Any]] = []
    for step in decisions:
        rows.append(
            {
                "episode_id": game_id,
                "match_id": game_id,
                "player_id": player_id,
                "map_id": map_id,
                "mode_id": 0,
                "timestamp": step.get("timestamp", 0.0),
                "observation_schema_version": 2,
                "observation": step["obs"],
                "tactical_features": step["tactical_features"],
                "action_masks": step["action_masks"],
                "teacher_decision": step["teacher_decision"],
                "teacher_label_version": "human_eval_v1",
                "label_source": label_source,
                "label_weight": label_weight,
                "outcome": step.get("outcome", {}),
                "difficulty": difficulty,
            }
        )
    target = output_path or (DEFAULT_OUTPUT_DIR / f"{time.strftime('%Y%m%d')}.hybrid_v2.jsonl")
    _append_replay_rows(rows, target)
    return target


def replay_filter(
    input_dir: Path,
    output_dir: Path,
    min_game_duration_seconds: float = 30.0,
    drop_fallback_only: bool = True,
) -> int:
    """Filter human_eval replay rows by the quality gate from §2.2.

    Returns the number of rows written.
    """
    import statistics

    input_dir = input_dir.resolve()
    output_dir = output_dir.resolve()
    if not input_dir.exists():
        raise FileNotFoundError(input_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    by_episode: dict[str, list[dict[str, Any]]] = {}
    for path in sorted(input_dir.glob("*.hybrid_v2.jsonl")):
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                row = json.loads(line)
                by_episode.setdefault(row["episode_id"], []).append(row)

    kept = 0
    written = 0
    for episode_id, rows in by_episode.items():
        rows.sort(key=lambda r: r["timestamp"])
        timestamps = [r["timestamp"] for r in rows]
        duration = (timestamps[-1] - timestamps[0]) if timestamps else 0.0
        has_fallback = any(r.get("fallback_used", False) for r in rows)
        if duration < min_game_duration_seconds:
            continue
        if drop_fallback_only and has_fallback and not any(
            r.get("outcome", {}).get("winner_player_id") == r.get("player_id")
            for r in rows
        ):
            continue
        out_path = output_dir / f"{episode_id}.hybrid_v2.jsonl"
        with out_path.open("w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                written += 1
        kept += 1

    return written


def strength_tier_monitor(log_dir: Path, output: Path, window_days: int = 7) -> dict[str, Any]:
    """Read recent human-eval JSONL records and report per-tier win rates.

    See 06-持续学习闭环.md §4.1 for the metric definitions.
    """
    import datetime as _dt

    cutoff = _dt.datetime.now() - _dt.timedelta(days=window_days)
    tiers = ["easy", "casual", "normal", "strong", "elite"]
    rates: dict[str, float | None] = {t: None for t in tiers}
    counts: dict[str, int] = {t: 0 for t in tiers}

    if not log_dir.exists():
        raise FileNotFoundError(log_dir)

    for path in log_dir.glob("*.jsonl"):
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                record = json.loads(line)
                played_at = _dt.datetime.fromisoformat(record["date"])
                if played_at < cutoff:
                    continue
                tier = record.get("difficulty")
                if tier not in tiers:
                    continue
                counts[tier] += 1
                if counts[tier] == 1:
                    rates[tier] = 0.0
                if record.get("winner") == "player":
                    rates[tier] = (rates[tier] or 0.0) + (1.0 / counts[tier]) * (
                        counts[tier] - 1
                    )

    target = {
        "easy":   (0.85, 1.00),
        "casual": (0.65, 0.85),
        "normal": (0.50, 0.75),
        "strong": (0.20, 0.35),
        "elite":  (0.05, 0.20),
    }
    out_of_range: list[str] = []
    for tier, (lo, hi) in target.items():
        r = rates[tier]
        if r is None:
            continue
        if not (lo <= r <= hi):
            out_of_range.append(f"{tier}={r:.3f} (target {lo}-{hi})")

    payload = {
        "window_days": window_days,
        "rates": rates,
        "counts": counts,
        "out_of_range": out_of_range,
        "monotonicity_violated": any(
            (rates[tiers[i]] is not None)
            and (rates[tiers[i + 1]] is not None)
            and (rates[tiers[i]] <= rates[tiers[i + 1]])
            for i in range(len(tiers) - 1)
        ),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_filter = sub.add_parser("filter", help="Apply the §2.2 quality gate to a human_eval directory.")
    p_filter.add_argument("--input-dir", type=Path, required=True)
    p_filter.add_argument("--output-dir", type=Path, required=True)
    p_filter.add_argument("--min-game-duration", type=float, default=30.0)
    p_filter.add_argument("--drop-fallback-only", action="store_true", default=True)

    p_monitor = sub.add_parser("monitor", help="Read human-eval records and emit tier suggestion.")
    p_monitor.add_argument("--log-dir", type=Path, required=True)
    p_monitor.add_argument("--output", type=Path, required=True)
    p_monitor.add_argument("--window-days", type=int, default=7)

    p_record = sub.add_parser("record-smoke", help="Emit a tiny synthetic replay row to verify the writer.")
    p_record.add_argument("--output", type=Path, required=True)
    p_record.add_argument("--player-id", type=str, default="smoke_tester")
    p_record.add_argument("--game-id", type=str, default="smoke_game_001")
    p_record.add_argument("--difficulty", type=str, default="normal")
    p_record.add_argument("--map-id", type=str, default="dungeon")

    args = parser.parse_args()

    if args.cmd == "filter":
        written = replay_filter(
            input_dir=args.input_dir,
            output_dir=args.output_dir,
            min_game_duration_seconds=args.min_game_duration,
            drop_fallback_only=args.drop_fallback_only,
        )
        print(json.dumps({"written_rows": written}))
        return 0
    if args.cmd == "monitor":
        payload = strength_tier_monitor(
            log_dir=args.log_dir,
            output=args.output,
            window_days=args.window_days,
        )
        print(json.dumps(payload, indent=2))
        return 0
    if args.cmd == "record-smoke":
        decisions = [
            {
                "timestamp": i * 0.5,
                "obs": {"self": {"health_ratio": 1.0}},
                "tactical_features": [0.0] * 142,
                "action_masks": {
                    "fire_mode": [True] * 6,
                    "movement_mode": [True] * 12,
                    "skill_mode": [True] * 6,
                    "target_slot": [True] * 7,
                },
                "teacher_decision": {"protocol_version": 2, "fire_mode": 1},
                "outcome": {},
            }
            for i in range(40)
        ]
        path = record_gameplay_as_replay(
            player_id=args.player_id,
            game_id=args.game_id,
            difficulty=args.difficulty,
            map_id=args.map_id,
            decisions=decisions,
            output_path=args.output,
        )
        print(json.dumps({"wrote": str(path)}))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
