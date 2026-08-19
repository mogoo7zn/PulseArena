# Pulse Arena 接续训练计划

> **开始之前**：本目录是接续训练的权威入口。所有"下一阶段怎么打"的问题，先读这里的 `README.md` 与本目录其它文件，再决定是否动 `docs/superpowers/_archived/`、`docs/training/legacy/` 或 `scripts/` 下的代码。
>
> **范围约定**：本计划**不修改**任何 Godot/Python 业务代码（你之前选定的"仅整理结构"）。当某阶段需要改代码时，会单独标注为"需新写 plan"。
>
> **写作时间**：2026-08-15  
> **基线参考点**：`docs/training/status/tactical-rl-progress.md`（最后更新 2026-08-04）  
> **目录路径**：`docs/plan/`  
> **语言**：中文  
> **接续目标**：训练一个**强而高可玩性**的高级策略 agent——能在 4 张地图上稳定走完"接近合法目标 → 受压找掩护 → 再接战并把合法窗口转化为命中"这条环路，并满足 `legal_window_pressure` profile 的硬门槛。

---

## 目录内容

| 文件 | 作用 |
|---|---|
| `README.md` | 本文件——总入口、阶段地图、运行前置条件。 |
| `00-baseline-and-status.md` | 当前 active 状态、政策、模型目录、已知风险。读完才能开始动手。 |
| `01-continuation-overview.md` | 阶段 0–4 的目标 / 命令 / 验收 / 退出条件一张图（**2026-08-16 已追加用户决策 D1–D4**）。 |
| `02-GPU-4-isolated-diagnostic.md` | 阶段 1 的实操细节：先把 `legal_window_pressure` 在 GPU-4 跑通 isolated diagnostic。 |
| `03-composite-fix-and-tdd.md` | 阶段 2 的实操细节：把 08-06 / 08-08 的修复按红→绿循环跑完。 |
| `04-promotion-and-deployment.md` | 阶段 3 / 4：从候选晋级默认服务的判定标准。 |
| `05-strength-tier-and-human-eval.md` | 阶段 5（2026-08-16 新增）：5 档强度分层实现 + human eval 接入 + 菜单集成。 |
| `06-continuous-learning-loop.md` | 阶段 6（2026-08-16 新增）：人机对局 → replay → BC 重训 → 5 档自动调节。 |

---

## 8. 2026-08-16 用户新确认的目标（D1–D4）

详见 `01-continuation-overview.md` 末尾的"用户新确认的目标"段。简述：

- **D1**：同一份模型 + 不同推理参数做强度分层（1 份 checkpoint 导出 5 档）。
- **D2**：human_eval 中档 `win_rate ∈ [0.50, 0.75]`（中档必须"打得有来有回"）。
- **D3**：启用菜单（在主菜单选 5 档难度）。
- **D4**：5 档命名 `easy / casual / normal / strong / elite`。

完整落地：`05-` + `06-`。

---

## 1. 一句话总结

**先验证后扩训**。当前所有 PPO 候选都已稳定但"打得不够"——授权开火密度只有 1.57%、Sky/Mist 的 LoS 块 68–72%、`SEEK_COVER→re-engage` 环路未跑起来。修复方向（08-06 + 08-08）已经写在 `_archived/` 里但**还没有通过 TDD**，代码层只是"看起来就位"。因此下一阶段的工作不是"再跑一次大训练"，而是：

1. 把红→绿循环跑通（`tests/run_tests.gd` + Python `unittest`）；
2. 在 GPU-4 跑一份 isolated diagnostic；
3. **门槛通过后**才扩到 8 卡 / 多 GPU 并行；
4. 通过 paired eval 与 human eval 后才推到 `model_catalog.json` 默认。

---

## 2. 当前接续的位置（基线）

### 2.1 已就位、**已通过测试**的部分

- Hybrid Tactical v2 协议（protocol v2，feature 长度 142，action mask 7/12/6/6）；
- `tactical_online_trainer.py` + `tactical_ppo.py` 单 worker 闭环 + 8 卡多任务 pilot；
- `evaluate_tactical_candidate.py --runner godot-service` 服务链路 self-play smoke；
- `model_catalog.json` 包含 1 个默认 + 2 个非默认 v2 PPO 候选。

### 2.2 已就位、**未通过测试或未跑过**的部分

> 这部分对应 `git status` 里的 52 个 modified 文件 + 多个 untracked 计划。**必须先做阶段 0–2 才能进入阶段 3**。

- decision generation 账本（`arena_root.gd` + `reward_calculator.gd` + `environment_bridge.gd`）；
- 资源兑现账本（`pickup.gd` + `player.gd` + `reward_config.gd`）；
- 4 张地图的 source-tagged 事件（`dungeon/sky_city/jungle/mist_world_rule.gd`）；
- ballistic lane 共享判定（`ballistic_aim_solver.gd` + `tactical_feature_builder.gd` + `movement_executor.gd`）；
- reserve 拆原因审计（`fire_control.gd` + `hybrid_combat_executor.gd` + `environment_bridge.gd`）；
- cover→re-engage 生命周期审计（`tactical_online_trainer.py`）。

