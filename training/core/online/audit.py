"""Rollout transition audit + cumulative counter helpers for online PPO."""
from __future__ import annotations

from typing import Any

from training.core.online.audit_helpers import (
    _decision_mode_name,
    _fallback_reason_from_player_data,
    _increment_audit_counter,
    _increment_nested_audit_counter,
    _update_cumulative_audit,
)
from training.core.online.config import (
    FIRE_MODE_NAMES,
    MOVEMENT_MODE_NAMES,
    PROFILE_REWARD_COMPONENTS,
)


def _empty_audit_payload() -> dict[str, Any]:
    """All zero-valued counters and empty maps for a fresh audit."""
    return {
        "tactical_step_calls": 0,
        "raw_step_calls": 0,
        "transitions": 0,
        "episodes": 0,
        "fallback_count": 0,
        "safety_override_count": 0,
        "fallback_reasons": {},
        "safety_override_reasons": {},
        "fire_intent_count": 0,
        "fire_allowed_count": 0,
        "fire_block_reasons": {},
        "reserved_energy_by_basis": {},
        "map_reserved_energy_by_basis": {},
        "line_of_sight_block_by_movement": {},
        "line_of_sight_block_by_reason": {},
        "map_line_of_sight_block_counts": {},
        "fire_rejection_reasons": {},
        "tactical_event_counts": {},
        "resource_event_counts": {},
        "map_event_counts": {},
        "event_counter_consistent": True,
        "decision_generation_consistent": True,
        "movement_mode_distribution": {},
        "fire_mode_distribution": {},
        "cover_entry_count": 0,
        "cover_reengage_count": 0,
        "map_cover_event_counts": {},
        "target_valid_count": 0,
        "target_change_count": 0,
        "reward_component_totals": {},
        "profile_reward_components": {},
        "_fallback_counts_by_player": {},
        "_reward_components_by_player": {},
        "_profile_components_by_player": {},
        "_resource_event_counts_by_player": {},
        "_map_event_counts_by_player": {},
        "_last_movement_modes_by_player": {},
        "_last_target_slots": {},
        "decision_ids": [],
    }


def initial_rollout_audit(reward_profile_id: str) -> dict[str, Any]:
    payload = _empty_audit_payload()
    payload["reward_profile_id"] = reward_profile_id
    return payload


