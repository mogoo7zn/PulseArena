# Archive

This directory stores historical experiment artifacts that should not be used
by the active training pipeline.

- `legacy_raw_ai/`: protocol v1 raw-action PPO/BC baselines, checkpoints,
  manifests, raw replays, logs, and old training plans.
- `hybrid_smoke/`: small protocol v2 smoke-test artifacts kept for debugging
  only. These are not production training datasets.

Active training writes to `training/replays/`, `training/runs/`, and
`training/checkpoints/`.