### 2.3 当前模型目录

```text
default_model_id: hybrid_tactical_v1
candidate:
  - hybrid_tactical_v2_ppo_expanded_candidate_20260802
  - hybrid_tactical_v2_ppo_resume_candidate_20260802
未登记但 manifest 存在（候选幽灵，需先决定去留）：
  - pressure_contact_reset_fallback_free_candidate
  - pressure_curriculum_geometric_fire_gpu7_candidate
  - pressure_curriculum_resource_gpu6_candidate
```

### 2.4 历史硬约束

- **任何续训/胜率报告都不能用 `training/artifacts/runs/archived/pre_draw_fix/` 下的产物做对照**——draw-as-win bug 修前数据作废。
- **不允许自动晋升** checkpoint（`model_catalog.json` 只能通过 `import_trained_model.py --update-catalog` 显式更新）。
- **训练不允许复用** `training/rl/online_trainer.py` / `bc_trainer.py` / `ppo.py`——已删除；任何新代码必须用 `tactical_*` 系列。
- 协议必须 v2：feature 142 维、mask 7/12/6/6、4 个 masked categorical head。

---

## 3. 阶段地图

| 阶段 | 目标 | 命令入口 | 退出条件 | 文档 |
|---|---|---|---|---|
| 0 | 看懂现状，决定要不要先补代码 | `git status` + 读 `00-baseline-and-status.md` | 形成"是否需要新写修复 plan"的决定 | `00-baseline-and-status.md` |
| 1 | GPU-4 isolated diagnostic | `training/pipeline/train_pipeline.py --profile local_constrained --plan tactical_legal_window_pressure_four_map_ballistic_repair --phase all --execute`（具体见 `02-`） | `rollout_audit.json` 通过 6 条硬门槛 | `02-GPU-4-isolated-diagnostic.md` |
| 2 | 复合修复的 TDD 红→绿 | `tests/run_tests.gd` + `tests/unit/*.py` | 全绿 + 全 4 张地图都有 cover_event | `03-composite-fix-and-tdd.md` |
| 3 | 扩训（8 卡 BC warm-start + PPO resume） | `training/orchestration/multi_gpu_orchestrator.py` + `--phase ppo-multi --execute` | 阶段 1 + 阶段 2 的门槛 + paired eval | `04-promotion-and-deployment.md` |
| 4 | 推送到默认服务 | `import_trained_model.py --update-catalog` | human eval 通过 + 6 个月无回退 | `04-promotion-and-deployment.md` |
| 5 | 5 档强度分层 + human eval + 菜单 | `sampler.py` + `main_menu.gd` + `evaluate_tactical_candidate.py` | 5 档胜率严格单调 + human eval 中档 [0.50, 0.75] | `05-strength-tier-and-human-eval.md` |
| 6 | 持续学习闭环 | `human_eval_harness.py` + `continual_bc_<YYYYMMDD>` | 6 个月内 5 档胜率稳定在目标区间 | `06-continuous-learning-loop.md` |

---

## 4. 运行前置条件（每次动手前先确认）

```bash
# 1. Godot 二进制存在
ls -la .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64

# 2. Python 虚拟环境存在
.conda/bin/python --version
.conda/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count())"

# 3. 端口空闲
ss -tlnp | grep -E '18766|18767|18945|18961|18962|18963|18964|8870|8877' || echo "ports free"

# 4. 目标 GPU 空闲
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | head -8

# 5. 当前模型目录
cat training/models/model_catalog.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('default:', d['default_model_id']); print('models:', [m['model_id'] for m in d['models']])"
```

如果上面任意一项不通过，**不要开始跑**。

---

## 5. 怎么读这份计划

1. 第一次接续训练：先读 `00-`，再读 `01-`，然后按 `02-` 跑 GPU-4 diagnostic。
2. 想看历史决策：`docs/training/legacy/status_reports/`。
3. 想看完整 4 阶段硬门槛：`01-` 末尾的"总验收表"。
4. 想看每阶段具体命令：直接到对应 `02-` / `03-` / `04-`。

---

## 6. 怎么改这份计划

- 仅在阶段全部完成、并把对应数字填进 `tactical-rl-progress.md` 之后，才能更新这里的硬门槛。
- 任何新写的设计稿放到 `docs/superpowers/specs/`；实施计划放到 `docs/superpowers/plans/`；完成后再迁移到 `_archived/`。
- 任何训练命令写进 `02-` / `03-` / `04-`，而不是直接贴在 README 里——README 只放地图。

---

## 7. 联系与变更记录

| 时间 | 变更 | 文档 |
|---|---|---|
| 2026-08-15 | 初始化本目录：把 `docs/superpowers/plans/_archived/` 的 08-06 / 08-08 计划整理为可执行阶段 | 本 README |
| (待) | 完成阶段 1 后补 GPU-4 diagnostic 数字 | `02-` + `tactical-rl-progress.md` |
| (待) | 完成阶段 2 后补 TDD 红绿记录 | `03-` + `tactical-rl-progress.md` |
| (待) | 完成阶段 3 后补扩训数字与晋级候选 | `04-` + `tactical-rl-progress.md` |
