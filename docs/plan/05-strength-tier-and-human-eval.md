# 阶段 5：强度分层与 Human Eval 接入

> **目的**：在 1 份 Hybrid Tactical checkpoint 上落地 5 档难度（easy / casual / normal / strong / elite），并接入真人对局评测。
> **前置**：阶段 1–4 全部通过；`hybrid_tactical_v2_promoted_<YYYYMMDD>` 已写入 `model_catalog.json` 默认。
> **关键边界**：强度分层只调推理参数（`temperature` / `mask_soften` / `safety_override_threshold`），不重训 5 个模型；不重训就保证不会因为"分层"导致训练-推理不一致。

---

## 1. 用户确认的关键决策

| 编号 | 决策 | 数值 |
|---|---|---|
| D1 | 同一份模型 + 不同推理参数 | 1 份 `.pt` 导出 5 档 |
| D2 | 中档 `win_rate ∈ [0.50, 0.75]`（人类 vs 中档） | 区间门槛 |
| D3 | 启用菜单 | 玩家在主菜单选 5 档 |
| D4 | 5 档命名 | easy / casual / normal / strong / elite |

---

## 2. 5 档强度档设计

### 2.1 推理参数表

| 档位 | model_id | temperature | mask_soften | safety_override_threshold | 目标玩家 |
|---|---|---|---|---|---|
| easy | `hybrid_tactical_v1_easy` | 1.6 | 0.30 | 0.55 | 第一次接触、不会闪避 |
| casual | `hybrid_tactical_v1_casual` | 1.1 | 0.20 | 0.65 | 玩过几局、会瞄准 |
| normal | `hybrid_tactical_v1_normal` | 0.85 | 0.10 | 0.75 | 中等玩家，**打得有来有回** |
| strong | `hybrid_tactical_v1_strong` | 0.55 | 0.05 | 0.85 | 进阶玩家 |
| elite | `hybrid_tactical_v1_elite` | 0.25 | 0.0 | 0.95 | 比大多数人类强 |

> **实现位置**：`training/inference/sampler.py`（新增）或 `training/inference/serve_agent.py` 的请求解析层；新增 `strength_profile` 字段透传到 `sample_masked_tactical_actions`。

### 2.2 推理参数语义

| 参数 | 范围 | 作用 |
|---|---|---|
| `temperature` | [0.1, 2.0] | 采样温度。T 越大越随机；T 越小越贪心 |
| `mask_soften` | [0.0, 0.5] | 把非法动作的负无穷惩罚"软化"为 `-mask_soften * 可行动作的最大 logit`；hard 模式下 = 0 |
| `safety_override_threshold` | [0.4, 1.0] | 决策置信度低于它则触发脚本 hard fallback；hard 模式 = 0.95 |

5 档之间的 `temperature` 必须**严格单调递减**；`mask_soften` 严格单调递减；`safety_override_threshold` 严格单调递增。**这是验收门槛 1**。

---

## 3. 实现步骤

### 3.1 Step 1 — Sampler 接收 strength_profile

**修改文件**：
- `training/inference/sampler.py`（新增）
- `training/inference/serve_agent.py`
- `scripts/controllers/remote_agent_controller.gd`（解析 `strength_profile` 字段）

**TDD 红→绿**：

```python
# tests/unit/test_sampler_strength_profile.py
def test_strength_profile_changes_sampling_temperature():
    sampler = TacticalSampler(checkpoint=..., strength="easy")
    probs_easy = sampler.softmax_logits(logits, masks)  # 较平
    sampler_normal = TacticalSampler(checkpoint=..., strength="normal")
    probs_normal = sampler_normal.softmax_logits(logits, masks)
    assert probs_easy.entropy() > probs_normal.entropy()

def test_strength_profile_default_is_normal():
    sampler = TacticalSampler(checkpoint=..., strength=None)
    assert sampler.strength == "normal"

def test_easy_raises_fallback_probability_in_low_confidence_steps():
    sampler = TacticalSampler(checkpoint=..., strength="easy")
    assert sampler.compute_fallback_probability(confidence=0.3) > 0.5
```

**退出条件**：3 个测试全绿；`serve_agent` 启动带 `--strength-profile` 参数。

### 3.2 Step 2 — Manifest 登记 5 档

**修改文件**：
- `training/models/model_catalog.json` — `models` 数组新增 5 个条目
- `training/models/hybrid_tactical_v1_*_agent.json` — 5 个 manifest（每档 1 个）

