# Four-Map Foundation Diagnostic Report

## Scope

This is an accounting and routing diagnostic for the `legal_window_pressure` playability route. It is not candidate-model evaluation and does not authorize deployment.

## Runtime diagnostic

Command class: `08_mixed_ffa_league`, four matches, two agents, two seconds per match, `--map=all`, `--record-replay`, `legal_window_pressure`, and `pressure_curriculum` spawn policy.

The run completed four matches in deterministic order:

| Match | Seed | Map | Result |
| --- | ---: | --- | --- |
| 0 | 20000 | dungeon | 0:0 draw |
| 1 | 20001 | sky_city | 0:0 draw |
| 2 | 20002 | jungle | 0:0 draw |
| 3 | 20003 | mist_world | 0:0 draw |

It wrote four separate hybrid replay files under `training/replays/four_map_foundation_diagnostic/`. Two seconds is intentionally too short to establish combat, resource, or playability quality; all outcomes were 0:0. The diagnostic proves the map rotation and replay path only.

## Verified common foundations

- Decision-to-projectile attribution stores the producing decision generation and prevents a later diagnostics snapshot from rewriting authorization/hit credit.
- Resource accounting records actual healing, shield absorption, haste/overcharge authorized damage, contested non-magnet capture, and unused pickup-effect expiry. Collection itself is not positive value.
- Map event sources are separately observable: `dungeon_trap`, `sky_squeeze`, `sky_void`, `jungle_swamp`, `jungle_snake`, `mist_portal`, and `mist_fog`.
- Tactical PPO alternates `dungeon`, `sky_city`, `jungle`, and `mist_world` at episode boundaries and writes map-keyed transition/event audit data.

## Fresh verification

- `python -m unittest tests.unit.test_tactical_online_trainer tests.unit.test_train_pipeline -v`: 20 passed.
- Godot `tests/run_tests.gd`: passed.
- `tests/smoke/tactical_training_protocol_check.py`: passed.
- `tests/smoke/tactical_ppo_cuda_micro_update.py`: passed on NVIDIA A100-SXM4-80GB.
- Four-map `ppo-multi` pipeline dry run: four independent GPU 4–7 commands with unique ports, seeds, and output directories.

## Training gate

The post-fix four-map BC checkpoint does not yet exist. The only available BC checkpoint is Dungeon-only and is intentionally excluded. Before PPO launch, run the new balanced 32-match / 60-second collection plan, train `training/runs/four_map_foundation_bc/best_tactical_policy.pt`, then launch a bounded one-worker PPO diagnostic and inspect its per-map audit. No model has been deployed or promoted.
