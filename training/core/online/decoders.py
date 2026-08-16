"""Per-player helpers that decode ``TacticalActionBatch`` into decisions/tensors."""
from __future__ import annotations

from typing import Any

import torch

from training.core.online.audit import _increment_audit_counter  # noqa: F401 (re-export)
from training.core.ppo.types import TacticalActionBatch


def _reward_totals(snapshot: dict[str, Any]) -> dict[str, float]:
    return {
        str(player_id): float(player.get("reward_total", 0.0))
        for player_id, player in snapshot.get("players", {}).items()
    }


def _actions_to_decisions(
    actions: TacticalActionBatch,
    player_ids: list[str],
    audit: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    decisions: dict[str, dict[str, Any]] = {}
    for index, player_id in enumerate(player_ids):
        decision_id = len(audit["decision_ids"]) + 1
        audit["decision_ids"].append(decision_id)
        decisions[player_id] = {
            "protocol": 2,
            "target_slot": int(actions.target_slot[index].item()),
            "movement_mode": int(actions.movement_mode[index].item()),
            "fire_mode": int(actions.fire_mode[index].item()),
            "skill_mode": int(actions.skill_mode[index].item()),
            "confidence": 1.0,
            "decision_id": decision_id,
        }
    return decisions


def _slice_action(actions: TacticalActionBatch, index: int) -> TacticalActionBatch:
    return TacticalActionBatch(
        target_slot=actions.target_slot[index].detach().cpu(),
        movement_mode=actions.movement_mode[index].detach().cpu(),
        fire_mode=actions.fire_mode[index].detach().cpu(),
        skill_mode=actions.skill_mode[index].detach().cpu(),
        log_prob=actions.log_prob[index].detach().cpu(),
        entropy=actions.entropy[index].detach().cpu(),
    )