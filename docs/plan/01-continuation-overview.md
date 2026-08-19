# 接续训练阶段总览

> **阶段地图**：阶段 0（决策）→ 阶段 1（GPU-4 isolated diagnostic）→ 阶段 2（复合修复的 TDD）→ 阶段 3（扩训）→ 阶段 4（推送到默认服务）。  
> **每阶段都有"硬门槛 + 退出条件 + 失败回退路径"**。  
> **每个阶段的实操细节**：阶段 1 在 `02-`，阶段 2 在 `03-`，阶段 3 / 4 在 `04-`。

---

## 阶段 0：决策与基线确认（不跑训练）

**目标**：回答"以哪个未提交改动作为阶段 1 的输入"。

**执行**：

1. 读 `00-baseline-and-status.md`。
2. 用 `git diff --stat` 看未提交改动覆盖范围，与 `_archived/` 里的 08-06 / 08-08 设计稿对照。
3. 在 PR / 工作记录里回答 `00-` 末尾的"接续训练决策表"6 个问题。
4. （可选）把"幽灵候选"归档到 `training/artifacts/runs/archived/_index/`。

**退出条件**：

- 决策表所有问题有答案；
- 已写明阶段 1 用哪个 plan / 哪个 GPU。

**失败回退**：

- 如果 52 个 modified 文件太多/太杂，先把 `_archived/` 里 08-06 / 08-08 的设计稿"复活"成新的 spec（放到 `docs/superpowers/specs/`，**不要**再放 `_archived/`），再写一份"修复 plan"放在 `docs/superpowers/plans/`，把未提交改动冻结。

---

## 阶段 1：GPU-4 isolated diagnostic（**第一个跑训练的阶段**）

**目标**：在 1 张 GPU（推荐 GPU-4）跑 `tactical_legal_window_pressure_four_map_ballistic_repair`，把"修复是否真有效"用数据证明。

**执行入口**：

```bash
# 准备
mkdir -p training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4
mkdir -p training/data/replays/four_map_ballistic_repair_bc
mkdir -p training/artifacts/runs/four_map_ballistic_repair_bc

# 1. 收集 BC 数据（32 局 60s）
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_ballistic_repair \
  --phase collect --execute

# 2. 训练 BC（用上面采集的数据）
CUDA_VISIBLE_DEVICES=4 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_ballistic_repair \
  --phase bc --execute

# 3. PPO warm-start BC（16,384 env-steps，端口 18961）
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

实操细节见 `02-GPU-4-isolated-diagnostic.md`。

**验收门槛**（6 条**全部**通过才能进入阶段 2；任一不通过就回到阶段 0 重新决策）：

1. `raw_step_calls == 0`；
2. `fallback_rate == 0`；
3. `decision_generation_consistent == true` 与 `audit_consistency_flags == true`；
4. 4 张地图**都有** episodes（`total_episodes_by_map[dungeon] > 0 && ... && mist_world > 0`）；
5. `fire_authorized / fire_intent >= 0.015`（参考基线 1.57%，本阶段目标 1.5%）；
6. Sky City 与 Mist World 的 `no_line_of_sight` 块**必须**低于 68.4% / 72.0% 基线**且** `reserved_energy` 拆原因后能说出主导项。

**附加观察指标**（不作为门槛，但必须看）：

- `cover_entry_count` 与 `cover_reengage_count` 都 > 0；
- `map_reserved_energy_by_basis` 至少能识别出 `dash_ready` / `shield_ready` / `low_health` / `projectile_threat` / `base` / `conservative` / `burst` / `all_in_kill_window` 中的 3 个非零项；
- `authorized_damage_count > 0`。

**退出条件**：

- 6 条硬门槛全部通过 → 进入阶段 2；
- 任一硬门槛失败 → 回到阶段 0，重新决策。

**失败回退**：

- LoS 仍是主要块：检查 `ballistic_aim_solver.evaluate_observation_lane` 是否真在 `tactical_feature_builder.gd` 被消费；如果消费了但 LoS 仍高，多半是 vantage 路由不够；**不要直接调 PPO 超参**。
- reserve 拆不出原因：检查 `fire_control.gd` 是否把 `reserve_basis` 写到 diagnostics，并确认 `environment_bridge.gd` 的 whitelist 里允许它；**不要调阈值**。
- cover 进了不出：检查 `movement_executor.gd` 的 candidate-shooter observation；**不要扩 PPO**。
- raw_step_calls > 0：立刻停——任何 PPO 调用了 legacy raw step 的 run 必须废弃。

---

## 阶段 2：复合修复的 TDD（红→绿循环）

**目标**：把 `_archived/` 里 08-04 / 08-06 / 08-08 三套修复按 TDD 跑通，并把每条测试写到 git。

**执行入口**：

```bash
# 1. Godot 单元 + smoke
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --headless --disable-crash-handler --path . --script tests/run_tests.gd

