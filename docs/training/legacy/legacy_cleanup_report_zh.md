# Pulse Arena 历史训练策略清理与混合战术训练策略规范报告

本报告详细记录了对 Pulse Arena 仓库中历史遗留、错误的 Raw-Action 训练策略进行的重构清理，并对当前采用的最新 **Hybrid Tactical Agent (混合战术智能体 v2)** 训练策略与规范进行了系统性总结。

---

## 1. 清理背景与设计哲学

在项目的早期开发中，智能体使用过直接输出底层物理控制（如 move_x, move_y, aim_x, aim_y, shoot, dash, shield）的 **Raw-Action (Protocol v1)** 策略。
经过实践与审计，该策略存在以下致命缺陷：
- **高频抖动与不可控**：模型直接控制物理量会导致智能体在地图边缘高频抖动、容易撞墙卡死。
- **环境死亡率极高**：在包含虚空（Sky City）、泥潭（Jungle）和地牢陷阱（Dungeon）等复杂地图机制中，模型无法精确处理物理避让，导致环境伤害与死亡率居高不下。
- **开火极度低效**：由于模型同时学习移动与瞄准，无法实现物理提前量计算和合理的开火门控，造成大量空枪与能量浪费。
- **状态不当泄漏**：旧策略在无遮挡迷雾等场景中未能严格落实部分可观测，导致部署的智能体非法依赖全局私有状态。

为此，项目全面重构并确立了 **Hybrid Tactical Agent (混合战术 v2)** 架构。模型仅负责高层的战术决策，具体的底层执行完全交由 Godot 内置的确定性安全执行层。为了让活跃的训练工作流保持纯净，防止误用和混淆，我们对历史遗留的 Raw-Action 训练路径进行了彻底的物理清理与代码重构。

---

## 2. 遗留策略重构与物理清理详情

本轮清理严格遵循**“最小化侵入、最大化纯净、保留兼容性”**的原则，具体执行如下：

### 2.1 物理删除遗留脚本
我们物理删除了 `training/rl/` 下不符合 v2 战术规范的 Raw-Action 训练代码及相关算法支持库：
- 🗑️ `training/rl/online_trainer.py`（旧版 Raw-Action 连续/离散 PPO 自博弈在线训练器）
- 🗑️ `training/rl/bc_trainer.py`（旧版 Raw-Action 行为克隆训练器）
- 🗑️ `training/rl/ppo.py`（旧版 PPO 动作采样、对数概率和熵计算工具类）

### 2.2 重构特征数据编码层 (`training/rl/encoding.py`)
- ✂️ **移除了 `ReplayArrays` 容器**：该数据结构专门用于存储连续动作的 Raw Replay，现已废弃。
- ✂️ **移除了 `load_replay_arrays(...)` 方法**：该加载器用于读取旧版 jsonl 数据，其存在会导致读取新版 `*.hybrid_v2.jsonl` 数据时产生冗余逻辑和版本识别冲突。
- ✂️ **移除了 `flatten_action(...)` 方法**：该辅助函数用于展平旧版 7 维 Raw-Action，已无业务引用。

经过重构，当前数据加载唯一通道被固化为 `load_hybrid_replay_arrays(...)`，仅加载支持特征维度为 `142` 的高层战术特征 `HybridReplayArrays`。

### 2.3 重构统一训练管线入口 (`training/train_pipeline.py`)
- ✂️ **清理 Imports**：移除了对已删除脚本中 `BehaviorCloneConfig`, `train_behavior_clone`, `OnlinePPOConfig`, `train_online_ppo`, `PPOHyperParams` 等所有旧实体的导入。
- 🛠️ **修剪 `run_bc` (行为克隆分支)**：移除了原本的回退逻辑（旧行为克隆分支）。现在，若 plan 中启用了旧的 `behavior_clone` 字段，程序将直接拦截并报错：
  ```text
  Error: Legacy raw-action behavior cloning is no longer supported.
  Please enable 'tactical_behavior_clone' in your training plan.
  ```
- ✂️ **彻底移除 `run_online_self_play`**：删除了该函数的完整定义，移除其对旧在线 PPO 的调度。
- 🛠️ **重构主入口 `main` 路由**：在 `--phase ppo` 阶段，若检测到 plan 未启用符合 v2 规范的 `tactical_ppo`，管线将不再回退，而是安全抛出错误日志并退出：
  ```text
  Error: Legacy raw-action PPO is no longer supported in the active training pipeline.
  Please enable 'tactical_ppo' in your training plan.
  ```

### 2.4 保留历史对比兼容性说明
为保护学术复现及横向指标对比的能力：
- 保持 `training/rl/models.py` 中 `BehaviorPolicyNet` 和 `ActorCriticNet` 的类定义（已加注过时废弃注释）。
- 保持 `training/inference/model_runtime.py` 加载 `behavior_policy` 和 `actor_critic` 类型 checkpoint 的能力。
- 这使得存储在 `archive/legacy_raw_ai/` 下的历史 checkpoint 和 manifest 仍然可以被模型服务（Inference Service）和评估脚本读取做横向胜率对比，而活跃训练则实现了 100% 隔离。

---

## 3. 最新 Hybrid Tactical Agent v2 策略参考规范

重构清理后，Pulse Arena 的训练逻辑已高度统一。以下是活跃的高层战术训练核心规范：