def update_transition_audit(
    audit: dict[str, Any],
    player_id: str,
    player_data: dict[str, Any],
    *,
    map_id: str | None = None,
) -> None:
    audit["transitions"] += 1
    diagnostics = player_data.get("diagnostics", {})
    diagnostics = diagnostics if isinstance(diagnostics, dict) else {}
    decision = player_data.get("executed_decision", {})
    decision = decision if isinstance(decision, dict) else {}
    fire_mode = int(decision.get("fire_mode", 0))
    movement_mode = int(decision.get("movement_mode", 0))
    _increment_audit_counter(
        audit,
        "movement_mode_distribution",
        _decision_mode_name(MOVEMENT_MODE_NAMES, movement_mode),
        1,
    )
    _increment_audit_counter(
        audit,
        "fire_mode_distribution",
        _decision_mode_name(FIRE_MODE_NAMES, fire_mode),
        1,
    )
    previous_movement_modes = audit.setdefault("_last_movement_modes_by_player", {})
    previous_movement_mode = previous_movement_modes.get(player_id)
    if movement_mode == 6 and previous_movement_mode != 6:
        audit["cover_entry_count"] += 1
        if map_id:
            _increment_nested_audit_counter(
                audit, "map_cover_event_counts", map_id, "cover_entry", 1
            )
    if previous_movement_mode == 6 and movement_mode in (1, 2, 7):
        audit["cover_reengage_count"] += 1
        if map_id:
            _increment_nested_audit_counter(
                audit, "map_cover_event_counts", map_id, "cover_reengage", 1
            )
    previous_movement_modes[player_id] = movement_mode
    fire_intent = fire_mode != 0
    fire_allowed = bool(diagnostics.get("fire_allowed", False))
    if fire_intent:
        audit["fire_intent_count"] += 1
    if fire_allowed:
        audit["fire_allowed_count"] += 1
    block_reason = str(diagnostics.get("fire_block_reason", ""))
    if fire_intent and not fire_allowed and block_reason:
        _increment_audit_counter(audit, "fire_block_reasons", block_reason, 1)
        if block_reason == "reserved_energy":
            reserve_basis = str(diagnostics.get("reserve_basis", "")) or "unspecified"
            _increment_audit_counter(audit, "reserved_energy_by_basis", reserve_basis, 1)
            if map_id:
                _increment_nested_audit_counter(
                    audit, "map_reserved_energy_by_basis", map_id, reserve_basis, 1
                )
        if block_reason == "no_line_of_sight":
            movement_name = _decision_mode_name(MOVEMENT_MODE_NAMES, movement_mode)
            movement_reason = str(diagnostics.get("movement_reason", "")) or "unspecified"
            _increment_audit_counter(audit, "line_of_sight_block_by_movement", movement_name, 1)
            _increment_audit_counter(audit, "line_of_sight_block_by_reason", movement_reason, 1)
            if map_id:
                _increment_nested_audit_counter(
                    audit, "map_line_of_sight_block_counts", map_id, movement_reason, 1
                )
    if bool(diagnostics.get("target_valid", False)):
        audit["target_valid_count"] += 1

    # Snapshot diagnostics can be newer than the executor action that created a
    # projectile. Cumulative Godot events are therefore the authoritative source
    # for realized authorization and hit conversion.
    event_deltas = _update_cumulative_audit(
        audit,
        "tactical_event_counts",
        "_tactical_event_counts_by_player",
        player_id,
        player_data.get("tactical_event_counts", {}),
        value_type=int,
    )
    event_counts = audit.get("tactical_event_counts", {})
    authorized_projectiles = int(event_counts.get("authorized_projectile", 0))
    authorized_hits = int(event_counts.get("authorized_hit", 0))
    if authorized_hits > authorized_projectiles:
        audit["event_counter_consistent"] = False
    for event_name, amount in event_deltas.items():
        if event_name.startswith("fire_rejected_"):
            _increment_audit_counter(
                audit,
                "fire_rejection_reasons",
                event_name.removeprefix("fire_rejected_"),
                amount,
            )
    if diagnostics.get("decision_generation_id") is not None and int(
        diagnostics.get("decision_generation_id", 0)
    ) <= 0:
        audit["decision_generation_consistent"] = False
    if map_id:
        _increment_audit_counter(audit, "map_transition_counts", map_id, 1)
        for event_name, amount in event_deltas.items():
            _increment_nested_audit_counter(
                audit, "map_tactical_event_counts", map_id, event_name, amount
            )
    resource_event_deltas = _update_cumulative_audit(
        audit,
        "resource_event_counts",
        "_resource_event_counts_by_player",
        player_id,
        player_data.get("resource_event_counts", {}),
        value_type=int,
    )
    if map_id:
        for event_name, amount in resource_event_deltas.items():
            _increment_nested_audit_counter(
                audit, "map_resource_event_counts", map_id, event_name, amount
            )
    map_event_deltas = _update_cumulative_audit(
        audit,
        "map_event_counts",
        "_map_event_counts_by_player",
        player_id,
        player_data.get("map_event_counts", {}),
        value_type=int,
    )
    if map_id:
        for event_name, amount in map_event_deltas.items():
            _increment_nested_audit_counter(
                audit, "map_environment_event_counts", map_id, event_name, amount
            )
    target_slot = int(decision.get("target_slot", 0))
    previous_target_slots = audit.setdefault("_last_target_slots", {})
    if player_id in previous_target_slots and previous_target_slots[player_id] != target_slot:
        audit["target_change_count"] += 1
    previous_target_slots[player_id] = target_slot
    fallback = bool(diagnostics.get("script_fallback", False))
    if fallback:
        audit["fallback_count"] += 1
    fallback_reason_deltas = _update_cumulative_audit(
        audit,
        "fallback_reasons",
        "_fallback_counts_by_player",
        player_id,
        diagnostics.get("fallback_counts", {}),
        value_type=int,
    )
    if fallback and not fallback_reason_deltas:
        _increment_audit_counter(
            audit,
            "fallback_reasons",
            _fallback_reason_from_player_data(player_data),
            1,
        )
    if bool(diagnostics.get("safety_override", False)):
        audit["safety_override_count"] += 1
        _increment_audit_counter(
            audit,
            "safety_override_reasons",
            str(diagnostics.get("override_reason", "unspecified")) or "unspecified",
            1,
        )
    reward_components = player_data.get("reward_components", {})
    _update_cumulative_audit(
        audit,
        "reward_component_totals",
        "_reward_components_by_player",
        player_id,
        reward_components,
        value_type=float,
    )
    profile_components = (
        {
            key: value
            for key, value in reward_components.items()
            if key in PROFILE_REWARD_COMPONENTS
        }
        if isinstance(reward_components, dict)
        else {}
    )
    _update_cumulative_audit(
        audit,
        "profile_reward_components",
        "_profile_components_by_player",
        player_id,
        profile_components,
        value_type=float,
    )


__all__ = [
    "initial_rollout_audit",
    "update_transition_audit",
]