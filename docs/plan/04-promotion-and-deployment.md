# 阶段 3 & 4：扩训、晋级与生产部署

> **阶段 3**：在 GPU-4 diagnostic 通过后，把训练扩到 8 卡并行（**8 个独立 checkpoint，不是 MAPPO**）。  
> **阶段 4**：把通过的 candidate 推到默认服务。  
> **关键边界**：阶段 3 是工程性扩训，阶段 4 是产品性晋级——前者可以反复试，后者一旦回滚代价很大。

---

## 阶段 3：扩训

### 3.1 前置

- 阶段 1 的 6 条硬门槛**全部通过**；
- 阶段 2 的 7 组 TDD **全部全绿**；
- 至少 7 张 GPU 空闲（推荐 GPU-0..7）；
- 端口 8870..8877 + 18961..18964 全部空闲。

### 3.2 8 卡 PPO multi

```bash
cd /data/mogoo7zn/PulseArena

# Dry-run（必须先跑一次确认资源分配）
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi

# 真正执行
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi --execute
```

**预期**：

- 8 个 worker 全部 `returncode=0`；
- 每个 worker 的 `env_steps=512`、`tactical_step_calls=128`、`raw_step_calls=0`；
- 输出在 `training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu{0..7}/`；
- GPU 显存占用 = `0MiB`（结束后）；
- 端口 `8870..8877` 无监听残留。

### 3.3 评估每个 worker

```bash
for gpu in 0 1 2 3 4 5 6 7; do
  .conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
    --runner godot-service \
    --candidate-dir training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu${gpu} \
    --output-dir training/artifacts/runs/evaluations/hybrid_tactical_v2_8gpu_parallel_pilot_gpu${gpu}_$(date +%Y%m%d) \
    --seeds 8
done
```

**预期**：

- 每个 candidate 的 `gate_summary` 至少 `gate_passed=true`；
- `model_catalog.json` 的 `default_model_id` **未自动变更**。

### 3.4 候选筛选

从 8 个 candidate 里**手动**筛：

| 维度 | 阈值 |
|---|---|
| `raw_step_calls == 0` | 必填 |
| `fallback_rate == 0` | 必填 |
| paired baseline win/top1 ≥ 0.55 | 必填（paired eval 见 `evaluate_tactical_candidate.py --runner godot-service` 的 paired 模式） |
| 4 张地图都有 episodes | 必填 |
| `safety_override_rate ≤ 0.10` | 推荐 |

**至少 1 个 candidate 通过全部必填条件**才能进入阶段 4。**没通过**则：

- 把"近通过"的 candidate 留下来做诊断；
- 回到阶段 0 重新决策（多半是 `legal_window_pressure` profile 还要再修）。

### 3.5 失败回退

- 任一 worker `raw_step_calls > 0` → 该 worker checkpoint 全部作废，归档；
- 8 个 candidate 全不过 gate → 回到阶段 1 重新跑 diagnostic；
- 资源争抢（端口冲突 / GPU OOM） → 缩到 4 卡重试；
- `safety_override_rate > 0.10` → 候选归档，不进阶段 4。

---

## 阶段 4：晋级与生产部署

### 4.1 前置

- 阶段 3 至少 1 个 candidate 通过所有必填条件；
- paired eval 已跑过（候选 vs `hybrid_tactical_v1`）；
- human eval 已准备好（至少 5 个玩家）。

### 4.2 Paired eval

```bash
# 选一个最佳 candidate
BEST_GPU=3   # 替换为实际通过的 GPU 编号
CANDIDATE_DIR=training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu${BEST_GPU}

# Paired 模式
.conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
  --runner godot-service \
  --candidate-dir ${CANDIDATE_DIR} \
  --output-dir training/artifacts/runs/evaluations/${CANDIDATE_DIR##*/}_paired_$(date +%Y%m%d) \
  --seeds 32 \
  --mode paired \
  --baseline-model-id hybrid_tactical_v1
```

**预期**：

- `paired_win_rate ≥ 0.55`、`top1_rate ≥ 0.55`；
- 32 个 seed 里 candidate 至少赢 18 个。

### 4.3 Human eval

- 把 candidate 部署到内测环境；
- 让 ≥ 5 个玩家玩 ≥ 30 分钟；
- 收集问卷（5 分制 ≥ 3.5 分算"接受"）。

**接受率 ≥ 0.7** 才进入下一阶段。

### 4.4 显式晋升

```bash
# 把通过的 candidate 导入 manifest
.conda/bin/python training/model_io/import_trained_model.py \
  --checkpoint training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu${BEST_GPU}/best_tactical_ppo.pt \
  --metrics-json training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu${BEST_GPU}/metrics.jsonl \
  --model-id hybrid_tactical_v2_promoted_$(date +%Y%m%d) \
  --run-id hybrid_tactical_v2_promoted_$(date +%Y%m%d) \
  --hidden 256 \
  --update-catalog
```

**预期**：

- `training/artifacts/checkpoints/hybrid/hybrid_tactical_v2_promoted_<YYYYMMDD>.pt` 存在；
- `training/models/hybrid_tactical_v2_promoted_<YYYYMMDD>_agent.json` 存在；
- `training/models/model_catalog.json` 的 `default_model_id` 更新为新 model_id；
- `training/models/model_catalog.json` 的 `models` 数组新增该 model_id。

### 4.5 7 天观察期

- 每天检查 `serve_agent --print-info` 的输出；
- 每天跑一次 `evaluate_tactical_candidate.py --runner godot-service --seeds 8`，确认无 raw-step / fallback 异常；
- 每天看一次 `training/artifacts/runs/` 下的新 evaluation，确认 paired win rate 没有显著下滑。

### 4.6 回滚预案

```bash
# 如果新候选出问题，把默认改回 baseline
# 1. 编辑 training/models/model_catalog.json，把 default_model_id 改回 hybrid_tactical_v1
# 2. 提交
git add training/models/model_catalog.json
git commit -m "rollback: revert default to hybrid_tactical_v1"
```

**回滚条件**：

- 7 天内任一日 paired win rate 跌至 0.45 以下；
- 任一日 evaluation 出现 `raw_step_calls > 0`；
- 任一日玩家投诉数 > 阈值（按项目 SLA）。

### 4.7 归档

晋升 30 天稳定后：

- 把老 candidate 的 manifest 移到 `training/artifacts/runs/archived/`；
- 老 checkpoint 留在 `training/artifacts/checkpoints/hybrid/`（仍可作对照）。

---

## 关键数字总览表

| 阶段 | 必填 | 推荐 |
|---|---|---|
| 3.4 候选筛选 | raw=0, fallback=0, paired win≥0.55, 4 maps all >0 | safety_override≤0.10 |
| 4.2 Paired eval | win/top1 ≥ 0.55 | win ≥ 0.65 |
| 4.3 Human eval | 接受率 ≥ 0.7 | 接受率 ≥ 0.85 |
| 4.4 显式晋升 | catalog 更新 | 同步 git tag |
| 4.5 7 天观察 | 无 raw-step | paired win 稳定 ≥ 0.55 |
| 4.6 回滚 | 触发即回 | 无 |

---

## 接续训练候选决策表

| 阶段 1 跑过的 run 目录 | 6 条门槛结果 | paired win | human 接受率 | 决定 |
|---|---|---|---|---|
| `ballistic_repair_gpu4_<YYYYMMDD>` | _/6 | _ | _ | _ |

把这个表填完才能进入阶段 4。
