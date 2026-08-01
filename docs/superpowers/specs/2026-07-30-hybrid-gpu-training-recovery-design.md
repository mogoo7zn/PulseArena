# Hybrid Tactical GPU 训练恢复设计

## 目标

在本机 GPU 上完成一个可复现、可评测、可部署的 Hybrid Tactical Agent
训练闭环。智能体保持当前的分层边界：Godot 中的传统算法负责低层执行，
PyTorch 模型只输出高层战术决策。

本阶段的最终产物是一个通过固定评测门槛的 `tactical_policy` checkpoint、
对应模型 manifest、可运行的本地推理服务，以及保存完整配置和指标的训练记录。

## 已确认的架构边界

运行时数据流保持如下形式：

```text
AgentObservation
  -> TacticalFeatureBuilder (142 维特征 + action masks)
  -> TacticalPolicyNet
  -> HighLevelDecision (protocol v2)
  -> HybridCombatExecutor
  -> PlayerAction
  -> ArenaPlayer
```

以下能力必须继续由确定性 Godot 代码掌控，训练模型不得绕过它们：

- 移动意图执行、碰墙/LOS 检查和卡死恢复；
- 解析式抛体提前瞄准；
- 开火冷却、能量保留、命中概率、友伤和遮挡门控；
- 子弹威胁分析以及高危情形的安全覆盖；
- 模型超时、协议错误、NaN/Inf、低置信度或无合法动作时回退 Scripted Hard。

模型只选择目标、移动模式、开火模式和技能模式。部署 actor 只能读取已公开的
`tactical_features` 与 `action_masks`；如后续使用 centralized critic，它只可
存在于训练过程。

## 分阶段实施

### 阶段 1：可复现基线审计

目的：确保当前 Godot/Python 协议、模型目录和训练计划本身一致，避免把已有
接口错配误判成训练问题。

执行内容：

- 运行静态检查、Python 编译检查和可用的无头 Godot smoke；
- 核对 v2 observation、142 维特征、action heads、动作掩码、模型 catalog 与
  replay schema；
- 记录当前可运行命令、版本和失败项，形成基线报告。

验收：能明确区分代码/配置故障与环境故障；现有 smoke 成功或有可定位的失败
证据。

### 阶段 2：GPU 训练环境恢复

目的：让本机 Python 能可靠调用 NVIDIA GPU。

执行内容：

- 诊断 NVIDIA 驱动、内核模块、`nvidia-smi`、CUDA runtime 和容器/宿主机可见性；
- 在获得用户授权后进行必要的驱动安装、升级、模块加载或重启；
- 建立项目隔离的 Python 训练环境，安装与实际 CUDA 驱动兼容的 PyTorch；
- 验证 `torch.cuda.is_available()`、GPU 名称、显存、简单张量计算及一个短训练步骤。

验收：GPU 可被 PyTorch 稳定识别，训练步骤运行在 CUDA 上，并记录版本与显存
基线。若宿主机未向本环境暴露 GPU，则记录外部阻塞和所需宿主机操作，不用 CPU
伪装为 GPU 训练成功。

### 阶段 3：小规模端到端闭环

目的：在少量数据和短时训练下验证采集、训练、推理、游戏执行四段连接正确。

执行内容：

- 用 `hybrid_tactical_v1` / Scripted Hard 采集少量 `hybrid_replay_v2`；
- 对 replay 执行 schema、mask 和标签质量审计；
- 运行 mask-aware tactical behavior cloning warm start；
- 将 checkpoint 注册为临时模型，启动 `serve_agent.py`，运行 Hybrid headless
  match 验证模型决策和 fallback 行为。

验收：训练 loss 有限且下降、checkpoint 能加载、推理协议 v2 正常、游戏实际
收到模型高层动作；任何 fallback 都有明确诊断原因。

### 阶段 4：正式数据集与 BC 基线

目的：得到覆盖地图、对局模式和种子的高质量初始 tactical policy。

执行内容：

- 根据 curriculum 采集分层 teacher replay；
- 清理/降权无效、低置信或过度脚本委托标签，保留采集清单与统计；
- 用 GPU 训练 BC，并保存 checkpoint、config、随机种子、学习曲线和资源统计；
- 以固定 evaluation matrix 对比 Scripted Hard 和 `hybrid_tactical_v1`。

验收：BC policy 可完成全套固定种子评测，且没有安全指标显著恶化；否则不晋级
RL 阶段。

### 阶段 5：高层强化学习微调

目的：只改进高层战术选择，不破坏可靠的低层控制与安全约束。

执行内容：

- 从 BC checkpoint 初始化 tactical PPO；多智能体扩展需求明确后可使用 MAPPO；
- 逐步提高地图、对手、模式和时长难度，使用 curriculum gate 控制晋级；
- 持续记录回退率、无目标开火、墙体阻挡开火、卡死恢复、命中率、空枪率、
  单位能量伤害、胜率和环境死亡率；
- 定期与固定 Scripted Hard 对手及 BC checkpoint 对战，防止遗忘和策略钻空子。

验收：候选策略超过 BC 基线和既定对手，且满足所有安全/稳定性 guardrail；未达标
的 run 仅保留作实验记录，不进入模型 catalog。

### 阶段 6：晋级、部署与续训

目的：把经验证的 checkpoint 安全加入游戏，并使后续训练可复现。

执行内容：

- 生成 `tactical_policy` manifest，导入 `training/models/model_catalog.json`；
- 用推理服务和游戏内/无头流程做部署回归；
- 固化训练计划、环境版本、数据集清单、评测表和模型说明；
- 保留上一个稳定模型，确保部署失败时可回滚。

验收：模型可以从 catalog 启动、在游戏运行且通过部署 smoke；文档足以让同一台
机器重新运行或继续该实验。

## 风险与处理原则

- 当前 `nvidia-smi` 无法与驱动通信，且 Python 未安装 PyTorch。GPU 恢复是最早的
  外部依赖；驱动安装、内核模块变更或重启必须在操作前获得用户授权。
- 本目录没有 `.git`，无法复原丢失会话的提交历史，也不能按流程提交设计文档。
  后续所有重要变更均应通过可读配置、实验记录和运行日志保留可追踪证据。
- Godot `EnvironmentBridge` 目前为单 Arena。阶段 3--4 先保证单实例闭环；只有在
  GPU 利用率与采样吞吐证明为瓶颈后，才建设 vectorized worker IPC。
- 旧 raw-action PPO/BC 仅用于历史比较，不得作为 v2 tactical policy 的默认训练
  或部署来源。

## 推荐执行顺序

先完成阶段 1，再做阶段 2。阶段 2 成功后立即跑阶段 3 的最小闭环；只有闭环
验证通过才投入批量采集、正式 BC 与 RL，避免在不可部署或协议不一致的管线上
消耗 GPU 时间。