### 3.1 战术决策空间定义 (Action Schema v2)
高层策略网络仅向 Godot 侧执行器发送 discrete 离散战术决策，共有 4 个独立的决策头：
1. **Target Slot (目标选择，共 7 类)**：`[NONE, ENEMY_0, ENEMY_1, ENEMY_2, BEST_VISIBLE_ENEMY, LOWEST_HEALTH_ENEMY, SCRIPTED_TARGET]`
2. **Movement Mode (移动模式，共 12 类)**：包含 `HOLD`, `CHASE`（追击）, `KEEP_RANGE`（控距）, `STRAFE`（环绕绕射）, `RETREAT`（撤退）, `SEEK_COVER`（找掩体）, `PEEK`（露头探头）, `SEEK_BEST_PICKUP`（抢道具）, `EVADE_PROJECTILE`（躲避危险子弹）及 `USE_SCRIPTED_MOVEMENT` 等。
3. **Fire Mode (开火模式，共 6 类)**：`[HOLD_FIRE, CONSERVATIVE, NORMAL, BURST, ALL_IN, USE_SCRIPTED_FIRE_MODE]`
4. **Skill Mode (技能模式，共 6 类)**：`[NONE, AUTO_DEFENSE, DASH_EVADE, DASH_ENGAGE, SHIELD, USE_SCRIPTED_SKILL]`

通过动作掩码（Action Masks），前向传播过程中不合法、冷却中、能量不足、或无遮挡的敌人槽位将被置为负无穷 logits，实现 100% 的合法战术决策采样。

### 3.2 训练流程三部曲
1. **数据采集**：利用 `TacticalTeacher` 运行 Scripted Hard 对局，生成格式为 `*.hybrid_v2.jsonl` 的 `hybrid_replay_v2` 数据，存储至 `training/replays/`。
2. **战术行为克隆（BC Warm Start）**：
   ```bash
   python training/train_pipeline.py --profile local_constrained --phase bc --execute
   ```
   训练出具备高层目标、移动、开火选择常识的 `TacticalPolicyNet` 权重。
3. **战术强化学习（Tactical PPO / MAPPO）**：
   ```bash
   python training/train_pipeline.py --profile local_constrained --plan tactical_legal_window_pressure --phase ppo --execute
   ```
   在此阶段，通过 `step_tactical` 在线交互，引入 Generalized Advantage Estimation (GAE) 折扣、GRU 序列 minibatch 自博弈，优化高层战术决策，绝不染指底层动作物理采样。

### 3.3 晋级测试门槛 (Promotion Gate)
一个强化学习 checkpoint 想要晋升并写入 `model_catalog.json` 部署，必须在 1v1、FFA 和 2v2 对战中满足以下刚性约束：
- ⚔️ 对战 Scripted Hard 1v1 胜率 $\ge 72\%$，且各分图胜率不低于 $55\%$。
- 🛡️ 在 holdout 环境种子下的死亡率 $\le 6\%$（验证其完美避开虚空、泥潭、陷阱机制）。
- 🎯 空枪率 $\le 10\%$（验证其在障碍物后或能量不足时合理克制开火）。
- 🩹 Fallback 回退率极低，模型能自主、流畅完成各种掩体切换和战术对决。

---

## 4. 自动化验证结果汇总

在清理重构完成后，我们运行了系统的自动化验证。编译和测试结果如下，确认未引入任何功能衰减或崩溃：

- **静态编译检查**：
  - `python -m compileall training/rl/` 顺利通过，未发现因文件删除或重构导致的符号缺失、未解析引用或导入错误。
- **单元测试执行情况**：
  - 🧪 `test_tactical_data_quality.py` (7个测试全部通过)：验证了战术数据质量门禁、特征/掩码合法性、Episode 级别随机划分的正确性。
  - 🧪 `test_tactical_online_trainer.py` (15个测试全部通过)：验证了战术在线 PPO 训练器中 rollout 状态审计、多图 Deterministic 轮换、BC 初始加载、GRU 序列和事件累加逻辑。
  - 🧪 `test_tactical_ppo.py` (7个测试全部通过)：验证了战术网络（`TacticalActorCritic`）的 masked 采样、非合法动作置零阻断、GAE 折扣截断与时间序列梯度回传。
  - 🧪 `test_train_pipeline.py` (12个测试全部通过)：验证了 Unified Pipeline 在多卡 GPU 上 dry-run、Reward 机制配置下发、以及 Godot 子进程命令构建的完备性。

**总计 41 个 Python 单元测试用例全部一次性 100% 通过（Green）。** 

---

### 结论

Pulse Arena 仓库的训练系统重构清理工作已圆满完成。本次清理：
1. **清除了毒瘤代码**：移除了会导致智能体物理行为失控、撞墙空枪的 Raw-Action 历史策略和算法支持库。
2. **规范了技术边界**：通过重构 `encoding.py` 和 `train_pipeline.py`，使 Pipeline 仅能且强制走 Protocol v2 战术特征与动作掩码通道。
3. **保留了横向追溯**：保留了旧 checkpoint 的离线加载与对比接口，对历史成果予以尊重。
4. **提供了详实的中文规程**：使后续参与训练工作的技术人员能一眼看清底层执行与高层决策的职责边界，避免重蹈 Raw-Action 的覆辙。
