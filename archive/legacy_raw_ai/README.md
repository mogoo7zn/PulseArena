# Legacy Raw AI Archive

This archive preserves the previous all-model raw-action approach. These
policies output `move_x`, `move_y`, `aim_x`, `aim_y`, `shoot`, `dash`, and
`shield` directly through protocol v1.

## Use

These files are kept for reports, comparisons, and regression checks. They are
not part of the active menu, active model catalog, or default training plan.

To reproduce a legacy policy explicitly:

```powershell
python -m training.serve_agent --manifest archive\legacy_raw_ai\manifests\ppo_10m.json --host 127.0.0.1 --port 8766
```

## Layout

- `checkpoints/ppo_10m.pt`: server PPO 10M checkpoint.
- `checkpoints/ppo_20m.pt`: server PPO 20M checkpoint.
- `checkpoints/ppo_400m.pt`: full league 400M checkpoint with known action collapse.
- `runs/bc_local/`: local behavior-cloning baseline and metrics.
- `runs/ppo_local/`: short local PPO baseline and logs.
- `runs/bc_smoke*`: early local BC smoke and verification runs.
- `replays/raw_20260627/`: raw replay v1 JSONL data.
- `manifests/`: runnable legacy manifests and pre-hybrid catalogs.
- `configs/`: archived raw-action training plans.
- `docs/`: archived notes for raw-action training runs.
- `tools/raw_behavior_clone.py`: archived standalone raw-action BC script.
- `packages/full_league_training_bundle.zip`: old server-training handoff package.

## Summary

- Active replacement: `hybrid_tactical_v1`
- Active catalog: `training/models/model_catalog.json`
- Active protocol: v2 `act_tactical`
- Archive reason: low-level raw action learning was replaced by model-level
  high-level planning plus deterministic low-level execution.