每个 manifest 的 `inference_profile` 字段写：

```json
{
  "model_id": "hybrid_tactical_v1_normal",
  "checkpoint": "training/artifacts/checkpoints/hybrid/hybrid_tactical_v2_promoted_<YYYYMMDD>.pt",
  "kind": "tactical_actor_critic",
  "protocol": 2,
  "inference_profile": {
    "temperature": 0.85,
    "mask_soften": 0.10,
    "safety_override_threshold": 0.75,
    "target_human_win_rate_range": [0.50, 0.75]
  }
}
```

**命令**：

```bash
# 5 个 manifest 都用同一份 checkpoint；用 import_trained_model 但不更新 catalog
for STRENGTH in easy casual normal strong elite; do
  .conda/bin/python training/model_io/import_trained_model.py \
    --checkpoint training/artifacts/checkpoints/hybrid/hybrid_tactical_v2_promoted_$(date +%Y%m%d).pt \
    --metrics-json training/artifacts/runs/hybrid_tactical_v2_8gpu_promoted/metrics.jsonl \
    --model-id hybrid_tactical_v1_${STRENGTH} \
    --run-id hybrid_tactical_v2_promoted_strength_${STRENGTH} \
    --hidden 256 \
    --strength-profile ${STRENGTH}
done
```

**退出条件**：5 个 manifest 存在；`model_catalog.json` 多了 5 个条目；`serve_agent --print-info` 能识别 5 个 model_id。

### 3.3 Step 3 — 菜单集成

**修改文件**：
- `scripts/app/main_menu.gd` — 右侧 mode 面板新增 `agent_difficulty` 选项（5 档）
- `scripts/core/match_config.gd`（或 `MatchConfig`）— 接收 `difficulty` 字段
- `scripts/controllers/remote_agent_controller.gd` — 通过 `--strength-profile` 传到 Python

**菜单默认值**：`normal`（中档）。这与 D2 的"中等强度要能和人打的有来有回"对应。

**测试**：

```gdscript
# tests/run_tests.gd
func test_main_menu_exposes_five_difficulty_options() -> void:
    var menu := load("res://scripts/app/main_menu.gd").new()
    var options := menu.list_difficulty_options()
    assert_eq(options.size(), 5)
    var labels := options.map(func(o): return o.label)
    assert_true("简单" in labels)
    assert_true("休闲" in labels)
    assert_true("普通" in labels)
    assert_true("困难" in labels)
    assert_true("精英" in labels)
```

**退出条件**：菜单加载时显示 5 档；选不同档后 `MatchConfig` 写入对应 `difficulty` 字段；启动后 `serve_agent` 日志能看到 `--strength-profile` 参数。

### 3.4 Step 4 — Paired eval 跑 5 档

**目的**：用当前 hybrid_tactical_v1 baseline 作为"对手"，量化 5 档的"打得有来有回"区间。

**命令**：

```bash
cd /data/mogoo7zn/PulseArena

for STRENGTH in easy casual normal strong elite; do
  .conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
    --manifest training/models/hybrid_tactical_v1_${STRENGTH}_agent.json \
    --runner godot-service \
    --output-dir training/artifacts/runs/evaluations/strength_${STRENGTH}_vs_v1 \
    --split holdout \
    --max-jobs 32
done
```

**验收**（4 条**全部**通过才进入 Step 5）：

| 档位 | vs scripted_hard 1v1 | vs scripted_normal 1v1 | vs hybrid_tactical_v1 1v1 | 阈值 |
|---|---|---|---|---|
| easy | win < 0.30 | win < 0.50 | win < 0.45 | 入门玩家也能赢 |
| casual | 0.30 ≤ win < 0.55 | 0.50 ≤ win < 0.70 | 0.45 ≤ win < 0.60 | 略强于 easy |
| **normal** | 0.55 ≤ win < 0.75 | 0.70 ≤ win < 0.85 | 0.60 ≤ win < 0.75 | **中档打得有来有回** |
| strong | 0.75 ≤ win < 0.90 | 0.85 ≤ win < 0.95 | 0.75 ≤ win < 0.90 | 比多数人类强 |
| elite | win ≥ 0.90 | win ≥ 0.95 | win ≥ 0.90 | 顶级玩家才能抗衡 |

