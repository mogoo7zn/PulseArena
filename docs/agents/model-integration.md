# 模型智能体接入说明

## 当前默认入口

当前 active 模型目录只保留 Hybrid Tactical v2：

```text
model_id: hybrid_tactical_v1
manifest: training/models/hybrid_tactical_v1_agent.json
catalog: training/models/model_catalog.json
protocol: 2
kind: hybrid_tactical_prior
```

模型只输出高层战术决策 `HighLevelDecision`。Godot 侧确定性执行器负责弹道提前量、开火门控、躲弹、能量保留、移动执行和卡墙恢复。

## 推理服务

启动默认服务：

```bash
python -m training.inference.serve_agent --host 127.0.0.1 --port 8766
```

查看当前加载内容：

```bash
python -m training.inference.serve_agent --print-info
```

Hybrid 请求使用 `act_tactical`：

```json
{"cmd":"act_tactical","protocol":2,"request_id":1,"model_id":"hybrid_tactical_v1","tactical_features":[],"action_masks":{}}
```

响应：

```json
{"type":"tactical_decision","protocol":2,"request_id":1,"model_id":"hybrid_tactical_v1","decision":{"target_slot":4,"movement_mode":2,"fire_mode":2,"skill_mode":1,"confidence":0.62,"protocol_version":2}}
```

## 游戏内使用

主菜单只暴露：

- `Scripted Agent`
- `Hybrid Tactical Agent`

旧 raw-action 模型不再作为普通菜单选项。需要复现实验时，显式指定 archive 里的 manifest 启动服务即可。

## 旧结果归档

旧 raw-action PPO/BC 结果已经移动到：

```text
archive/legacy_raw_ai/
```

关键文件：

- `archive/legacy_raw_ai/checkpoints/ppo_10m.pt`
- `archive/legacy_raw_ai/checkpoints/ppo_20m.pt`
- `archive/legacy_raw_ai/checkpoints/ppo_400m.pt`
- `archive/legacy_raw_ai/runs/bc_local/`
- `archive/legacy_raw_ai/runs/ppo_local/`
- `archive/legacy_raw_ai/manifests/*.json`
- `archive/legacy_raw_ai/replays/raw_20260627/`

这些结果只用于报告、对照和回归分析，不参与后续默认训练。
