# 阶段 6：持续学习闭环（5 档自动调节）

> **目的**：在 5 档强度分层上线后，建立"人类对局 → replay → 重训 → 5 档自动调节"的闭环，避免模型上线后随玩家群体水平变化而失效。
> **前置**：阶段 5 全部完成；5 档已在 `model_catalog.json` 登记；human eval 已跑过 50 局/档。
> **关键边界**：持续学习**只重训 BC、不重训 PPO**；重训后的 BC 只更新 `hybrid_tactical_v1_easy` 档（一档），其余 4 档从强档 PPO 重新导出。

---

## 1. 为什么需要持续学习

- 如果不做闭环，1 个月后涌入大量"打过几局"的玩家，模型会"越来越打不过真人"——因为 slime 训练集全部来自 scripted + 早期 PPO。
- 人类对局就是最新的"分布外"数据，必须回流。
- 不重训 PPO 是因为 PPO 训练成本高、稳定性差；用 BC 调一档，其余沿用现有 PPO checkpoint，**风险最低**。

---

## 2. 数据回流通道

### 2.1 human eval → replay

human eval harness（`training/evaluation/human_eval_harness.py`）已经记录每局 JSON。**额外**写一份 `hybrid_replay_v2` JSONL：

```python
# training/evaluation/human_eval_harness.py
def record_gameplay_as_replay(player_id, game_id, decisions, observations, ...):
    """把每局的人机对局转成 hybrid_replay_v2 格式"""
    rows = []
    for step in decisions:
        row = {
            "episode_id": game_id,
            "match_id": game_id,
            "player_id": ...,
            "map_id": ...,
            "mode_id": ...,
            "timestamp": ...,
            "observation_schema_version": 2,
            "observation": step.obs,
            "tactical_features": step.tactical_features,
            "action_masks": step.action_masks,
            "teacher_decision": step.teacher_decision,  # 由 hybrid_tactical_v1_normal 提供
            "teacher_label_version": "human_eval_v1",
            "label_source": "human_playthrough",
            "label_weight": 1.0 / max(1, count_human_games_this_week),
            "outcome": step.outcome,
        }
        rows.append(row)
    return rows
```

**输出**：`training/data/replays/human_eval_continual/<YYYYMMDD>.hybrid_v2.jsonl`

**频率**：每天合并前一天的所有对局到 1 个文件；超过 1000 行就拆成 2 个。

### 2.2 replay 质量门

不直接拿人类对局重训——人类会犯错（撞墙、空枪、不躲弹）。质量门要做 3 件事：

1. **去掉玩家早期死亡的对局**：玩家 30 秒内死亡的去掉，不作为 teacher 数据；
2. **保留玩家获胜的对局**：玩家赢的对局保留，作为"如何赢"的范例；
3. **去掉 `fallback_used=true` 行**：这些行战术决策被骗过，不适合当 teacher。

```bash
# 每周日 03:00 跑一次
PYTHONPATH=. .conda/bin/python \
  training/server_agent/human_eval_replay_filter.py \
  --input-dir training/data/replays/human_eval_continual \
  --output-dir training/data/replays/human_eval_continual_filtered \
  --min-game-duration 30 \
  --drop-fallback-only
```

---

## 3. 课程 BC 重训

### 3.1 节奏

**每周一次**（周日 03:00 Asia/Shanghai）：

1. 拉取本周 7 天的 `human_eval_continual_filtered/` 数据；
2. 合并到 `training/data/replays/human_eval_continual_cumulative/`；
3. 跑 BC warm-start：`replays/human_eval_continual_cumulative + fair_share 1:1 配上 scripted 四图数据`；
4. 输出 `training/artifacts/runs/continual_bc_<YYYYMMDD>/best_tactical_policy.pt`；
5. **仅**把这份 checkpoint 登记成 `hybrid_tactical_v1_easy`（入门档），因为它最容易"学习近期分布"，不容易过拟合。

### 3.2 命令

```bash
cd /data/mogoo7zn/PulseArena

# 1. 数据合并
PYTHONPATH=. .conda/bin/python \
  training/continual/build_continual_replay.py \
  --input-dir training/data/replays/human_eval_continual_filtered \
  --output training/data/replays/human_eval_continual_cumulative \
  --ratio-human-to-scripted 1:1

# 2. 跑 BC（单 GPU 4）
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan hybrid_tactical_v2_continual_bc \
  --phase bc --execute

# 3. 评估
.conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
  --manifest training/models/hybrid_tactical_v1_easy_continual_<YYYYMMDD>_agent.json \
  --runner godot-service \
  --output-dir training/artifacts/runs/evaluations/continual_easy_<YYYYMMDD> \
  --split dev --max-jobs 8

# 4. 登记到 catalog
.conda/bin/python training/model_io/import_trained_model.py \
  --checkpoint training/artifacts/runs/continual_bc_<YYYYMMDD>/best_tactical_policy.pt \
  --metrics-json training/artifacts/runs/continual_bc_<YYYYMMDD>/metrics.jsonl \
  --model-id hybrid_tactical_v1_easy_continual_<YYYYMMDD> \
  --run-id hybrid_tactical_v2_continual_<YYYYMMDD> \
  --hidden 256 \
  --strength-profile easy \
  --update-catalog
```

### 3.3 关键约束

- **不动 PPO**：continual BC 只重训 1 档（easy），其余 4 档沿用上阶段 PPO checkpoint。
- **不全量学**：每周只学最近 30 天的人类数据，超过 30 天的归档到 `training/data/replays/human_eval_continual_archived/`。
- **保留旧 easy**：continual BC 后的 easy 不能直接覆盖旧 easy，必须先跑 1 周 dev eval，确认中档（normal）玩家体验**不下降**（即 normal 玩家 vs 旧 easy 还能赢 0.85+）。只有通过才把 easy 切换。

