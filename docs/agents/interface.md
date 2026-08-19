# Agent 接口

所有控制器实现统一的 `PlayerController` 接口：

```gdscript
func reset() -> void
func get_action(observation: AgentObservation, delta: float) -> PlayerAction
```

## 📦 数据结构

- **`PlayerAction`**：归一化的 move / aim 向量，加 shoot / dash / shield 三个布尔动作。
- **`AgentObservation`**：自身状态、其它玩家、距离最近的几发子弹、边界距离、16 条 map ray、mode id、map id。支持字典和扁平数组两种序列化方式，便于对接 Python 与回放管道。

## 🌉 EnvironmentBridge

训练侧桥接接口：

```text
reset_environment(config)
get_observations()
apply_actions(actions)
step()
get_rewards()
get_terminated()
get_truncated()
get_info()
```

---

## 🟢 当前激活协议：Protocol v2

Protocol v2 是 Hybrid Tactical Agent 的活跃接口：

```json
{"cmd":"act_tactical","protocol":2,"tactical_features":[],"action_masks":{}}
```

v2 响应是 `HighLevelDecision`，包含：

- `target_slot` —— 目标槽位（7 类）
- `movement_mode` —— 移动意图（12 类）
- `fire_mode` —— 开火策略（6 类）
- `skill_mode` —— 技能策略（6 类）
- `confidence` —— 决策置信度
- `decision_id` —— 决策序号
- `protocol_version` —— 协议版本

Godot 端在拿到 `HighLevelDecision` 后，由**确定性 Hybrid executor** 翻译成 `PlayerAction`。

## 📦 归档协议：Protocol v1

Protocol v1 的 raw-action 推理仅用于历史结果复现：

```json
{"cmd":"act","protocol":1,"observation":{},"flat_observation":[]}
```

旧 checkpoint、manifest、回放数据全部归档在 `archive/legacy_raw_ai/`，**不进入默认菜单与默认训练流水线**。