**5 档之间胜率必须严格单调上升**——这是验收门槛 2。

### 3.5 Step 5 — Human eval 接入

**目的**：让真人跑至少 50 局 / 档，验证 D2 的中档 0.50–0.75 区间。

**硬件**：
- 任何能跑 Godot 4.7 的电脑（不需要服务器）；
- 神策 / 自建 form 记录每局胜负、平均时长、玩家评分。

**Step 5.1 — 内部测试员 3 人跑 50 局 / 档**：

```bash
# 启动 human eval harness
.conda/bin/python training/evaluation/human_eval_harness.py \
  --serve-agent training/inference/serve_agent.py \
  --port 8790 \
  --log-dir training/artifacts/human_eval/$(date +%Y%m%d)
```

**记录字段**（每局一行）：

```json
{
  "player_id": "tester_03",
  "date": "2026-08-20",
  "difficulty": "normal",
  "map_id": "dungeon",
  "winner": "player",
  "duration_seconds": 87,
  "player_score": 3,
  "agent_score": 1,
  "rating_5scale": 4,
  "comments": "打得有来有回，但最后 30 秒被压着打"
}
```

**Step 5.2 — 验收**：

| 维度 | 阈值 |
|---|---|
| 局数 | 每档 ≥ 50 局 |
| 玩家数 | ≥ 3 个 tester |
| 地图分布 | 4 张地图都有 ≥ 10 局 |
| 中档（normal）`win_rate` | [0.50, 0.75] |
| 强档（strong）`win_rate`（玩家视角） | [0.20, 0.35] |
| 入门档（easy）`win_rate`（玩家视角） | ≥ 0.85 |
| 5 档接受率（5 分制 ≥ 3.5） | ≥ 0.7 |

**任一不通过**：调整对应档的 `temperature`/`mask_soften` 重新跑 Step 4 + Step 5，不重训。

### 3.6 Step 6 — 写入 tactical-rl-progress.md

把以下数字写入 `docs/training/status/tactical-rl-progress.md`：
- 5 档推理参数
- 5 档 vs scripted_normal/hard 胜率
- human eval 局数 / 接受率
- 5 档 manifest 路径

---

## 4. 失败回退

| 现象 | 原因 | 处理 |
|---|---|---|
| 5 档之间胜率不单调 | temperature / mask_soften 间隔太密 | 间隔扩大 1.5 倍 |
| 中档 win_rate 超过 0.75 | 玩家太弱 / 模型太稳 | 把 normal 的 temperature 提到 1.0 |
| 中档 win_rate 低于 0.50 | 玩家太强 / 模型太弱 | 把 normal 的 temperature 降到 0.7 |
| 入门档玩家都输 | temperature 太高打空枪 | 把 easy 的温度降到 1.2 |
| 顶级档玩家赢不了 | safety_override 触发太多 | 把 elite 的阈值降到 0.85 |
| 5 档都没有显著差异 | 推理参数没生效 | 检查 `sampler.py` 是否真消费了 `strength_profile` |

**绝对不能做的事**：为了让某些档"看起来好"而修改训练数据 / 改 `training/configs/rewards/`。

---

## 5. 阶段 5 完成后必做

1. 在 `docs/training/status/tactical-rl-progress.md` 末尾写"5 档强度分层验收报告"段；
2. 在 `README.md` "Hybrid Tactical Training" 段加"5 档难度"说明；
3. 提交 `model_catalog.json`、`sampler.py`、`main_menu.gd` 等所有改动；
4. 不更新 `default_model_id`——5 档并存，玩家在菜单选哪档就下发哪档。

---

## 6. 接续训练决策表（阶段 5 输出）

| 档位 | checkpoint | temperature | mask_soften | safety_threshold | vs scripted_hard | vs v1 | human eval | 决定 |
|---|---|---|---|---|---|---|---|---|
| easy | _ | 1.6 | 0.30 | 0.55 | _ | _ | _ | _ |
| casual | _ | 1.1 | 0.20 | 0.65 | _ | _ | _ | _ |
| normal | _ | 0.85 | 0.10 | 0.75 | _ | _ | _ | _ |
| strong | _ | 0.55 | 0.05 | 0.85 | _ | _ | _ | _ |
| elite | _ | 0.25 | 0.0 | 0.95 | _ | _ | _ | _ |

把这个表填完才能进入阶段 6（持续学习闭环）。
