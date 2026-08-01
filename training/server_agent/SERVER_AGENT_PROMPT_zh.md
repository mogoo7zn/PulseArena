# Pulse Arena Hybrid Tactical v2：服务器端 agent 执行提示词

把以下文件视为本次任务的唯一执行规范。你是在一台 Linux + A100 服务器上的高级游戏 AI / 强化学习工程 agent。请按阶段顺序执行、保留证据、每个 gate 不通过就停止后续阶段并给出精确阻塞原因；不要用猜测代替结果。

## 0. 目标、边界与不可违反的约束

本次任务目标是完成一个可复现的 **单卡 A100 Hybrid Tactical v2 BC pilot**，交付经过数据审计的候选 checkpoint 与完整报告。它不是 8 卡全量 self-play，也不是旧 raw-action PPO 训练。

必须遵守：

1. 只使用 `CUDA_VISIBLE_DEVICES=0` 的一张 A100。不要申请、启用或假装使用 2/4/8 卡；当前 v2 tactical MLP 约 11 万参数，现有代码没有 DDP、多环境采样或 v2 MAPPO。
2. 绝不执行 `archive/legacy_raw_ai/` 下的训练、checkpoint 或 manifest；它们是 `raw_action_v1_only`，与 Hybrid v2 不兼容。
3. 不要执行 `training/rl/online_trainer.py`，不要用它生成或宣称 v2 模型。它输出原始 `PlayerAction`，会绕过 `HybridCombatExecutor`。
4. 不删除、不覆盖任何已有 replay、checkpoint、运行目录或归档。所有新产物写入 `training/runs/`、`training/replays/` 或一个新的数据集目录。数据预处理脚本遇到非空输出目录会拒绝执行；此时换一个新目录，不要删除旧目录。
5. 任何候选模型都不能更新 `training/models/model_catalog.json`，更不能成为默认模型。只有固定种子、跨地图的实际对局评测通过晋级门槛后，才允许由人工决定是否导入。
6. 不能把训练/验证分类准确率称为“游戏战力”。当前教师是规则函数，且回放原先按物理帧记录；随机样本切分会存在强时间相关泄漏。

当前架构必须保持为：

```text
142 维可观测 tactical features
  -> 高层离散目标/移动/开火/技能决策
  -> HybridCombatExecutor
  -> 解析弹道瞄准、开火门控、躲弹、安全覆盖、卡住恢复
  -> PlayerAction
```

模型不能直接接管 `move/aim/shoot/dash/shield` 原始连续动作。

## 1. 解压与环境预检（必须执行）

在压缩包所在目录执行：

```bash
sha256sum -c pulsearena_hybrid_tactical_v2_agent_bundle_*.tar.gz.sha256
tar -xzf pulsearena_hybrid_tactical_v2_agent_bundle_*.tar.gz
cd pulsearena_hybrid_tactical_v2_agent_bundle_*
sed -n '1,260p' training/server_agent/SERVER_AGENT_PROMPT_zh.md
export CUDA_VISIBLE_DEVICES=0
export GODOT_BIN=/absolute/path/to/godot
python training/server_agent/preflight.py --godot "$GODOT_BIN" --require-cuda --output training/runs/server_agent_preflight.json
```

如果压缩包的实际文件名前缀不同，使用同目录的 `*.tar.gz` 与 `*.sha256`，不要手工修改 checksum 文件。`preflight.py` 必须报告：Python 3.10+、NumPy、Matplotlib、PyTorch CUDA 可用、至少 1 个 GPU、以及 Godot 4 可执行文件。如果失败：停止，输出报告中的 `failures`，不要盲目下载或升级 CUDA/PyTorch。

随后执行基础测试：

```bash
python tests/smoke/static_project_check.py
"$GODOT_BIN" --headless --path . --script tests/run_tests.gd
"$GODOT_BIN" --headless --path . --script tests/smoke/map_build_check.gd
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_pilot_bc --phase validate
```

只有全部返回 0 才进入下一阶段。将每个命令、退出码、关键 stdout/stderr 摘要写入 `training/runs/server_agent_<UTC时间>/reports/command_log.md`。

## 2. 有界回放采集（必须执行）

先运行小型 pilot，不能直接跑 `stage=all` 或旧的全阶段 BC 脚本：

```bash
RUN_ID=server_agent_pilot_$(date -u +%Y%m%dT%H%M%SZ)
export RUN_ID
COLLECT_STAGE=01_foundation_combat \
COLLECT_MATCHES=8 \
COLLECT_SECONDS=30 \
COLLECT_SEED=51000 \
RUN_BC=0 \
bash training/server_train_hybrid_tactical_v2.sh
```

这会完成：预检、测试、8 场有界 Hybrid v2 回放采集、原始回放审计、按 15Hz 决策时间桶降采样、降采样后审计。报告目录为：

```text
training/runs/$RUN_ID/reports/
```

如果需要诊断，不改变源回放，重新执行：

```bash
python training/server_agent/audit_hybrid_replays.py \
  --replay-dir training/replays \
  --output training/runs/$RUN_ID/reports/raw_replay_audit.json \
  --min-rows 1000
python training/server_agent/audit_hybrid_replays.py \
  --replay-dir training/replays_decision \
  --output training/runs/$RUN_ID/reports/decision_replay_audit.json \
  --min-rows 1000
```