---

## 4. 5 档自动调节

### 4.1 滑动窗口统计

每周一 02:00 跑一次：

```python
# training/continual/strength_tier_monitor.py
from pathlib import Path
import json
from datetime import datetime, timedelta

WINDOW_DAYS = 7
TIERS = ["easy", "casual", "normal", "strong", "elite"]
TIER_ORDER = {t: i for i, t in enumerate(TIERS)}

def load_human_eval(directory: Path) -> list[dict]:
    """加载最近 WINDOW_DAYS 天的人类对局记录"""
    cutoff = datetime.now() - timedelta(days=WINDOW_DAYS)
    games = []
    for f in directory.glob("*.jsonl"):
        for line in f.read_text().splitlines():
            game = json.loads(line)
            game_date = datetime.fromisoformat(game["date"])
            if game_date >= cutoff:
                games.append(game)
    return games

def win_rate_by_tier(games: list[dict]) -> dict[str, float]:
    rates = {}
    for tier in TIERS:
        relevant = [g for g in games if g["difficulty"] == tier]
        if not relevant:
            rates[tier] = None
        else:
            wins = sum(1 for g in relevant if g["winner"] == "player")
            rates[tier] = wins / len(relevant)
    return rates

def monotonicity_violated(rates: dict[str, float]) -> bool:
    """检查胜率是否从 easy 到 elite 严格单调递增"""
    values = [rates[t] for t in TIERS if rates[t] is not None]
    return any(values[i] >= values[i+1] for i in range(len(values)-1))

def out_of_range(rates: dict[str, float]) -> list[str]:
    """检查是否在目标区间内"""
    target = {
        "easy":    (0.85, 1.00),
        "casual":  (0.65, 0.85),
        "normal":  (0.50, 0.75),
        "strong":  (0.20, 0.35),
        "elite":   (0.05, 0.20),
    }
    bad = []
    for tier, (lo, hi) in target.items():
        r = rates.get(tier)
        if r is None: continue
        if not (lo <= r <= hi):
            bad.append(f"{tier}={r:.3f} (target {lo}-{hi})")
    return bad
```

### 4.2 调节规则

**触发条件**（满足任一就触发）：

- 任意一档的 `win_rate` 偏离目标区间（如 normal 跑到 0.80）；
- 5 档不单调（strong 反而比 normal 弱）；
- 某档 `win_rate` 连续 2 周低于区间下沿（玩家太强）。

**调节动作**（最多 ±10%）：

| 偏离方向 | 调整目标 |
|---|---|
| 玩家太强（win_rate 太低） | 把对应档的 `temperature` 降低 0.05，`mask_soften` 降低 0.02 |
| 玩家太弱（win_rate 太高） | 把对应档的 `temperature` 提高 0.05，`mask_soften` 提高 0.02 |
| 5 档不单调 | 把对应档的 `temperature` 拉远相邻档 0.10 |
| 持续 2 周低于区间 | 触发阶段 5 的"重导出 5 档 manifest"流程 |

**调节命令**：

```bash
# 1. 跑 monitor
PYTHONPATH=. .conda/bin/python training/continual/strength_tier_monitor.py \
  --log-dir training/artifacts/human_eval \
  --output training/artifacts/runs/continual/tier_suggestion_<YYYYMMDD>.json

# 2. 看建议
cat training/artifacts/runs/continual/tier_suggestion_*.json | jq .

# 3. 手动应用（每周一次）
PYTHONPATH=. .conda/bin/python training/continual/apply_tier_adjustment.py \
  --suggestion training/artifacts/runs/continual/tier_suggestion_<YYYYMMDD>.json \
  --update-catalog
```

### 4.3 调节上限

- 每周最多调整 1 档（避免一次改太多）；
- 累计调整不超 ±20%（从阶段 5 锁定值算起）；
- 任何手动 tie-out（玩家投诉）触发**冻结**：本周不再调。

---

## 5. 监控看板

每周一邮件 + dashboard：

| 指标 | 来源 | 阈值 |
|---|---|---|
| 5 档胜率 | human eval harness | 见 4.2 目标区间 |
| 5 档评估 | paired eval | 单调且 ≥ 0.55 |
| raw_step_calls | serve_agent | == 0 |
| fallback_rate | rollout_audit | < 0.005 |
| safety_override_rate | rollout_audit | < 0.10 |
| 玩家平均评分 | human eval | ≥ 3.5 |
| 持续学习 BC head accuracy | metrics.jsonl | ≥ 0.85 |

任一不通过 → 触发"冻结本周"。

---

## 6. 接续训练决策表（阶段 6 输出）

| 周次 | 步长 | 5 档胜率 | 调节动作 | 决定 |
|---|---|---|---|---|
| W1 | 7 天 | easy X / casual X / normal X / strong X / elite X | _ | _ |
| W2 | 7 天 | _ | _ | _ |
| W3 | 7 天 | _ | _ | _ |
| ... | ... | ... | ... | ... |

把这个表填完，最终的目标是：**6 个月内 5 档胜率稳定在目标区间内**。

---

## 7. 长期路线

- 阶段 6 跑通 4 周后（每周 50+ 局/档）：把 `hybrid_tactical_v2_promoted_<日期>.pt` 升级为 `hybrid_tactical_v3_promoted_<日期>.pt`，触发阶段 1–5 重跑一次（用 4 周后的混合数据）。
- 阶段 6 跑通 12 周后：考虑"难度自适应"——根据玩家最近 10 局表现动态调整难度档位；该功能放到 `07-difficulty-adaptation.md`（下一份计划）。
- PPO 持续学习不在这份计划里；等 BC 闭环稳定至少 1 个季度后再评估。
