# Hybrid Tactical Agent 架构

## 当前决策架构

当前默认架构是：

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> Learned Tactical Policy / tactical prior
  -> HighLevelDecision
  -> HybridCombatExecutor
  -> PlayerAction
  -> ArenaPlayer
```

低层控制不是深度学习模型。移动执行、解析式提前瞄准、LOS/撞墙检查、友伤检查、射击门控、能量保留、子弹威胁躲避和 stuck recovery 都是确定性算法。强化学习/行为克隆模型只控制更高层的战术选择。

旧架构是 `ModelAgentController -> protocol v1 -> raw PlayerAction`，模型直接输出 move/aim/shoot/dash/shield。旧 checkpoint、manifest、replay 和训练记录已归档到 `archive/legacy_raw_ai/`，只用于报告复现和离线对比，不再进入默认菜单、默认 catalog 或默认训练计划。

## 高层动作

`HighLevelDecision` protocol version 为 2，字段：

- `target_slot`: `NONE`, `ENEMY_0`, `ENEMY_1`, `ENEMY_2`, `BEST_VISIBLE_ENEMY`, `LOWEST_HEALTH_ENEMY`, `SCRIPTED_TARGET`
- `movement_mode`: `HOLD`, `CHASE`, `KEEP_RANGE`, `STRAFE_CLOCKWISE`, `STRAFE_COUNTERCLOCKWISE`, `RETREAT`, `SEEK_COVER`, `PEEK_FROM_COVER`, `SEEK_BEST_PICKUP`, `MOVE_TO_CENTER`, `EVADE_PROJECTILE`, `USE_SCRIPTED_MOVEMENT`
- `fire_mode`: `HOLD_FIRE`, `CONSERVATIVE`, `NORMAL`, `BURST`, `ALL_IN`, `USE_SCRIPTED_FIRE_MODE`
- `skill_mode`: `NONE`, `AUTO_DEFENSE`, `DASH_EVADE`, `DASH_ENGAGE`, `SHIELD`, `USE_SCRIPTED_SKILL`
- `confidence`, `decision_id`, `protocol_version`, optional `candidate_index`

`TacticalFeatureBuilder` 生成 action masks。不存在的敌人、不可用拾取物、冷却或能量不足的技能会被 mask。mask 后无合法动作时回退 Scripted Hard。

## 低层执行器

`BallisticAimSolver` 解：

```text
||p + v*t - s|| = c*t
```

并处理二次/一次退化、无正根、判别式小于零、极小速度、NaN、最大预测时间、子弹寿命、LOS、撞墙、友军路径和复活保护。输出预测瞄准点、飞行时间、瞄准误差和命中概率。

`FireControl` 决定是否真正射击。它检查冷却、能量、动态保留能量、命中概率、瞄准误差、LOS、墙体、友伤、目标有效性、burst 状态和防御优先级。`ALL_IN` 只有击杀窗口才允许。

`ProjectileThreatAnalyzer` 计算敌方子弹 closest approach、预计命中、剩余生命周期和威胁等级，生成左/右切向、后撤、dash/shield 等候选。高危时 safety layer 可以覆盖移动，并记录 `safety_override`。

`MovementExecutor` 将移动意图转换为 `move`，并带 hysteresis。`StuckRecovery` 使用位置历史、指令速度、实际位移、墙距、角落分数和当前模式区分战术贴墙与真卡死。

## Scripted Hard 用法

Scripted Hard 有三种角色：

- teacher：v2 replay 记录 `teacher_decision` 和最终 `PlayerAction`
- candidate：模型可选 `SCRIPTED_TARGET`、`USE_SCRIPTED_MOVEMENT`、`USE_SCRIPTED_FIRE_MODE`、`USE_SCRIPTED_SKILL`
- fallback：服务断开、超时、协议错误、NaN/Inf、低 confidence、动作塌缩、无目标开火、卡墙等情况回退

## 推理协议

请求：

```json
{
  "cmd": "act_tactical",
  "protocol": 2,
  "request_id": 1,
  "player_id": 1,
  "model_id": "hybrid_tactical_v1",
  "observation": {},
  "tactical_features": [],
  "action_masks": {}
}
```

响应：

```json
{
  "type": "tactical_decision",
  "protocol": 2,
  "request_id": 1,
  "model_id": "hybrid_tactical_v1",
  "decision": {
    "target_slot": 4,
    "movement_mode": 2,
    "fire_mode": 2,
    "skill_mode": 1,
    "confidence": 0.62,
    "protocol_version": 2
  }
}
```

v1 `cmd=act` 仅作为归档 raw-action checkpoint 的兼容协议保留。

## 运行命令

启动 v2 服务：

```bash
python -m training.inference.serve_agent --host 127.0.0.1 --port 8766
```

Hybrid headless smoke：

```bash
godot --headless --path . -- --training --matches=1 --agents=2 --seed=7102 --seconds=3 --map=dungeon --agent-controller=hybrid --agent-model-id=hybrid_tactical_v1
```

采集 v2 teacher replay：

```bash
godot --headless --path . -- --training --matches=1 --agents=2 --seed=7500 --seconds=2 --map=dungeon --agent-controller=hybrid --agent-model-id=hybrid_tactical_v1 --record-replay
```

可视化 smoke：

```bash
godot --path . -- --training --visual --matches=1 --agents=2 --seed=7600 --seconds=5 --map=dungeon --agent-controller=hybrid --agent-model-id=hybrid_tactical_v1
```

## 游戏内选择

1. 启动推理服务。
2. 主菜单 `Agent Type` 选择 `Hybrid Tactical Agent`。
3. `Agent Model` 选择 `Hybrid Tactical v1` 或后续训练出的 tactical checkpoint。
4. 旧 v1 checkpoint 需要显式从 `archive/legacy_raw_ai/` 取出并走兼容入口，不作为日常菜单选项。
