"""Static metadata about a loaded agent model."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class AgentModelInfo:
    model_id: str
    kind: str
    checkpoint: Path
    input_dim: int
    hidden: int
    device: str
    metrics: dict[str, Any]