## 3. 数据 gate（必须评审，不能跳过）

阅读两个 audit JSON，逐项记录以下结论：

- `parse_errors == 0`；`illegal_teacher_labels == 0`；两者任一不满足则停止 BC。
- 原始回放与降采样数据均应有至少 1,000 条 hybrid row；小于此值说明采集或模式错误。
- 原始数据的 `consecutive_equal_decision_rate` 很高是预期信号：它证明 recorder 是物理帧级，不能把原始随机切分 accuracy 当泛化指标。
- 降采样后必须有正数输出，且输出行数明显少于原始行数。检查 target、movement、fire、skill 四个 head 的分布；若某 head 只有一个类别，BC 只能做管线 smoke，不能评价策略。
- `fallback_rate`、`safety_override_rate` 必须写入报告。它们不是自动失败，但必须明确说明模型/教师最终有多少决策被确定性层覆盖。

pilot 只有 dungeon/FFA，不能作为跨地图候选。若 gate 通过，按同样的有界方法补采 `04_dungeon_mechanics`、`05_sky_city_mechanics`、`06_jungle_mechanics`、`07_mist_world_mechanics` 与 `09_team_2v2`；每阶段先 8 场、30 秒、使用互不重叠的 seed。每次都生成新的 `replays_decision_<run-id>` 数据集，不能覆盖旧的 `training/replays_decision`。

注意：现有 pilot plan 固定使用 `training/replays_decision`。只有在你已审核 pilot 后，才可以复制该 plan，改成新的数据集和新的 `output_dir`，并在报告中记录新 plan 的完整 diff。不得修改 `hybrid_tactical_v2_server_bc.json` 的设计意图。

## 4. 单卡 BC pilot（仅在数据 gate 通过后执行）

先确认 GPU 可见性，然后显式启动 BC：

```bash
export CUDA_VISIBLE_DEVICES=0
RUN_BC=1 RUN_ID="$RUN_ID" bash training/server_train_hybrid_tactical_v2.sh
```

该阶段使用 `hybrid_tactical_v2_server_pilot_bc`：hidden=256、batch=4096、40 epoch。运行时记录：GPU 名称/显存、实际 samples、总耗时、每 epoch 耗时、最优验证 loss、四个 head 的验证准确率、以及 `metrics.csv`、`metrics.png`、checkpoint SHA-256。

BC 完成并不等于模型可推广。必须在报告中写明以下限制：

- 标签来自 `TacticalTeacher` 规则，BC 的上限通常是近似教师而不是超过教师；
- trainer 当前按样本随机切分，尚未按 episode/seed 做 group split；
- 所有低层运动、瞄准与安全仍由 Godot 确定性代码负责；
- 该 checkpoint 只能是未晋级的 `tactical_policy` 候选，不能更新 catalog/default。

若 BC 脚本失败、损失为 NaN/Inf、输出 checkpoint 不存在，立即停止并保存 traceback 与前 100 行/后 100 行日志。

## 5. 必须交付的报告

在 `training/runs/$RUN_ID/reports/final_report.md` 中给出：

1. 服务器环境和实际使用 GPU 数（应为 1）；
2. 全部命令、返回码、运行时间；
3. raw 与 decision-rate replay 的审计 JSON 摘要和完整路径；
4. 数据集范围：地图、模式、seed、对局数、行数、类别分布、fallback/safety 比率；
5. BC 配置、输出文件、SHA-256 与训练曲线；
6. 失败/风险：时间重复、规则教师上限、缺少 group split、缺少真实对局评测；
7. 明确的 `GO` 或 `NO-GO`：是否允许进入“实现专用 tactical PPO/MAPPO”的工程阶段。这个结论不能以 BC accuracy 单独决定。

## 6. 下一工程阶段：只写实施计划，不要在本次 pilot 中偷偷开跑

若且仅若 pilot 的数据、训练和报告完整，输出 `training/runs/$RUN_ID/reports/tactical_ppo_implementation_plan.md`。计划必须要求新实现满足：

1. 新建 v2 tactical runner；不复用 `online_trainer.py` 的 raw action 路径。
2. actor 输出四个 **masked categorical** heads；联合 log-prob 是四 head log-prob 之和；非法动作在采样、训练和推理都被 mask。
3. Godot 训练接口接收 `HighLevelDecision`，并仍调用 `HybridCombatExecutor`，不能把 raw action 注入 `ArenaRoot`。
4. 使用正确的 episode boundary、bootstrap value、GAE-lambda、优势标准化、序列 minibatch 与持久 GRU hidden state。
5. FFA/2v2 训练 critic 可使用合法 centralized state；部署 actor 不得读取隐藏敌人私有状态。
6. 先实现多 Godot worker/port 的向量化采样和吞吐基准；只有采样吞吐和 learner 利用率证明有需求时，再考虑 2 卡。4/8 卡要用于并行独立实验/评测或经过验证的分布式 learner，不能仅靠配置文件宣称。
7. 在实现前补齐按 episode/seed 的 group split、固定 holdout 自动评测，以及 `evaluation_matrix.json` 中的胜率、环境死亡率与空枪率 gate。

本次任务结束时不要开始 2/4/8 卡训练。提交 final report、所有 JSON、日志和候选 checkpoint 的路径，等待用户确认下一阶段。
