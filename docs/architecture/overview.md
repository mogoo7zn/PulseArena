# Architecture

Pulse Arena separates flow, entity simulation, control, UI, replay, and RL interfaces.

- `GameFlowManager` owns global state transitions.
- `ArenaRoot` composes one match instance.
- `ArenaPlayer` consumes `PlayerAction` only.
- `PlayerController` implementations produce actions from `AgentObservation`.
- `ObservationBuilder` and `RewardCalculator` stay independent from player/projectile classes.
- UI listens to snapshots and typed `GameEvents`.

The current app supports one active Arena. `EnvironmentBridge` is shaped for future multi-Arena batching.

## Hybrid Tactical Agent

The default agent architecture is now split:

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> protocol v2 Learned Tactical Policy
  -> HighLevelDecision
  -> HybridCombatExecutor
  -> PlayerAction
```

`HybridCombatExecutor` owns deterministic aim solving, line-of-sight and wall checks, fire gating, projectile evasion, movement hysteresis, and stuck recovery. `ArenaPlayer` still receives only `PlayerAction`.

Legacy protocol v1 raw-action models were archived under `archive/legacy_raw_ai/`.
They can still be loaded explicitly for result reproduction, but they are not
part of the active menu, active catalog, or default training plan.