# 2. Python 单元
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
PYTHONPATH=. \
  .conda/bin/python -m unittest discover -s tests/unit -v

# 3. 静态检查
python3 tests/smoke/static_project_check.py
```

实操细节见 `03-composite-fix-and-tdd.md`。

**验收门槛**（按修复分组）：

| 修复 | 必须通过的测试 | 失败对应 |
|---|---|---|
| decision generation 账本 | `test_tactical_online_trainer.py` 中所有 generation 相关 | `arena_root.gd` 没把 generation 传出去 |
| 资源兑现账本 | `reward_calculator_profile_test.gd` 资源块 + Python audit | `pickup.gd` / `player.gd` 还在以"拾到"为奖励 |
| 4 地图 source-tagged 事件 | `reward_calculator_profile_test.gd` taxonomy + 1-match smoke | map rule 没传 source |
| ballistic lane 共享 | `tests/run_tests.gd` 的 pressure+lane case | `ballistic_aim_solver.evaluate_observation_lane` 未在 `tactical_feature_builder` 消费 |
| reserve 拆原因 | `test_tactical_online_trainer.py` 的 basis case + `tactical_training_protocol_test.gd` | `fire_control.gd` 没写 `reserve_basis` |
| cover→re-engage 生命周期 | `test_tactical_online_trainer.py` 的 transition case | `tactical_online_trainer.py` 没记 `cover_entry_count` 等 |
| pressure 控件暴露 | `tests/run_tests.gd` 的 cover / fire case | `tactical_teacher.gd` 没用 config 参数 |

**退出条件**：

- 上述 7 组**全部**全绿；
- 阶段 1 的 6 条门槛仍然成立（不要把跑过的 diagnostic 跑坏了）。

**失败回退**：

- 红→绿没做完之前不要回到阶段 1（会重新跑很久）；
- 哪一组红就把那一组按 `_archived/` 的 plan 走 TDD，每一组单独提交。

---

## 阶段 3：扩训（8 卡 BC warm-start + PPO resume）

**目标**：在阶段 1 + 阶段 2 完成后，把单 GPU diagnostic 扩到 8 卡并行。**已知：8 卡是 8 个独立 checkpoint，不是 MAPPO。**

**执行入口**（仅在阶段 1+2 完成后执行）：

```bash
# 1. 8 卡 PPO multi
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi --execute

# 2. 评估每个 worker 出来的 candidate
for gpu in 0 1 2 3 4 5 6 7; do
  .conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
    --runner godot-service \
    --candidate-dir training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu${gpu} \
    --output-dir training/artifacts/runs/evaluations/hybrid_tactical_v2_8gpu_parallel_pilot_gpu${gpu} \
    --seeds 8
