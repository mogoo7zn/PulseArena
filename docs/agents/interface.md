# Agent Interface

Controllers implement `PlayerController`:

```gdscript
func reset() -> void
func get_action(observation: AgentObservation, delta: float) -> PlayerAction
```

`PlayerAction` contains normalized move/aim vectors and boolean shoot/dash/shield actions.

`AgentObservation` includes own state, other players, closest projectiles, boundary distances, 16 map rays, mode ID, and map ID. It supports dictionary and flat-array serialization for Python or replay pipelines.

`EnvironmentBridge` defines:

- `reset_environment(config)`
- `get_observations()`
- `apply_actions(actions)`
- `step()`
- `get_rewards()`
- `get_terminated()`
- `get_truncated()`
- `get_info()`

## Active Protocol

Protocol v2 is the active Hybrid Tactical interface:

```json
{"cmd":"act_tactical","protocol":2,"tactical_features":[],"action_masks":{}}
```

The v2 response is a `HighLevelDecision` with `target_slot`, `movement_mode`,
`fire_mode`, `skill_mode`, `confidence`, `decision_id`, and
`protocol_version`. Godot converts it to `PlayerAction` through the
deterministic Hybrid executor.

## Archived Protocol

Protocol v1 raw action inference is archived for result reproduction only:

```json
{"cmd":"act","protocol":1,"observation":{},"flat_observation":[]}
```

The legacy checkpoints, manifests, and replay data live under
`archive/legacy_raw_ai/`. They are not part of the active menu or default
training plan.
