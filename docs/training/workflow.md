# Hybrid Tactical v2 训练流程

## BC 是什么

BC 是 Behavior Cloning，中文通常叫行为克隆。它是监督学习：把老师在某个状态下选择的动作当标签，让模型先学会稳定、合法、可解释的基础策略。

在本项目里，BC 不是最终训练目标。它的作用是给后续 tactical PPO/MAPPO 一个稳定初始策略，避免强化学习一开始随机选择高层动作，造成空枪、贴墙、乱用技能和训练不稳定。

## 当前训练主线

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> TacticalPolicyNet
  -> HighLevelDecision
  -> HybridCombatExecutor
  -> PlayerAction
```

模型只训练高层战术头：

- `target_slot`
- `movement_mode`
- `fire_mode`
- `skill_mode`
- `confidence`

移动执行、提前量瞄准、LOS 检查、墙体检查、开火门控、能量保留、躲弹、安全覆盖和卡死恢复仍由 Godot 确定性代码负责。

## 阶段 1：显式战术教师和 replay 采集

`scripts/agents/tactical_teacher.gd` 会把公开观测转成真实高层标签，不再固定写 `USE_SCRIPTED_*`：

- 高危子弹：`EVADE_PROJECTILE`，必要时 `DASH_EVADE` 或 `SHIELD`
- 低血/低能量：`SEEK_COVER`、`RETREAT`、`CONSERVATIVE`
- 敌人远：`CHASE`
- 距离合适：`KEEP_RANGE`
- 残血击杀窗口：`LOWEST_HEALTH_ENEMY + ALL_IN`
- 无目标：`SEEK_BEST_PICKUP` 或 `MOVE_TO_CENTER + HOLD_FIRE`

新 replay 会记录：

- `teacher_decision`
- `teacher_label_version`
- `label_source`
- `label_reason`
- `label_weight`
- `label_confidence`
- `action_masks`
- `fallback_used`
- `safety_override`
- `diagnostic_metrics`

这些字段用于训练过滤、论文复盘和实验版本对比。

## 阶段 2：mask-aware BC 热启动

训练入口：

```bash
python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_server_bc \
  --phase bc \
  --execute \
  --swanlab-mode offline
```

BC trainer 会：

- 在 loss 中使用 action mask，非法动作不参与竞争
- 使用 `label_weight` 降权低质量样本
- 使用 `label_confidence` 训练 confidence head
- 自动降权旧 replay 中纯 `SCRIPTED_*` 委托标签
- 输出 `best_tactical_policy.pt`、`last_tactical_policy.pt`、`metrics.csv`、`metrics.png`

## 阶段 3：tactical PPO/MAPPO

下一阶段在线训练必须是 protocol v2 tactical runner：

- actor 输出四个 masked categorical heads
- PPO log probability 是四个 head 的和
- 从 BC checkpoint 初始化
- 前期保留 BC KL regularization
- 多人 FFA 和 2v2 使用 centralized critic
- 部署 actor 不读取隐藏敌人状态

不要复用旧 `training/rl/online_trainer.py` 作为正式训练入口；它是 raw-action PPO，会绕开 Hybrid Tactical v2 的底层执行器。

已接入的 8 卡入口是任务编排层，不是单 run 多卡同步 learner。它会启动 8 个独立 protocol-v2 tactical PPO worker，各自独占 GPU、Godot 端口和输出目录：

```bash
python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi
```

dry-run 确认 GPU/端口/日志分配无误后再添加 `--execute`。

## 服务器资源建议

建议先不要把全部卡同时压到单个 run。这个项目主要瓶颈很可能是 Godot worker 仿真和 IPC，而不是 tactical MLP 本身。

- BC 阶段：1 张卡即可，batch size 可以开到 8192 或更高。
- 早期 PPO/MAPPO：2 张卡，先测 worker 吞吐和 learner 稳定性。
- 中期 league：4 张卡，把训练、评测、历史策略对战和候选 checkpoint 并行起来。
- 最终完整 league：最多 8 张卡，用于全图自博弈、消融实验和持续评测并行。

配套建议：

- CPU：128 核起，完整 league 建议 192-256 核。
- RAM：256GB 起，完整 league 建议 512GB 以上。
- 存储：高速 SSD，至少 1TB，完整 replay/metrics 建议 2TB 以上。
- Godot workers：从 128/256 压测，稳定后再上 512/1024。

## 服务器运行

在 Ubuntu 服务器上：

```bash
export GODOT_BIN=/path/to/godot
bash training/server_train_hybrid_tactical_v2.sh
```

也可以分阶段执行：

```bash
python training/pipeline/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase validate
python training/pipeline/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase collect --execute
python training/pipeline/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase bc --execute --swanlab-mode offline
```

## 模型回收

服务器训练完成后，把 checkpoint 和 metrics 放到：

```text
training/data/incoming_models/
```

然后本地导入：

```bash
python training/model_io/import_trained_model.py \
  --checkpoint training/data/incoming_models/hybrid_tactical_v2_bc_s01.pt \
  --metrics-json training/data/incoming_models/hybrid_tactical_v2_bc_s01_metrics.json \
  --model-id hybrid_tactical_v2_bc_s01 \
  --run-id hybrid_tactical_v2_bc_s01 \
  --hidden 256 \
  --update-catalog
```

导入后：

- checkpoint 进入 `training/artifacts/checkpoints/hybrid/`
- manifest 进入 `training/models/`
- 可选更新 `training/models/model_catalog.json`

## 命名规则

模型名、run id、checkpoint 名不要出现具体硬件型号。

推荐：

- `hybrid_tactical_v2_bc_s01`
- `hybrid_tactical_v2_foundation_mappo_080m`
- `hybrid_tactical_v2_mixed_ffa_candidate_03`
- `hybrid_tactical_v2_promoted`

硬件信息只写入实验 metadata，不进入模型 id。

## 实验痕迹

长期保留：

- `training/configs/training_plans/*.json`
- `training/artifacts/runs/<run_id>/metrics.csv`
- `training/artifacts/runs/<run_id>/metrics.png`
- `training/artifacts/runs/<run_id>/swanlab/`
- `training/data/experiments/<line>/README.md`
- 导入后的 manifest 和 catalog

论文整理时，每个阶段至少记录：

- 使用的代码版本
- replay 数据规模
- label 版本
- 训练配置
- 验证集 head accuracy
- promotion gate 指标
- 失败样例和下一轮修改理由
