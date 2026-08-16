# Hybrid Tactical Agent 服务器训练交接

## Schema

Observation schema version: `2`

基础观测仍来自 `AgentObservation`，包含 self、other_players、projectiles、map。Hybrid actor 不读取 arena 私有状态，不读取迷雾中不可见敌人的真实内部资源。当前 `TacticalFeatureBuilder` 仅使用 `AgentObservation` 中已提供的槽位。

Tactical feature schema version: `2`

- feature dim: `142`
- 入口：`training.encoding.TACTICAL_FEATURE_DIM`
- Godot 入口：`scripts/agents/tactical_feature_builder.gd`
- Python 入口：`training/rl/encoding.py`

## Tactical Action Schema

Protocol: `2`

Heads:

- target slot: 7 类
- movement mode: 12 类
- fire mode: 6 类
- skill mode: 6 类
- confidence: `[0, 1]`

Python 常量：

- `TACTICAL_TARGETS`
- `TACTICAL_MOVEMENTS`
- `TACTICAL_FIRE_MODES`
- `TACTICAL_SKILL_MODES`

Godot 常量：

- `HighLevelDecision.TargetSlot`
- `HighLevelDecision.MovementMode`
- `HighLevelDecision.FireMode`
- `HighLevelDecision.SkillMode`

## Action Masks

Mask keys:

- `target_slot`
- `movement_mode`
- `fire_mode`
- `skill_mode`

规则：

- 不存在/无效/队友/死亡敌人不可选。
- 无敌或被墙阻挡不直接从 target mask 移除，但会由低层 fire gate 阻止射击。
- 无拾取物时 `SEEK_BEST_PICKUP=false`。
- 无高危子弹时 `EVADE_PROJECTILE=false`。
- dash/shield 冷却或能量不足时对应技能 false。
- fire mode 至少保留 `HOLD_FIRE` 和 `USE_SCRIPTED_FIRE_MODE`。

## Replay Schema

Replay schema: `hybrid_replay_v2`

文件后缀：`*.hybrid_v2.jsonl`

每行字段：

- `episode_id`
- `match_id`
- `player_id`
- `map_id`
- `mode_id`
- `timestamp`
- `observation_schema_version`
- `observation`
- `tactical_features`
- `action_masks`
- `teacher_decision`
- `teacher_label_version`
- `label_source`
- `label_reason`
- `label_weight`
- `label_confidence`
- `model_decision`
- `executed_decision`
- `final_player_action`
- `safety_override`
- `fallback_used`
- `reward_components`
- `outcome`
- `diagnostic_metrics`

旧 raw replay 不应作为 tactical trainer 默认输入。Python raw loader 已跳过 `hybrid_replay_v2` 行；tactical loader 使用 `load_hybrid_replay_arrays()`。

`teacher_decision` 由 `scripts/agents/tactical_teacher.gd` 生成显式高层标签，不再固定记录 `USE_SCRIPTED_*`。`label_weight` 和 `label_confidence` 会被 mask-aware BC trainer 使用；旧 replay 中纯脚本委托标签会被自动降权。

## Checkpoint Schema

当前 baseline manifest:

```text
training/models/hybrid_tactical_v1_agent.json
kind=hybrid_tactical_prior
protocol=2
input_dim=142
```

服务器训练后的 tactical checkpoint manifest 建议：

```json
{
  "schema_version": 2,
  "model_id": "hybrid_tactical_<run_id>",
  "kind": "tactical_policy",
  "checkpoint": "training/artifacts/checkpoints/hybrid/<run_id>.pt",
  "input_dim": 142,
  "hidden": 192,
  "protocol": 2,
  "observation_schema_version": 2,
  "tactical_action_schema_version": 2
}
```

PyTorch model: `training.models.TacticalPolicyNet`

## 推理协议

Server command:

```bash
python -m training.serve_agent --host 127.0.0.1 --port 8766
```

Request command: `act_tactical`

Response type: `tactical_decision`

v1 `act` is retained only as a compatibility path for archived raw-action checkpoints under `archive/legacy_raw_ai/`.

## 本地测试结果

测试日期：2026-07-07

已通过：

- `python tests/smoke/static_project_check.py`
- `python -m compileall training`
- Godot unit tests via `tests/run_tests.gd`
- Hybrid fallback headless 1v1 smoke, service closed
- Hybrid protocol v2 headless 1v1 smoke, service running
- Four-map 4-agent FFA headless smoke
- Four-map 2v2 headless smoke
- 4-agent pressure smoke on jungle
- v2 replay collection and `load_hybrid_replay_arrays()` smoke
- `diagnose_policy` tactical summary for `hybrid_tactical_v1`
- Visual local match smoke with `--visual`; service closed, Scripted Hard fallback path verified

Linux 验证请使用 `make test`；它会将无头匹配日志写入
`test-results/headless-smoke.log`。

## 尚未完成项

- 没有进行正式大步数训练。
- `hybrid_tactical_v1` 是 tactical prior，不是最终学习策略。
- 需要服务器训练 `kind=tactical_policy` checkpoint。
- 当前 tactical feature 中地图机制实体保留了字段位置，但复杂地图机制的精细实体编码仍可继续扩展。
- 需要继续补正式评测报告：胜率、命中率、空枪率、单位能量伤害、墙边停留率、卡死次数和环境死亡率。

## 服务器训练入口

采集 teacher replay：

```bash
godot --headless --path . -- --training --matches=100 --agents=4 --seed=9000 --seconds=20 --map=all --mode=ffa --agent-controller=hybrid --agent-model-id=hybrid_tactical_v1 --record-replay
```

读取 replay：

```python
from pathlib import Path
from training.core.encoding import load_hybrid_replay_arrays

arrays = load_hybrid_replay_arrays(Path("training/replays"), decision_key="teacher_decision")
```

训练建议：

1. 先用 `TacticalTeacher` 显式高层标签做 mask-aware BC warm start。
2. 再用专用 tactical PPO/MAPPO 训练 tactical heads，不复用 legacy raw-action PPO。
3. actor 只用 `tactical_features` 和 `action_masks`。
4. critic 可在服务器训练中引入合法 centralized training state，但部署 actor 不可读取隐藏敌人真实状态。
5. promotion gate 必须检查：fallback 率、no-target fire、wall-block fire、stuck recovery、hit probability、空枪率、单位能量伤害和 scripted-hard 胜率。
