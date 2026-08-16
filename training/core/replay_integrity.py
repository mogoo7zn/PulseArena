"""Strict, read-only validation for replay datasets used by offline training.

Collection can be interrupted while the final JSONL record is being written.
Training must fail before loading any samples in that situation, with a precise
file and line number, instead of silently training a partial dataset or raising
an opaque JSON exception halfway through a run.
"""

from __future__ import annotations

import json
import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MAP_NAMES = {
    0: "dungeon",
    1: "sky_city",
    2: "jungle",
    3: "mist_world",
}


class ReplayIntegrityError(ValueError):
    """Raised when a replay directory is unsafe to use for training."""


@dataclass(frozen=True)
class InvalidReplayLine:
    path: Path
    line_number: int
    reason: str

    def format(self) -> str:
        return f"{self.path.name}:{self.line_number}: {self.reason}"


@dataclass(frozen=True)
class ReplayIntegrityReport:
    replay_dir: Path
    files: tuple[Path, ...]
    row_count: int
    schema_row_counts: dict[str, int]
    map_row_counts: dict[str, int]
    invalid_lines: tuple[InvalidReplayLine, ...]

    @property
    def file_count(self) -> int:
        return len(self.files)

    @property
    def invalid_line_count(self) -> int:
        return len(self.invalid_lines)

    @property
    def is_valid(self) -> bool:
        return not self.invalid_lines

    def summary(self) -> dict[str, Any]:
        return {
            "replay_dir": str(self.replay_dir),
            "file_count": self.file_count,
            "row_count": self.row_count,
            "schema_row_counts": self.schema_row_counts,
            "map_row_counts": self.map_row_counts,
            "invalid_line_count": self.invalid_line_count,
            "invalid_lines": [line.format() for line in self.invalid_lines],
        }


def replay_files(replay_dir: Path) -> tuple[Path, ...]:
    """Return only top-level JSONL assets; quarantined data is never training data."""
    return tuple(sorted(path for path in replay_dir.glob("*.jsonl") if path.is_file()))


def _map_name(row: dict[str, Any]) -> str | None:
    map_value = (row.get("observation") or {}).get("map", {}).get("map_id")
    try:
        return MAP_NAMES.get(int(map_value), f"unknown:{map_value}")
    except (TypeError, ValueError):
        return None


def inspect_replay_directory(replay_dir: Path) -> ReplayIntegrityReport:
    """Read every JSONL record and return auditable dataset facts without mutation."""
    directory = Path(replay_dir)
    files = replay_files(directory)
    schemas: Counter[str] = Counter()
    maps: Counter[str] = Counter()
    invalid: list[InvalidReplayLine] = []
    rows = 0
    for path in files:
        with path.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as error:
                    invalid.append(InvalidReplayLine(path, line_number, error.msg))
                    continue
                if not isinstance(row, dict):
                    invalid.append(InvalidReplayLine(path, line_number, "JSON record must be an object"))
                    continue
                rows += 1
                schemas[str(row.get("replay_schema", "missing"))] += 1
                map_name = _map_name(row)
                if map_name is not None:
                    maps[map_name] += 1
    return ReplayIntegrityReport(
        replay_dir=directory,
        files=files,
        row_count=rows,
        schema_row_counts=dict(sorted(schemas.items())),
        map_row_counts=dict(sorted(maps.items())),
        invalid_lines=tuple(invalid),
    )


def require_valid_replays(replay_dir: Path) -> ReplayIntegrityReport:
    """Return the report or stop training with actionable corruption details."""
    report = inspect_replay_directory(replay_dir)
    if report.invalid_lines:
        details = "; ".join(line.format() for line in report.invalid_lines[:5])
        remainder = "" if report.invalid_line_count <= 5 else f"; plus {report.invalid_line_count - 5} more"
        raise ReplayIntegrityError(
            f"Replay integrity check failed for {report.replay_dir}: {details}{remainder}. "
            "Move incomplete files to a quarantine/ subdirectory, then resume collection."
        )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect replay JSONL integrity before offline training.")
    parser.add_argument("replay_dir", type=Path)
    args = parser.parse_args()
    report = inspect_replay_directory(args.replay_dir)
    print(json.dumps(report.summary(), ensure_ascii=False, indent=2))
    return 0 if report.is_valid else 2


if __name__ == "__main__":
    raise SystemExit(main())
