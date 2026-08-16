# 完整联赛训练调整说明

## 结论

服务器上的完整训练模型需要重新训练。

当前迁移进项目的模型：

```text
model_id: full_league_8gpu_20260630
checkpoint: training/checkpoints/full/full_league_8gpu_agent.pt
manifest: training/models/full_league_8gpu_agent.json
```

接入链路已经验证过：Godot 菜单会把 `model_id` 发给 Python 推理服务，Python 能正确加载 checkpoint，观测维度为 297，动作能正常返回。问题不是“没接上”，而是该 checkpoint 的策略已经塌缩成近似常量动作。

真实 Godot 观测诊断结果：

```text
samples: 160
mean_move: [0.7066, 0.7076]
std_move: [0.00049, 0.00049]
move_direction_resultant: 0.9999998
shoot_rate: 1.0
collapsed: true
```

这解释了游戏里的表现：智能体一直向右下角移动，卡到角落后继续朝固定方向射击，缺少追敌、绕掩体、躲弹、技能决策。

当前游戏默认模型已经切回：

```text
model_id: local_complete_bc_20260627
checkpoint: training/runs/local_complete_bc/best_policy.pt
```

它不是最终强模型，但动作多样性正常，适合作为临时可玩模型。

## 是否可以继续训练旧 checkpoint

不建议直接从 `full_league_8gpu_20260630` 继续训练。

原因：

- 当前 actor 输出已经严重饱和，移动方向几乎恒定。
- 继续训练可能需要很长时间才能从坏局部策略里恢复。
- 该模型没有通过基础 promotion gate，不应作为后续 league archive 的强对手。

推荐做法：

- 保留 `full_league_8gpu_agent.pt` 作为失败样本和回归测试对象。
- 新训练从行为克隆 warm-start 或重新训练的 scripted-hard warm-start 初始化。
- 新 checkpoint 只有通过诊断和评测 gate 后，才能进入 `training/models/model_catalog.json` 的 `default_model_id`。

## 现有训练链路的主要问题

### 1. 缺少可靠 warm-start

完整 PPO/MAPPO 不应从随机 actor 直接跑完整 league。随机策略在稀疏击杀奖励下很容易学到“固定移动 + 高频射击”这种低质量局部策略。

需要先用以下数据做行为克隆：

- scripted-hard 对局 replay。
- 人类操作 replay。
- 旧 BC 模型与 scripted-hard 混合对局 replay。
- 覆盖四张地图、FFA、2v2、不同出生点和随机种子。

### 2. 观测归一化不一致

当前其他玩家和 projectile 的相对位置已经按 `balance.map_size` 归一化，但 self position 仍是像素坐标，例如 x 可到 2160、y 可到 1215。神经网络会更容易被绝对位置主导，出现靠角落或固定方向偏置。

训练前应统一观测尺度：

- `self.position.x / map_size.x`
- `self.position.y / map_size.y`
- `self.velocity / max_speed`
- score、时间、冷却、生命等保持有限范围。

注意：改观测格式后，所有旧 checkpoint 都不兼容，必须重训。

### 3. PPO return 太短视

当前本地 PPO 实现里，训练 batch 直接使用单步 reward：

```python
returns = rewards
advantages = rewards - old_values
```

这对 projectile game 不够。命中、击杀、躲避、走位都有延迟效果，必须改成 discounted return 或 GAE。

建议：

- `gamma = 0.995`
- `gae_lambda = 0.95`
- 按 player episode 切分轨迹。
- 终止状态 bootstrap value 为 0。
- 非终止状态 bootstrap 最后一帧 value。

### 4. Recurrent 训练与部署不一致

完整模型是 GRU actor-critic，但当前推理服务每次请求都是独立前向，等价于每次清空 hidden state。即使训练出了依赖记忆的策略，部署时也会损失行为质量。

需要调整：

- rollout 采样时为每个 worker/player 保存 GRU hidden。
- episode reset、死亡重生或 player 重置时清 hidden。
- 推理服务按 `model_id + connection + player_id` 保存 hidden。
- Godot match reset 时发送 reset/session 信息，或服务端在新连接时清空 hidden。

### 5. 奖励太稀疏

当前奖励核心是 damage、kill、death、win。对于从随机策略开始的 PPO，这不足以稳定学出战术。

建议增加密集奖励：

- 有效瞄准：准星方向接近最近可见敌人方向。
- 命中前压：敌人在射线/射程内时开火，且不是被墙挡住。
- 空射惩罚：没有敌人、被墙挡住或冷却/能量不足时持续射击扣分。
- 躲弹：近距离危险 projectile 的距离增加奖励，距离减少扣分。
- 角落惩罚：长期贴边或停留在地图角落扣分。
- 活动区奖励：离开出生点和角落，保持可交战距离。
- 有效 dash：dash 后远离 projectile 或拉开敌人火线奖励。
- 有效 shield：shield 吸收伤害或在危险 projectile 接近时开启奖励。
- 掩体使用：有敌方火线威胁时进入 cover 后奖励。