done
```

实操细节见 `04-promotion-and-deployment.md`。

**验收门槛**：

- 8 个 worker 全部 `returncode=0`；
- 每个 worker 的 `raw_step_calls == 0`；
- 至少 1 个 candidate 通过 `evaluate_tactical_candidate.py` 的 gate 层（不是 promotion，只是 gate 通过）；
- `model_catalog.json` 的 `default_model_id` **未自动变更**。

**退出条件**：

- 至少 1 个 candidate 通过 gate；
- 通过 gate 的 candidate 被登记到 `model_catalog.json`（**手动**，通过 `import_trained_model.py --update-catalog`）。

**失败回退**：

- 任一 worker `raw_step_calls > 0` → 该 worker 的 checkpoint 全部作废，不进 catalog；
- 8 个 candidate 都没过 gate → 回到阶段 1 重新跑 diagnostic；
- 资源争抢（端口冲突 / GPU OOM） → 缩到 4 卡重试。

---

## 阶段 4：晋级与生产部署

**目标**：把通过的 candidate 推到默认服务。**这一步是接续训练的"出口"，也是最难的一步。**

**执行入口**（仅在阶段 3 完成后执行）：

```bash
# 1. 把通过 gate 的 candidate 导入 manifest
.conda/bin/python training/model_io/import_trained_model.py \
  --checkpoint training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu<N>/best_tactical_ppo.pt \
  --metrics-json training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu<N>/metrics.jsonl \
  --model-id hybrid_tactical_v2_promoted_<YYYYMMDD> \
  --run-id hybrid_tactical_v2_promoted_<YYYYMMDD> \
  --hidden 256 \
  --update-catalog
```

实操细节见 `04-promotion-and-deployment.md`。

**验收门槛**：

- paired baseline win/top1 ≥ 0.55（候选 vs `hybrid_tactical_v1` baseline）；
- human eval 通过（至少 5 个玩家、≥ 0.7 接受率）；
- 6 个月内无安全回退（无 `raw_step_calls > 0`、无 PPO 跨卡同步事故）；
- `model_catalog.json` 的 `default_model_id` 显式更新。

**退出条件**：

- 候选上线后至少观察 7 天；
- 观察期内无 promotion 回退。

**失败回退**：

- 任何 paired/human 指标下滑 → 立即把 `default_model_id` 回滚到 `hybrid_tactical_v1`；
- 任何 raw-step 重现 → 候选下线、归档；
- 安全覆盖异常（safety override > 10%）→ 候选归档、不再继续。

---

## 总验收表

| 维度 | 阶段 1 | 阶段 2 | 阶段 3 | 阶段 4 |
|---|---|---|---|---|
| `raw_step_calls == 0` | ✅ | ✅ | ✅ | ✅ |
| `fallback_rate == 0` | ✅ | ✅ | ✅ | ✅ |
| 4 张地图都有 episodes | ✅ | ✅ | ✅ | ✅ |
| `fire_authorized/fire_intent ≥ 0.015` | ✅ | ✅ | ✅ | ✅ |
| Sky/Mist LoS 块 < 68.4% / 72.0% | ✅ | ✅ | ✅ | ✅ |
| reserve basis 可识别 | ✅ | ✅ | ✅ | ✅ |
| paired win/top1 ≥ 0.55 | ❌ | ❌ | 准备 | ✅ |
| human eval ≥ 0.7 | ❌ | ❌ | ❌ | ✅ |
| `model_catalog.json` 默认变更 | ❌ | ❌ | ❌ | ✅ |

---

## 用户新确认的目标（2026-08-16）

在阶段 0–4 完成之上，叠加三个新目标。新目标决定**阶段 3 训练出什么**、**阶段 4 如何对**、**阶段 5 持续学习如何跑**：

| 编号 | 决策 | 含义 | 落地位置 |
|---|---|---|---|
| D1 | 同一份模型 + 不同推理参数做强度分层 | 用 1 份 checkpoint 通过 `temperature + mask_soften + safety_override_threshold` 5 个组合导出 5 档 | 阶段 3 末尾 → `manifest` 多 profile |
| D2 | human_eval 中档 `win_rate ∈ [0.50, 0.75]` | 中档必须"打得有来有回"，门槛比 0.7 接受率更直接 | 阶段 4 验收 / `docs/plan/05-` |
| D3 | 启用菜单 | 玩家在 Godot 主菜单可选 5 档难度 | `scripts/app/main_menu.gd` + `MatchConfig` |
| D4 | 强度分层 5 档（easy / casual / normal / strong / elite） | "中档能打的有来有回 / 强档比人类强" | `docs/plan/05-` 与 `06-` |

> **顺序**：阶段 0 → 1 → 2 → 3（D1 落地）→ 4（D2 + D3 落地）→ 5（D4 持续学习）。  
> 文档：
> - 强度分层实现 + human eval 接入 + 菜单集成 → `05-strength-tier-and-human-eval.md`
> - 持续学习闭环 + 5 档自动调节 → `06-continuous-learning-loop.md`
