# Pulse Arena 高层战术强化学习训练方案

## 1. 目标与边界

目标是在本机 CUDA GPU 上训练 `tactical_policy`，让模型只学习**高层战术**，而由 Godot 的传统算法稳定执行底层移动、瞄准和开火。模型不得直接输出原始 `PlayerAction`，也不得读取不可见敌人或 Arena 私有状态。

运行时链路固定为：

```text
AgentObservation（可见状态）
  -> TacticalFeatureBuilder（142 维特征 + 四组动作掩码）
  -> Tactical Actor-Critic（高层策略）
  -> HighLevelDecision（协议 v2）
  -> HybridCombatExecutor（确定性安全执行）
  -> PlayerAction
  -> ArenaPlayer
```

模型的四个离散决策头为：目标 `7` 类、移动模式 `12` 类、开火模式 `6` 类、技能模式 `6` 类。每步均使用动作掩码排除无效目标、不可用技能和不适用战术。

以下能力始终由确定性代码掌控：解析式提前瞄准、LOS 与墙体检查、友伤检查、开火冷却和能量保留、子弹威胁躲避、卡死恢复、模型超时/非法响应时的 Scripted Hard 回退。

## 2. 当前进度与不可混用部分

已完成：本机 `.conda` CUDA 环境、Godot 无头环境、协议 v2 基线审计、26 场正式课程采集、259,630 条有效 replay、GPU 行为克隆（BC）候选及 CUDA 推理加载验证。

BC 只是强化学习的 warm start。当前候选不能晋级：回放中的回退与重复决策比例过高，且现有 BC 验证集按行随机切分，连续帧可能同时位于训练和验证集，不能将其准确率解释为泛化能力。

不得复用 `training/rl/online_trainer.py` 作为本方案的训练器。它采样原始 move/aim/button 动作，会绕过 `HybridCombatExecutor`，且缺少 masked tactical action、GAE、序列训练与正确终局 bootstrap。

## 3. 完整训练闭环

### 3.1 数据质量与 BC 起点

1. Godot 使用 `TacticalTeacher` 在 Scripted Hard、历史策略和当前策略对局中记录 `hybrid_replay_v2`。
2. 每条记录包含 episode、seed、地图、模式、真实 tactical features、动作掩码、教师决策、最终执行动作、安全覆盖和回退诊断。
3. 数据集按 `episode_id` 分组；缺失时才退回到 `random_seed` 分组为 train/dev/holdout，禁止帧级随机切分。BC 优化只读取 train episode，验证只读取 dev episode。
4. 训练前必须运行 `training/server_agent/tactical_data_quality.py`，报告固定写入 `training/artifacts/runs/tactical_data_quality.json`。缺少 replay 输入、存在 malformed row、教师标签不在其动作掩码内，或任一动作头没有标签覆盖时，数据集直接取消资格；报告同时记录地图/模式覆盖、回退率和连续重复决策率。
5. mask-aware BC 从合法教师决策训练四个策略头，形成 RL 初始 checkpoint；BC 模型仅作为候选，不自动写入 catalog。

### 3.2 Godot 战术 Step API

在线训练的 Godot TCP JSONL 协议必须新增独立 tactical 入口：

- `reset` / `observe`：返回每个玩家真实 `tactical_features`、`action_masks`、可部署 actor 观测、累计 reward、episode 标识和 terminated/truncated；
- `step_tactical`：接收每玩家 `HighLevelDecision`，在 Godot 内应用掩码并交给 `HybridCombatExecutor`；
- response：返回 reward delta、奖励分量、下一状态、终局标记、实际执行 decision、safety override、fallback、卡死和开火诊断；
- legacy raw-action `step` 保留给历史试验，但 tactical 训练器不得调用它。

### 3.3 Masked Tactical PPO

actor 输入仅为 142 维 `tactical_features`；critic 默认共享同一可见输入。若以后增加 centralized critic，只能在训练时读取显式允许的训练状态，部署 actor 不变。

对每个 head，先将非法 logits 置为负无穷，再采样合法 categorical 动作。联合概率与熵为四个 head 的和：

```text
log π(a|s) = log π_target + log π_movement + log π_fire + log π_skill
entropy = entropy_target + entropy_movement + entropy_fire + entropy_skill
```

rollout 必须保存 feature、mask、四头 action、old log-prob、value、reward、terminated、truncated、episode id 和 GRU hidden state。使用 gamma 折扣、GAE-lambda、终局/截断 bootstrap、优势标准化、PPO clip、value loss、entropy bonus、KL 早停及 gradient clipping。使用 GRU 时必须按 episode 的时间序列做 sequence minibatch。

### 3.4 奖励与反钻空子

总奖励由可审计分量组成，而不是只看胜负：

- 正向：得分、击杀、有效伤害、胜局/排名、有效掩体存活、低能量恢复；
- 负向：死亡、环境死亡、空枪、无目标开火、被墙阻挡射击、无收益技能、危险区停留、卡死恢复触发；
- 约束：安全层覆盖与服务故障不作为模型能力得分；回退率过高的 rollout 不得作为晋级依据。

奖励只反映游戏结果和可观测诊断，不把私有状态泄漏给 actor。

### 3.5 课程、自博弈与吞吐

顺序为：地牢 1v1 基础战斗 → 能量纪律 → 掩体 → 四张地图机制 → 混合 FFA → 2v2。每阶段只在固定评测门槛达标后推进。

对手池按比例混合 Scripted Hard、当前策略、BC 基线与历史 archive。先实现单 Godot worker 的正确性与可恢复 checkpoint，再实现多端口 worker 池和批量 rollout；GPU 数量不是正确性的替代品。

### 3.6 评测、候选与晋级

每次候选在固定 holdout seed、四图、1v1、FFA 和 2v2 中对 Scripted Hard 与 BC 基线进行同 seed 成对评测。必须输出不可变 JSON/Markdown 报告。

默认 gate：四图 Scripted Hard 1v1 胜率不低于 `0.72`、FFA top-1 不低于 `0.40`、holdout 环境死亡率不高于 `0.06`、空枪率不高于 `0.10`、人工评测每图胜率不低于 `0.55`。同时检查回退、安全覆盖、延迟、卡死、单位能量伤害和相对于 BC 的回归。

只有所有 gate 通过、部署 smoke 通过并经人工确认，才允许把 manifest 写入 `training/models/model_catalog.json` 或设为默认模型。

## 4. 实施顺序

1. 先建立 group split、数据质量 gate 与中文实验记录；
2. 实现 Godot tactical Step API 及 protocol/schema 测试；
3. 实现 Python masked tactical actor-critic、GAE 和 PPO 单元测试；
4. 实现单 worker tactical PPO 闭环，从 BC checkpoint warm start；
5. 实现固定 seed 评测与候选 gate；
6. 在正确性通过后增加多 worker、课程和自博弈；
7. 运行 GPU pilot，产出候选、报告和可复现配置；
8. 人工审核后再部署。

## 5. 本机执行约束

- 使用项目 `.conda/bin/python` 和 CUDA；不重启、不改 NVIDIA 驱动；
- Godot 使用 `.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64`；
- 所有训练 run 固化随机种子、配置、replay 清单、checkpoint 与评测报告；
- 临时推理服务必须在验证后停止；
- 由于当前目录没有 Git 元数据，计划、子代理报告、测试输出和训练 artifact 是变更追踪依据。