### 6. 缺少 promotion gate

不能只看 env steps 或训练是否跑完。每个 checkpoint 必须跑自动 gate。

最低 gate：

- `diagnose_policy` 的 `collapsed` 必须为 `false`。
- 移动方向集中度 `move_direction_resultant < 0.90`。
- 角落停留率低于阈值。
- 空射率低于阈值。
- 每分钟平均伤害高于 scripted-hard baseline。
- FFA scripted-hard top1/top2 率达标。
- 四张地图分别过关，不能只在 dungeon 过关。
- 2v2 不出现队友间距崩塌和无意义贴边。

## 推荐重训路线

### 阶段 0：修训练代码

服务器重训前先修以下代码，不要直接重跑旧配置：

1. `ObservationBuilder` 和 `training/rl/encoding.py` 对齐新的归一化观测。
2. `training/rl/online_trainer.py` 增加 BC 权重初始化。
3. `training/rl/online_trainer.py` 增加 GAE。
4. rollout storage 保存 sequence、done、hidden state。
5. `training/inference/model_runtime.py` 增加 recurrent hidden state 推理路径。
6. 增加 checkpoint gate，自动调用 `training.diagnose_policy`。

### 阶段 1：重新采集 warm-start replay

采集目标：

- 四张地图都要覆盖。
- FFA 2 agent、FFA 4 agent、2v2 都要覆盖。
- 至少 scripted-hard。
- 如果有人类 replay，混入 10% 到 30%。

建议输出：

```text
training/replays/full_warm_start/
```

### 阶段 2：行为克隆 warm-start

输出目录：

```text
training/runs/full_league_bc/
```

BC 训练目标：

- validation loss 稳定下降。
- 移动方向不要塌缩。
- shoot/dash/shield 不要恒真或恒假。
- 在真实 Godot 观测上通过 `diagnose_policy`。

### 阶段 3：短程 PPO 验证

先只跑小步数验证，不要直接上 400M：

```text
1M env steps: dungeon, FFA 2 agents
5M env steps: dungeon + sky_city, FFA 2 agents
10M env steps: all maps, FFA 4 agents
```

每个 checkpoint 都跑 gate。只要出现 movement collapse、shoot 恒真、角落率高，就停止并回滚。

### 阶段 4：完整 league

短程验证通过后再跑完整计划：

```text
training/checkpoints/full/
training/checkpoints/full/archive.json
training/runs/full_online_mappo/
```

league 对手池建议：

- 20% scripted-hard。
- 30% 当前策略。
- 30% archive checkpoint。
- 20% BC/warm-start 策略。

前期不要过早去掉 scripted-hard，否则 self-play 容易学到互相无效射击或角落策略。

## 服务器执行建议

服务器需要重新训练，但分两步：

1. 先同步训练代码修复。
2. 再重新采集 replay、BC warm-start、短程 PPO、完整 league。

不要只执行：

```powershell
python training/train_pipeline.py --profile full_distributed_league --plan full_league --phase all --execute
```

因为旧训练逻辑会再次有较高概率得到塌缩策略。

修复后推荐流程：

```powershell
python training/train_pipeline.py --profile full_distributed_league --plan full_league --phase validate
python training/train_pipeline.py --profile full_distributed_league --plan full_league --phase collect --execute
python training/train_pipeline.py --profile full_distributed_league --plan full_league --phase bc --execute
python -m training.diagnose_policy --model-id <bc_model_id> --fail-on-collapse
python training/train_pipeline.py --profile full_distributed_league --plan full_league --phase ppo --execute
python -m training.diagnose_policy --model-id <new_ppo_model_id> --fail-on-collapse
```

完整重训完成后，只有通过 gate 的模型才能写入：

```text
training/models/model_catalog.json
```

并设置为：

```json
"default_model_id": "<passed_model_id>"
```

## 当前项目内临时方案

在重新训练前，游戏内默认使用：

```text
local_complete_bc_20260627
```

完整训练模型：

```text
full_league_8gpu_20260630
```

仍保留在菜单里，便于对比和调试，但不应作为默认模型。

## 验收标准

新模型至少满足：

- 不再固定朝一个方向移动。
- 不会长期卡在角落。
- 能根据敌人相对位置调整 aim。
- 有 projectile 接近时能改变移动方向。
- dash/shield 有条件触发，而不是恒真或恒假。
- shoot 不应在无敌人、被墙挡住、无能量或冷却状态下长期恒真。
- scripted-hard baseline 上有稳定胜率提升。
- 四张地图行为都正常。

通过以上标准后，才可以认为服务器完整训练成功。
