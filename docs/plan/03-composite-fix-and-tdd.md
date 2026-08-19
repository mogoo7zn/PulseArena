# 阶段 2：复合修复与 TDD（红→绿循环）

> **目的**：在阶段 1 拿到 GPU-4 数字**之前**，先把所有 `_archived/` 写到的"修复方向"按 TDD 跑通。这样阶段 1 的训练产物才是基于"修复后"的代码，而不是"修复前"的代码。
>
> **范围**：本期不写新代码（按"仅整理结构"原则），只跑现有未提交改动的红→绿。  
> **失败处理**：哪一组红，把那一组按 `_archived/` 里对应的 plan 走 TDD，每组单独 commit。

---

## 0. 准备

```bash
cd /data/mogoo7zn/PulseArena
# 确认 GODOT_HOME、Python venv、目录权限
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --version
```

## 1. 一组测试：Godot 单元 + 静态检查（5–10 分钟）

```bash
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --headless --disable-crash-handler --path . -s res://tests/run_tests.gd
python3 tests/smoke/static_project_check.py
```

**预期**：

- `tests/run_tests.gd` 全绿（baseline fire 拒绝、emergency 阈值、pressure lane、vantage routing 等）；
- `static_project_check.py` 通过。

**失败对应**：

- `pressure lane` 失败 → 回 `ballistic_aim_solver.gd` + `tactical_feature_builder.gd`；
- `vantage routing` 失败 → 回 `movement_executor.gd`；
- `baseline fire 拒绝` 失败 → 回 `fire_control.gd`。

## 2. 二组测试：Python 单元（5–10 分钟）

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
PYTHONPATH=. \
  .conda/bin/python -m unittest discover -s tests/unit -v
```

**预期**：所有 `test_*.py` 全绿。

**失败对应**：

- `test_tactical_online_trainer.py` 失败 → 按 `_archived/2026-08-08` 与 `_archived/2026-08-06` 的 plan 走 TDD；
- `test_tactical_ppo.py` 失败 → 检查 `tactical_ppo.py` 与 `models.py`；
- `test_train_pipeline.py` 失败 → 检查 `train_pipeline.py` 的 plan 解析；
- `test_evaluate_tactical_candidate.py` 失败 → 检查 `evaluate_tactical_candidate.py` 的 godot-service runner；
- `test_multi_gpu_orchestrator.py` 失败 → 检查 `multi_gpu_orchestrator.py`；
- `test_model_runtime.py` / `test_import_trained_model.py` 失败 → 检查 `inference/` 与 `import_trained_model.py`；
- `test_archive_pre_draw_fix_runs.py` 失败 → 检查 `training/tools/archive_pre_draw_fix_runs.py`；
- `test_replay_integrity.py` 失败 → 检查 `training/rl/replay_integrity.py`；
- `test_audit_hybrid_replays.py` 失败 → 检查 `training/server_agent/audit_hybrid_replays.py`；
- `test_training_preflight.py` 失败 → 检查 `training/preflight` 流程；
- `test_baseline_audit.py` 失败 → 检查 `training/evaluation/baseline_audit.py`。

## 3. 三组测试：协议 smoke（≤ 5 分钟）

```bash
HOME="$PWD/.tools/godot-user" \
python3 tests/smoke/tactical_training_protocol_check.py \
  --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --port 18766
```

**预期**：

- protocol `2`、feature 142 维、mask 7/12/6/6；
- raw 字段被拒绝；
- 玩家齐全性校验通过。

**失败对应**：

- Feature 长度不对 → 检查 `tactical_feature_builder.gd`；
- mask 长度不对 → 检查 `tactical_decision.gd`；
- raw 字段被接受 → 立即停——这是 protocol v1 leak，**严肃问题**。

## 4. 四组测试：CUDA micro-update（≤ 5 分钟）

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
PYTHONPATH=. \
.conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_ppo.py' -v
CUDA_VISIBLE_DEVICES=0 \
HOME="$PWD/.tools/godot-user" \
.conda/bin/python tests/smoke/tactical_ppo_cuda_micro_update.py
```

**预期**：

- Python 部分全绿；
- CUDA micro-update 输出"step 1 / 4 / 16 / 64 done"。

**失败对应**：

- Python 失败 → 退到 2.；
- CUDA 失败 → 检查 `.conda` 虚拟环境是否包含 `torch==2.5.1+cu121`，Driver 是否 ≥ 535。

## 5. 每组失败的 TDD 路径

| 失败组 | 找哪份 plan | 找哪份 design |
|---|---|---|
| ballistic lane / vantage routing | `_archived/2026-08-08-ballistic-lane-and-reserve-repair.md` Task 1 | `_archived/2026-08-08-ballistic-lane-and-reserve-repair-design.md` |
| reserve basis | `_archived/2026-08-08-ballistic-lane-and-reserve-repair.md` Task 2 | 同上 |
| cover→re-engage 生命周期 | `_archived/2026-08-06-high-playability-combat-loop-repair.md` Task 1 | `_archived/2026-08-06-high-playability-combat-loop-repair-design.md` |
| pressure 控件暴露 | `_archived/2026-08-06-high-playability-combat-loop-repair.md` Task 2 | 同上 |
| decision generation 账本 | `_archived/2026-08-04-pressure-reward-accountability.md` Task 1 | `_archived/2026-08-04-pressure-reward-accountability-design.md` |
| 资源兑现账本 | `_archived/2026-08-04-four-map-combat-resource-foundation.md` Task 2 | `_archived/2026-08-04-four-map-common-combat-resource-foundation-design.md` |
| 4 地图 source-tagged 事件 | `_archived/2026-08-04-four-map-combat-resource-foundation.md` Task 3 | 同上 |
| 4 地图调度 | `_archived/2026-08-04-four-map-combat-resource-foundation.md` Task 4 | 同上 |

## 6. 阶段 2 完成后必做

1. 把所有测试命令与结果写进 `docs/training/status/tactical-rl-progress.md` "文档维护记录"段；
2. 跑一次 `git status`，把仍然 M 的文件分两类：
   - "已通过测试 + 保留" → 提交；
   - "已通过测试 + 弃用" → 归档到 `training/artifacts/runs/archived/` 或 `docs/training/legacy/`；
3. 进入阶段 1（如果阶段 1 还没跑）或回到阶段 1 重新跑（如果阶段 1 已经跑过）。

## 7. 整套测试跑一遍的脚本

```bash
cd /data/mogoo7zn/PulseArena

# 1. Godot
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --headless --disable-crash-handler --path . -s res://tests/run_tests.gd \
  || echo "[!] Godot tests failed"

# 2. Python
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
PYTHONPATH=. \
  .conda/bin/python -m unittest discover -s tests/unit -v \
  || echo "[!] Python tests failed"

# 3. Static
python3 tests/smoke/static_project_check.py \
  || echo "[!] static check failed"

# 4. Protocol
HOME="$PWD/.tools/godot-user" \
python3 tests/smoke/tactical_training_protocol_check.py \
  --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
  --port 18766 \
  || echo "[!] protocol smoke failed"

# 5. CUDA micro
CUDA_VISIBLE_DEVICES=0 \
HOME="$PWD/.tools/godot-user" \
.conda/bin/python tests/smoke/tactical_ppo_cuda_micro_update.py \
  || echo "[!] CUDA micro failed"
```

每一步失败都写 `[!]` 但**不退出**，方便一次看完整。
