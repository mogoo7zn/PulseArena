# Hybrid Tactical v2 Experiment Trace

## Current Iteration

- Objective: train protocol v2 high-level tactical policy.
- Actor input: `tactical_features` schema v2, 142 dims.
- Actor output: target, movement, fire, skill, confidence.
- Low-level control: deterministic HybridCombatExecutor.
- Warm start: mask-aware behavior cloning from explicit TacticalTeacher labels.
- Online training: dedicated tactical PPO/MAPPO only; legacy raw-action PPO is
  not part of this line.

## Run Naming

Use names such as:

- `hybrid_tactical_v2_bc_s01`
- `hybrid_tactical_v2_foundation_mappo_080m`
- `hybrid_tactical_v2_mixed_ffa_candidate_03`
- `hybrid_tactical_v2_promoted`

Do not include hardware model names in run ids, checkpoint names, or model ids.
