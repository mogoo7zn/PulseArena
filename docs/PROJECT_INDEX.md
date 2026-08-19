# 项目顶层索引

> 整个仓库的"地图"。如果你只想看接续训练，请直接去 [`docs/plan/`](plan/README.md)。

## 0. 接续训练

- **`docs/plan/README.md`**——下一次训练怎么开始，每一步命令、硬门槛、回滚条件。
- **`docs/plan/00-baseline-and-status.md`**——当前 active 状态、政策与已知风险。
- **`docs/plan/01-continuation-overview.md`**——阶段 0–4 的目标 / 命令 / 验收 / 退出条件。
- **`docs/plan/02-GPU-4-isolated-diagnostic.md`**——下一阶段先跑的诊断。
- **`docs/plan/03-composite-fix-and-tdd.md`**——动手前的红→绿循环。
- **`docs/plan/04-promotion-and-deployment.md`**——什么时候把候选模型推到默认服务。

## 1. 项目核心代码（活跃）

- `scripts/` —— Godot 4 / GDScript 运行时。
  - `app/` 主入口；`core/` 跨模块服务；`config/` 数值与配置；`arena/` 对战主控 + 4 张地图规则；`gameplay/` 玩家/子弹/道具；`controllers/` 玩家与 AI 控制器（`hybrid_agent_controller.gd` 是当前 active）；`rl/` 观测、奖励、桥接；`replay/` 回放；`debug/` 调试覆盖层；`ui/` 菜单与 HUD。
  - `agents/hybrid/` —— Hybrid Tactical v2 的高层决策 + 确定性执行层（`tactical_decision`、`tactical_feature_builder`、`ballistic_aim_solver`、`fire_control`、`movement_executor`、`hybrid_combat_executor` 等）。
- `scenes/` —— Godot 场景（主菜单、对战、HUD、调试覆盖）。
- `resources/` —— 默认数值表与地图数据。
- `assets/` —— 美术 / 音频 / shader 资源。

## 2. 训练代码（Python）

- `training/pipelines/train_pipeline.py` —— 统一训练流水线（validate/collect/bc/ppo/ppo-multi/all）。
- `training/core/` —— RL 算法与 replay 编码（`tactical_bc_trainer.py`、`tactical_online_trainer.py`、`tactical_ppo.py`、`encoding.py`、`godot_env.py`、`models.py`、`model_runtime.py`、`replay_integrity.py`、`swanlab_utils.py`、`league.py`）。
- `training/inference/` —— 推理服务（`serve_agent.py`、`diagnose_policy.py`；`model_runtime.py` 已迁入 `core/`）。
- `training/evaluation/` —— 基线契约审计（`baseline_audit.py`）+ 候选评估（`evaluate_tactical_candidate.py`）。
- `training/server/` —— 服务器 agent 工具集：`preflight`、`prepare_hybrid_replays`、`audit_hybrid_replays`、`tactical_data_quality`、`multi_gpu_orchestrator`、`estimate_resources`、`package_server_bundle`、`import_trained_model`、`migrate_legacy_checkpoint`、`archive_pre_draw_fix_runs`，以及 server-agent prompt 与 README。
- `training/configs/` —— 训练计划、profile、奖励、GPU 资源估计。

## 3. 训练产物（不在 git 跟踪中）

- `training/artifacts/runs/` —— 训练运行时产物；详见 `training/artifacts/runs/README.md`。
- `training/artifacts/runs/evaluations/` —— 评估快照；详见 `_index/README.md`。
- `training/models/` —— manifest 与 `model_catalog.json`（catalog 是线上的"白名单"）。
- `training/data/replays/` —— 新采集的 hybrid replay。
- `training/artifacts/checkpoints/` —— 导入后的 checkpoint。
- `training/data/incoming_models/` —— 服务器上传入口。

## 4. 文档

- `docs/README.md` —— 总入口。
- `docs/architecture/` —— 架构与 hybrid agent 文档。
- `docs/agents/` —— agent 接口与集成。
- `docs/game/` —— 玩法设计、技能、关卡。
- `docs/design/` —— UI 设计。
- `docs/operations/` —— Linux / 项目结构 / 服务器训练 bundle。
- `docs/training/` —— 训练策略、流程、handoff、runbook。
- `docs/training/status/` —— 当前进行中的活跃进度报告。
- `docs/plan/` —— **接续训练计划（写在这里）**。
- `docs/deployment/` —— 网页对战与演示部署。

## 5. 测试

- `tests/run_tests.gd` —— Godot 集成测试入口。
- `tests/unit/` —— Python 单元测试（`test_tactical_ppo.py`、`test_tactical_online_trainer.py`、`test_evaluate_tactical_candidate.py` 等）。
- `tests/smoke/` —— 端到端 smoke（`tactical_training_protocol_check.py`、`tactical_ppo_cuda_micro_update.py`、HUD / 地图 / 摄像机布局等）。

## 6. 工具与本地

- `.tools/godot-4.7.1/` —— 本地 Godot 4.7.1 二进制（不在 git 跟踪）。
- `.conda/` —— conda 虚拟环境（不在 git 跟踪）。
- `Makefile` —— 顶层快捷命令。
- `requirements.txt` / `requirements-training.txt` —— Python 依赖。
