# Pulse Arena Training

`training/` is the active training workspace for the Hybrid Tactical Agent.
Historical raw-action experiments were moved to `archive/legacy_raw_ai/`.

## Active Architecture

The active agent path is protocol v2:

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> TacticalPolicyNet or hybrid_tactical_prior
  -> HighLevelDecision
  -> HybridCombatExecutor
  -> PlayerAction
```

Low-level movement execution, projectile lead aiming, fire gates, evasion,
energy reservation, and stuck recovery live in Godot deterministic code. The
trainable model owns high-level target, movement, fire, and skill decisions.

## Key Files

- `configs/curriculum.json`: staged map and mode curriculum.
- `configs/evaluation_matrix.json`: promotion metrics and fixed seeds.
- `configs/profiles/local_constrained.json`: local workstation profile.
- `configs/profiles/full_distributed_league.json`: server-scale profile.
- `configs/training_plans/hybrid_tactical_local.json`: default local v2 plan.
- `configs/training_plans/hybrid_tactical_full.json`: server v2 plan scaffold.
- `configs/training_plans/hybrid_tactical_v2_server_bc.json`: server mask-aware BC plan.
- `rl/encoding.py`: raw and hybrid replay encoders.
- `rl/tactical_bc_trainer.py`: v2 tactical behavior-cloning warm start.
- `import_trained_model.py`: import a server-trained tactical checkpoint into the local registry.
- `package_server_bundle.py`: create a clean Ubuntu server training bundle.
- `rl/models.py`: `TacticalPolicyNet` and legacy policy nets.
- `train_pipeline.py`: unified collect / BC / PPO entry point.
- `inference/serve_agent.py`: JSONL TCP inference service.

## Phase 1 Baseline Audit

Before GPU training, verify that the checked-in Hybrid Tactical baseline stays
internally consistent:

```bash
make train-baseline-audit
```

For a GPU training host, run the CUDA preflight as the stop/go check:

```bash
python training/server_agent/preflight.py --require-cuda
```

The baseline audit exits `0` only when its baseline contract passes, and exits
`2` when it finds an inconsistency. With `--require-cuda`, CUDA preflight exits
`0` only when project prerequisites, Godot, NVIDIA driver visibility, and
PyTorch CUDA are all available. It exits `2` when any prerequisite is missing;
that is a stop condition for GPU training until the reported failure is
resolved.

## Local Workflow

Validate the default local v2 plan:

```bash
python training/train_pipeline.py --profile local_constrained --phase validate
```

Collect Hybrid v2 replay data:

```bash
python training/train_pipeline.py --profile local_constrained --phase collect --execute
```

Train high-level tactical heads from `hybrid_replay_v2` rows:

```bash
python training/train_pipeline.py --profile local_constrained --phase bc --execute --swanlab-mode offline
```

Server-side v2 BC plan:

```bash
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase validate
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase collect --execute
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase bc --execute --swanlab-mode offline
```

Package a clean server bundle:

```bash
python training/package_server_bundle.py
```

Dry-run the generated Godot commands directly:

```bash
python training/run_stage.py --profile local_constrained --stage 01_foundation_combat --agent-controller hybrid --agent-model-id hybrid_tactical_v1 --record-replay
```

## Inference

Start the active model server:

```bash
python -m training.inference.serve_agent --host 127.0.0.1 --port 8766
```

The service loads `training/models/model_catalog.json` by default. The active
catalog contains only `hybrid_tactical_v1`, which uses protocol v2
`act_tactical` requests.

To inspect the loaded registry:

```bash
python -m training.inference.serve_agent --print-info
```

## Results Layout

Active runs should write to:

- `training/replays/`: current replay collection, normally empty before a run.
- `training/runs/hybrid_tactical_bc/`: local tactical BC outputs.
- `training/runs/hybrid_tactical_bc_full/`: server tactical BC outputs.
- `training/checkpoints/hybrid/`: future promoted tactical checkpoints.
- `training/incoming_models/`: drop server-trained checkpoints before import.
- `training/experiments/`: durable experiment traces for reports and papers.
- `training/models/`: active deployable manifests and catalog only.

Historical raw-action PPO/BC checkpoints, replays, SwanLab logs, and old plans
are archived under `archive/legacy_raw_ai/`.
