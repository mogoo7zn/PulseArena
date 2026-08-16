# 阶段 1：GPU-4 isolated diagnostic

> **输入**：阶段 0 的决策（`00-项目基线与现状.md` 末尾的决策表）。  
> **目标**：在 1 张 GPU（推荐 GPU-4）跑 `tactical_legal_window_pressure_four_map_ballistic_repair`，把 08-06 / 08-08 修复方向的"是否真有效"用数据证明。  
> **时间预算**：collect ≈ 30 分钟、bc ≈ 20 分钟、ppo 16,384 env-steps ≈ 60–90 分钟（视磁盘 IO）；总计 2–3 小时。  
> **风险**：raw-step leak、端口冲突、GPU OOM、collect 阶段 Godot 崩溃。

---

## 1. 前置检查

```bash
# 1. Godot 二进制
ls -la .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64

# 2. Python 虚拟环境
.conda/bin/python --version
.conda/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count())"

# 3. 目标 GPU 空闲
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | head -8

# 4. 目标端口空闲
ss -tlnp | grep -E '18961|18962|18963|18964' || echo "ports 18961-18964 free"

# 5. 训练计划 JSON 存在
ls -la training/configs/training_plans/tactical_legal_window_pressure_four_map_ballistic_repair.json
ls -la training/configs/multi_gpu/legal_window_pressure_ballistic_repair_gpu4_7.json

# 6. 当前 git 状态（不要在 dirty 状态跑）
git status --short
```

如果上面任意一项不通过，**不要开始跑**。

## 2. 准备输出目录

```bash
PROJECT_ROOT=/data/mogoo7zn/PulseArena
cd "$PROJECT_ROOT"

# 训练 run 目录（不要覆盖已存在的）
mkdir -p training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4
mkdir -p training/data/replays/four_map_ballistic_repair_bc
mkdir -p training/artifacts/runs/four_map_ballistic_repair_bc
```

每个 run 都用**独立**目录（不要复用 `ballistic_repair_gpu4` 跑两次）。如果该目录已存在，跑前需要：
- 把它整体 mv 到 `training/artifacts/runs/archived/`，并写明原因；或
- 在 `01-` 之外另起一个 `_v2` 后缀的目录。

## 3. collect 阶段（32 局 60s 平衡四图 replay）

```bash
cd /data/mogoo7zn/PulseArena
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_ballistic_repair \
  --phase collect --execute
```

**预期**：

- 32 局（4 张地图 × 8 局）每局 60 秒；
- 输出到 `training/data/replays/four_map_ballistic_repair_bc/`；
- 每个 replay 是 `*.hybrid_v2.jsonl`；
- `auc` 文件里 `fallback_used` 比例很低（< 5%）。

**失败处理**：

- `replay_integrity` 报错 → 重新跑 collect；
- Godot 端口被占用 → 改 `--port` 参数；
- Fallback 比例 > 5% → 在 `00-` 决策表里"是否需要先写修复 plan"那一栏填"是"，回到阶段 0。

## 4. bc 阶段（行为克隆）

```bash
cd /data/mogoo7zn/PulseArena
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_ballistic_repair \
  --phase bc --execute
```

**预期**：

- 输出 `training/artifacts/runs/four_map_ballistic_repair_bc/best_tactical_policy.pt`；
- `metrics.jsonl` 至少 5 个 epoch；
- head accuracy ≥ 0.85（target_slot / movement_mode / fire_mode / skill_mode）。

**失败处理**：

- 任何 head accuracy < 0.7 → 重新跑 collect（数据质量不够）；
- 训练 NaN/爆炸 → 检查 `tactical_teacher.gd` 的输出 JSON 是否稳定。

## 5. PPO 阶段（warm-start BC，16,384 env-steps）

```bash
cd /data/mogoo7zn/PulseArena
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_ballistic_repair \
  --phase ppo --execute \
  --output-dir training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4 \
  --port 18961 --seed 20261086
```

**预期**：

- 输出 `training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/{best_tactical_ppo.pt,last_tactical_ppo.pt,metrics.jsonl,config.json,rollout_audit.json}`；
- `env_steps=16,384`、`updates=64`、`episodes=64`（每 256 env-steps 一个 update）；
- 训练全程 `raw_step_calls=0`；
- `last_tactical_ppo.pt` 存在但**不**进入 `model_catalog.json`。

**失败处理**：

- `raw_step_calls > 0` → 立即停，整个 run 归档到 `training/artifacts/runs/archived/`，回到阶段 0；
- 端口冲突 → 改 `--port`（18962..18964）；
- `env_steps` 没跑够 → 检查 `training/configs/training_plans/tactical_legal_window_pressure_four_map_ballistic_repair.json` 的 `total_env_steps` 是否被环境变量覆盖。

## 6. 验收（看 rollout_audit.json）

```bash
AUDIT=training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/rollout_audit.json

# 1. raw / fallback
echo "raw_step_calls: $(jq -r '.raw_step_calls' $AUDIT)"
echo "fallback_rate: $(jq -r '.fallback_rate' $AUDIT)"

# 2. 4 张地图都有 episodes
jq '.total_episodes_by_map' $AUDIT

# 3. 授权率
jq '.fire_intent_count, .fire_authorized_count, .fire_blocked_count, .authorized_hit_count, .authorized_damage' $AUDIT

# 4. LoS 块（按地图）
jq '.map_blocked_breakdown_by_map' $AUDIT

# 5. reserve basis
jq '.reserved_energy_by_basis, .map_reserved_energy_by_basis' $AUDIT

# 6. cover 事件
jq '.cover_entry_count, .cover_reengage_count, .map_cover_event_counts' $AUDIT

# 7. consistency
jq '.decision_generation_consistent, .audit_consistency_flags' $AUDIT
```

| 维度 | 阈值 | 命令 |
|---|---|---|
| `raw_step_calls` | == 0 | grep 'raw_step_calls' |
| `fallback_rate` | == 0 | grep 'fallback_rate' |
| 4 张地图都有 episodes | 4 项都 > 0 | `total_episodes_by_map` |
| `fire_authorized/fire_intent` | ≥ 0.015 | 算 |
| Sky/Mist LoS 块 | < 68.4% / 72.0% | `map_blocked_breakdown_by_map` |
| reserve basis 至少 3 个非零 | base / dash_ready / shield_ready / low_health / projectile_threat / conservative / burst / all_in_kill_window | `reserved_energy_by_basis` |
| consistency | 都 true | `decision_generation_consistent` |

**任一不通过 → 阶段 1 失败 → 回到阶段 0**。

## 7. 阶段 1 完成后必做

1. 把 `metrics.jsonl` 与 `rollout_audit.json` 拷到 `training/artifacts/runs/ballistic_repair_gpu4_20260815/` 备份（这个名字加日期）；
2. 把这次数字 append 到 `docs/training/status/tactical-rl-progress.md`；
3. 把这次 run 的 6 条硬门槛结果写到 `04-` 的"晋级候选决策表"对应行。

## 8. 一个常见误区

- **"GPU-4 跑过了，下一步直接上 8 卡"**——错。阶段 2 必须先把 TDD 跑通，否则 8 卡跑出来的东西仍然是 baseline 行为。
- **"raw_step_calls=0 但 safety override 7%"**——safety override ≠ raw step；只要 raw 是 0，就可以继续看。
- **"看到 fallback_rate > 0 立刻归档"**——fallback_rate > 0 时先看 `fallback_reasons` 是不是 `service_transport`，如果是，可能是 IPC 抖动，不要立刻归档。
