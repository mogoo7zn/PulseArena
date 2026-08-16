# Pulse Arena Agent 训练策略

## 当前主线

后续训练采用 Hybrid Tactical 架构：

```text
AgentObservation
  -> TacticalFeatureBuilder
  -> 高层战术模型
  -> HighLevelDecision
  -> 确定性低层执行器
  -> PlayerAction
```

模型不再直接输出 `move_x/move_y/aim_x/aim_y/shoot/dash/shield`。低层移动、提前量瞄准、开火门控、能量保留、躲弹、防卡墙、LOS/撞墙检查和安全回退都由基础算法处理。模型只学习目标选择、移动意图、开火策略、技能策略和 confidence。

历史全模型 raw-action PPO/BC 结果已经归档到 `archive/legacy_raw_ai/`，只用于报告复现和横向对比，不再作为默认训练入口、模型目录或菜单选项。

## 训练目标

训练一个在四张地图中都稳定强于脚本 hard，并具备进入人类评测资格的战术 agent。目标不是单纯追人开火，而是能在生命、能量、弹药、掩体、地图风险、迷雾、传送、道具和中立实体之间做稳定决策。

四张地图分别达标：

- `dungeon`：利用墙体和拐角，避开笼锁陷阱。
- `sky_city`：处理移动障碍、挤压风险和虚空区。
- `jungle`：避开沼泽减速伤害，处理伪装信息差和中立蛇。
- `mist_world`：在迷雾下使用记忆推断敌人位置，并合理利用传送门。

## 当前可用基础

- Godot headless 对局入口：`scripts/rl/training_runner.gd`。
- 环境桥接接口：`scripts/rl/environment_bridge.gd`。
- 观测结构：`scripts/rl/agent_observation.gd`。
- 观测构建：`scripts/rl/observation_builder.gd`。
- 奖励计算：`scripts/rl/reward_calculator.gd`。
- 脚本 AI 基线：`scripts/controllers/scripted_agent_controller.gd`。
- Hybrid 控制器：`scripts/controllers/hybrid_agent_controller.gd`。
- 低层执行器：`scripts/agents/`。
- v2 推理服务：`training/inference/serve_agent.py`。
- tactical BC 训练器：`training/rl/tactical_bc_trainer.py`。
- 默认模型目录：`training/models/model_catalog.json`，当前只保留 `hybrid_tactical_v1`。

## 推荐训练路线

第一阶段使用 Scripted Hard teacher 采集 `hybrid_replay_v2`，对 `TacticalPolicyNet` 做 behavior cloning warm start。这样模型先学会高层战术选择，低层执行稳定性由确定性算法保证。

第二阶段做 tactical-head PPO/MAPPO。actor 仍只输出 `HighLevelDecision`，critic 可在训练时使用合法 centralized training state，但部署 actor 不能读取隐藏敌人的真实私有状态。

第三阶段进入 league self-play 和分地图 promotion gate。新 checkpoint 只有在 fallback 率、无目标开火、墙后开火、卡墙恢复、单位能量伤害、空枪率、环境死亡率和对 scripted hard 胜率都达标后，才进入模型目录。

## 默认入口

本地验证：

```bash
python training/pipeline/train_pipeline.py --profile local_constrained --phase validate
python training/pipeline/train_pipeline.py --profile local_constrained --phase collect
python training/pipeline/train_pipeline.py --profile local_constrained --phase bc
```

服务器计划：

```bash
python training/pipeline/train_pipeline.py --profile full_distributed_league --phase validate
python training/pipeline/train_pipeline.py --profile full_distributed_league --phase collect
python training/pipeline/train_pipeline.py --profile full_distributed_league --phase bc
```

默认 plan：

- `training/configs/training_plans/hybrid_tactical_local.json`
- `training/configs/training_plans/hybrid_tactical_full.json`

## 观测和特征路线

当前 tactical feature schema 为 v2，维度为 142。后续扩展优先级：

1. 最近 K 个道具：类型、相对位置、剩余时间、安全可达性。
2. 地图危险实体：陷阱、虚空、沼泽、蛇、传送门、移动障碍、迷雾密度。
3. 掩体战术特征：与敌人的 line-of-sight、敌人到自己的 line-of-sight、最近掩体方向。
4. 局部 egocentric grid：墙、危险区、道具、敌人、子弹、迷雾。
5. 严格部分可观测：迷雾内不可见敌人不能泄漏私有状态。

## 奖励和评测

主奖励保持稀疏且稳定：

- 胜利奖励。
- 击杀奖励。
- 死亡惩罚。
- 有效伤害奖励。
- 受到伤害惩罚。

辅助奖励只用于课程学习，权重必须低于终局目标：

- 环境伤害和环境死亡惩罚。
- 空枪、低能量无效开火惩罚。
- 成功利用掩体降低受击风险的小奖励。
- 道具收益按局势估值。
- 危险区连续惩罚。

每个 checkpoint 必须分地图报告：

- 胜率：对 scripted easy/normal/hard、历史模型和人类。
- Elo 或 TrueSkill。
- 每点能量造成伤害。
- 空枪率。
- 环境死亡率。
- 道具拾取后收益。
- 掩体后受击率。
- 迷雾中被击杀率。
- 传送门使用后净收益。
- fallback 率和 safety override 率。

## 课程学习

1. `01_foundation_combat`：基础移动、瞄准、躲弹、短 burst。
2. `02_energy_discipline`：能量/弹药节制，控制空枪和低价值开火。
3. `03_cover_tactics`：掩体、断线、露头射击。
4. `04_dungeon_mechanics`：地牢笼锁陷阱。
5. `05_sky_city_mechanics`：天空城移动障碍、挤压和虚空。
6. `06_jungle_mechanics`：丛林沼泽、伪装和中立蛇。
7. `07_mist_world_mechanics`：迷雾记忆和传送门。
8. `08_mixed_ffa_league`：四图混合 FFA 自博弈联盟。
9. `09_team_2v2`：全 agent 2v2 team 训练。
10. `10_human_eval_tuning`：人类评测和轻微微调。

## 工程下一步

1. 用 Hybrid controller 重新采集高质量 `*.hybrid_v2.jsonl`。
2. 用 `tactical_bc_trainer.py` 训练第一个 `kind=tactical_policy` checkpoint。
3. 补 tactical PPO/MAPPO 更新脚本，保持 actor 输出高层动作。
4. 完善 promotion gate 和自动评测报告。
5. 只把通过 gate 的 checkpoint 写入 `training/models/model_catalog.json`。
