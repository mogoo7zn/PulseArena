from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class CheckpointEntry:
    path: str
    stage: str
    env_steps: int
    score: float
    created_at: float


class CheckpointArchive:
    def __init__(self, archive_path: Path, keep: int = 24) -> None:
        self.archive_path = archive_path
        self.keep = keep
        self.entries: list[CheckpointEntry] = []
        self.load()

    def load(self) -> None:
        if not self.archive_path.exists():
            self.entries = []
            return
        data = json.loads(self.archive_path.read_text(encoding="utf-8"))
        self.entries = [CheckpointEntry(**entry) for entry in data.get("entries", [])]

    def save(self) -> None:
        self.archive_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": 1, "entries": [entry.__dict__ for entry in self.entries]}
        self.archive_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    def add(self, path: Path, stage: str, env_steps: int, score: float) -> None:
        self.entries.append(CheckpointEntry(str(path), stage, int(env_steps), float(score), time.time()))
        self.entries.sort(key=lambda entry: (entry.score, entry.env_steps), reverse=True)
        self.entries = self.entries[: self.keep]
        self.save()

    def sample(self, ratio: float, rng: random.Random | None = None) -> list[CheckpointEntry]:
        if not self.entries:
            return []
        rng = rng or random.Random()
        count = max(1, int(round(len(self.entries) * ratio)))
        return rng.sample(self.entries, k=min(count, len(self.entries)))

    def to_dict(self) -> dict[str, Any]:
        return {"entries": [entry.__dict__ for entry in self.entries], "keep": self.keep}
