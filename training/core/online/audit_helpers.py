"""Small helpers for the rollout audit: counter updates, fallback reasons, mode names."""
from __future__ import annotations

from typing import Any

from training.core.online.config import FIRE_MODE_NAMES, MOVEMENT_MODE_NAMES


def _update_cumulative_audit(
    audit: dict[str, Any],
    public_key: str,
    private_key: str,
    player_id: str,
    values: Any,
    *,
    value_type: type,
) -> dict[str, int | float]:
    if not isinstance(values, dict):
        return {}
    per_player = audit.setdefault(private_key, {})
    current = {
        str(key): value_type(value)
        for key, value in values.items()
        if isinstance(value, (int, float))
    }
    previous = per_player.get(player_id, {})
    if not current:
        per_player[player_id] = {}
        return {}
    public_totals = audit.setdefault(public_key, {})
    deltas: dict[str, int | float] = {}
    for key, value in current.items():
        previous_value = previous.get(key, 0)
        delta = value - previous_value if value >= previous_value else value
        if delta != 0:
            public_totals[key] = public_totals.get(key, 0) + delta
            deltas[key] = delta
    per_player[player_id] = current
    return deltas


def _fallback_reason_from_player_data(player_data: dict[str, Any]) -> str:
    executed = player_data.get("executed_decision", {})
    if isinstance(executed, dict) and str(executed.get("target_name", "")) == "SCRIPTED_TARGET":
        return "scripted_target"
    return "script_fallback"


def _increment_audit_counter(
    audit: dict[str, Any], public_key: str, counter_key: str, amount: int | float
) -> None:
    counters = audit.setdefault(public_key, {})
    counters[counter_key] = counters.get(counter_key, 0) + amount


def _increment_nested_audit_counter(
    audit: dict[str, Any],
    public_key: str,
    group_key: str,
    counter_key: str,
    amount: int | float,
) -> None:
    groups = audit.setdefault(public_key, {})
    counters = groups.setdefault(group_key, {})
    counters[counter_key] = counters.get(counter_key, 0) + amount


def _decision_mode_name(names: tuple[str, ...], value: int) -> str:
    return names[value] if 0 <= value < len(names) else f"INVALID_{value}"


def _mode_name_for_movement(movement_mode: int) -> str:
    return _decision_mode_name(MOVEMENT_MODE_NAMES, movement_mode)


def _mode_name_for_fire(fire_mode: int) -> str:
    return _decision_mode_name(FIRE_MODE_NAMES, fire_mode)