# 架构概览

Pulse Arena 在运行时将**流程控制、实体仿真、玩家控制、UI、回放与强化学习接口**清晰地分离开。

## 🎯 角色分工

| 模块 | 职责 |
|---|---|
| `GameFlowManager` | 维护全局状态转移（菜单 ↔ 对战 ↔ 结算） |
| `ArenaRoot` | 组合单局对战的全部节点、规则与控制器 |
| `ArenaPlayer` | 唯一消费 `PlayerAction`，不感知控制来源 |
| `PlayerController` | 各控制器把 `AgentObservation` 翻译成 `PlayerAction` |
| `ObservationBuilder` | 把比赛状态编码成 Agent 观测（与玩家/子弹解耦） |
| `RewardCalculator` | 独立维护奖励分量（用于训练与回放审计） |
| UI 层 | 监听 `GameEvents` 与状态快照，不进入观测通道 |

> 当前应用一次只激活 **一个 Arena**。`EnvironmentBridge` 已为后续多 Arena 批量训练留好接口。

---

## 🤖 Hybrid Tactical Agent

默认 Agent 架构遵循**"模型决策 + 算法执行"分层**：

```text
AgentObservation
  → TacticalFeatureBuilder
  → Protocol v2 Learned Tactical Policy
  → HighLevelDecision
  → HybridCombatExecutor
  → PlayerAction
```

- `HybridCombatExecutor` 负责：解析式提前量瞄准、LOS / 撞墙检查、开火门控、子弹威胁躲避、移动 hysteresis、卡墙恢复。
- `ArenaPlayer` 仍然只接收 `PlayerAction`，与训练策略解耦。
- **raw-action 模型**（Protocol v1、`ModelAgentController` 直出 move/aim/shot）已归档到 `archive/legacy_raw_ai/`，**不再进入默认菜单、活动 catalog 与默认训练计划**——只用于复现历史报告与离线对比。
