# 训练实现说明

## 当前训练路线

后续训练采用 Hybrid Tactical v2 架构：

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> TacticalPolicyNet / tactical prior
  -> HighLevelDecision
  -> HybridCombatExecutor
  -> PlayerAction
```

模型只负责高层战术头：

- `target_slot`
- `movement_mode`
- `fire_mode`
- `skill_mode`
- `confidence`

底层移动、瞄准、开火、躲弹和防卡墙由 Godot 确定性算法处理。

## Active Plans

本地：

```text
profile: training/configs/profiles/local_constrained.json
plan: training/configs/training_plans/hybrid_tactical_local.json
```

服务器：

```text
profile: training/configs/profiles/full_distributed_league.json
plan: training/configs/training_plans/hybrid_tactical_full.json
```

旧 raw-action plans 已归档到：

```text
archive/legacy_raw_ai/configs/
```

## 命令

验证默认本地 v2 plan：

```bash
python training/pipeline/train_pipeline.py --profile local_constrained --phase validate
```

采集 `hybrid_replay_v2`：

```bash
python training/pipeline/train_pipeline.py --profile local_constrained --phase collect --execute
```

训练高层 tactical BC：

```bash
python training/pipeline/train_pipeline.py --profile local_constrained --phase bc --execute --swanlab-mode offline
```

直接 dry-run Godot 采样命令：

```bash
python training/pipeline/run_stage.py --profile local_constrained --stage 01_foundation_combat --agent-controller hybrid --agent-model-id hybrid_tactical_v1 --record-replay
```

## 输出目录

当前训练数据从空目录开始：

```text
training/data/replays/
```

本地 tactical BC 输出：

```text
training/artifacts/runs/hybrid_tactical_bc/
```

后续正式 tactical checkpoint 建议放在：

```text
training/artifacts/checkpoints/hybrid/
```

旧 checkpoint、raw replay、SwanLab 记录和服务器包已放入 `archive/legacy_raw_ai/`。
