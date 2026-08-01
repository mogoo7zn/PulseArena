# 本地训练运行记录

日期：2026-06-27

## 目标

本次运行的目标不是直接得到超人 agent，而是把本地可执行训练链路跑通：

- Godot headless 对局采样。
- replay JSONL 记录。
- 本地计算卡 warm-start 训练。
- SwanLab offline 监控。
- CSV/PNG/checkpoint 输出。

## 本地资源结论

- 可用计算设备：1 张本地 CUDA 计算卡。
- 显存级别：约 8GB。
- 当前最值得跑的本地任务：短程采样、观测/奖励调试、行为克隆 warm-start、小模型 PPO/MAPPO 冒烟。
- 不建议只靠本地资源完成最终四地图超人自博弈训练；最终策略仍应使用完整多卡配置训练。

本地 profile 已按“显存省用、内存换显存”的方向配置：

- rollout storage 放在 CPU/pinned memory。
- optimizer state 允许 CPU offload。
- 使用 mixed precision。
- 使用较小 GRU/MLP 隐层。
- 关闭本地版 grid CNN。
- 用 gradient accumulation 换显存。

这些优化能让本地训练跑起来，但不能把模型激活、环境采样和自博弈吞吐成本完全消掉，所以训练速度会明显低于完整训练 profile。

## 已执行命令

生成本地 replay：

```powershell
python -B training\run_stage.py --profile local_constrained --stage 01_foundation_combat --matches 4 --seconds 30 --record-replay --execute
```

本地 warm-start 训练：

```powershell
python training\behavior_clone.py --epochs 20 --batch-size 512 --swanlab-mode offline --run-name bc_local_constrained
```

查看本地 profile 预算：

```powershell
python training\estimate_resources.py --profile local_constrained
```

## 本次数据规模

- replay 文件：4 个。
- 每场：30 秒。
- 总 agent timestep 样本：14416。
- replay 输出目录：`training/replays/`。

本次采样是顺序 headless 采样，4 场 30 秒对局总耗时约 2 分钟出头。这个速度足够本地调试训练链路，但正式 RL 需要并行 worker。

## 本次训练结果

- 训练设备：CUDA。
- epoch：20。
- batch size：512。
- 训练耗时：约 9 秒。
- best validation loss：0.6156。
- validation loss：从 1.3101 降到 0.6156。
- validation move loss：从 0.3654 降到 0.0319。
- validation aim loss：从 0.3345 降到 0.0233。

输出文件：

- 曲线 PNG：`training/runs/behavior_clone/metrics.png`
- 曲线 CSV：`training/runs/behavior_clone/metrics.csv`
- best checkpoint：`training/runs/behavior_clone/best_policy.pt`
- last checkpoint：`training/runs/behavior_clone/last_policy.pt`

SwanLab offline run：

```powershell
swanlab sync D:\Workspace\agent\PulseArena\training\runs\behavior_clone\swanlab\run-20260627_115316-h47g71pa
```

## 曲线解读

loss 曲线下降明显，说明 observation/action pipeline、replay 读取、模型前向反向、checkpoint 和日志链路都是可用的。

按钮类 accuracy 基本持平，原因是本次数据来自短程 scripted 行为，样本分布比较单一，按钮动作存在类别不平衡。这个结果不能代表 agent 已经学会高水平策略，只说明本地 warm-start 能拟合一部分移动和瞄准行为。

## 时间预估

按本次顺序采样结果估算：

- 本地短程 warm-start：几分钟内可以得到 replay、曲线和 checkpoint。
- 本地 100 场、每场 30 秒的 replay 采样：约 50 到 70 分钟，训练本身通常是分钟级。
- 本地 profile 的第 1 阶段 RL 目标为 3M env steps。如果只用当前顺序采样吞吐，约 15 到 18 小时；接入并行 worker 后，预计可降到数小时级，具体取决于 Godot 多进程吞吐。
- 本地 profile 全部阶段目标为 58M env steps。它适合持续调试和小规模能力提升，不适合作为最终超人策略的唯一训练来源。
- 完整训练 profile 的基础 curriculum 为 400M env steps，更适合最终自博弈联盟、四地图泛化、人类评测前 checkpoint。

## 下一步

1. 用更多 scripted/human replay 做 warm-start，覆盖障碍、陷阱、负增益区、迷雾、传送、虚空和增益技能。
2. 接入并行 Godot worker，先测 1/2/4/8/12 worker 的 env steps/sec。
3. 在本地 profile 上跑第 1 到第 3 阶段小模型 PPO/MAPPO，重点验证奖励和观察。
4. 切到完整训练 profile 做自博弈 league、archive opponent、跨四地图评测。

## 追加运行：本地完整可执行流程

日期：2026-06-27

本次执行的是当时代码能完整跑通的本地流程：`local_constrained` 全阶段 headless replay 采样，加本地计算卡 warm-start 训练。后续版本已经补上单 worker Godot step IPC 和短程 PPO，见下一节。

采样命令：

```powershell
python -B training\run_stage.py --profile local_constrained --stage all --record-replay --execute
```

训练命令：

```powershell
python training\behavior_clone.py --epochs 80 --batch-size 1024 --swanlab-mode local --run-name bc_local_complete_all_stages --output-dir training\runs\behavior_clone_local_complete
```

SwanLab dashboard：

```text
http://127.0.0.1:5092
```

本次结果：

- 全阶段新增 replay：26 个。
- 当前 replay 总数：30 个。
- 当前 replay 总大小：约 1.78GB。
- 当前训练样本：270020。
- 全阶段采样耗时：约 21 分钟。
- 训练 wall time：约 8 到 9 分钟。
- 训练循环耗时：453.15 秒。
- 平均 epoch 时间：5.66 秒。
- epoch：80。
- first validation loss：0.8448。
- best validation loss：0.6286。
- last validation loss：0.6301。

输出文件：

- 曲线 PNG：`training/runs/behavior_clone_local_complete/metrics.png`
- 曲线 CSV：`training/runs/behavior_clone_local_complete/metrics.csv`
- best checkpoint：`training/runs/behavior_clone_local_complete/best_policy.pt`
- last checkpoint：`training/runs/behavior_clone_local_complete/last_policy.pt`
- SwanLab local logs：`training/runs/behavior_clone_local_complete/swanlab/`

同规模本地复跑预估：

- 全阶段采样：20 到 25 分钟。
- 80 epoch warm-start：8 到 12 分钟。
- 合计：约 30 到 40 分钟。

当前瓶颈：

- replay 是 JSONL，解析 1GB 以上数据时明显慢于训练本身。
- staged runner 仍然顺序启动 Godot job，尚未并行采样。
- button accuracy 变化小，说明 scripted 数据按钮类别不平衡；这不能代表强博弈策略已经学成。

## 追加运行：本地完整链路含在线 PPO

日期：2026-06-27

本次执行的是当前本地可跑完整流程：全阶段 headless replay 采样、80 epoch 行为克隆 warm-start、单 worker Godot step-IPC PPO。它验证的是训练链路完整性和本地可运行性，不代表最终四地图超人 league 已经完成。

执行命令：

```powershell
python training\train_pipeline.py --profile local_constrained --plan local_complete --phase all --execute --swanlab-mode local
```

由于第一次 BC 阶段遇到 Windows 控制台编码问题，已修复为 UTF-8 后从 BC 阶段续跑，并继续执行 PPO：

```powershell
python training\train_pipeline.py --profile local_constrained --plan local_complete --phase bc --execute --swanlab-mode local
python training\train_pipeline.py --profile local_constrained --plan local_complete --phase ppo --execute --swanlab-mode local
```

SwanLab dashboard：

```text
BC 曲线：http://127.0.0.1:5092
PPO 曲线：http://127.0.0.1:5093
```

本次结果：

- 当前 replay 总数：56 个。
- 当前 replay 总大小：约 3.48GB。
- 本次新增全阶段 replay：26 个。
- 本次新增采样时间窗口：14:08 到 14:29，约 21 分钟。
- BC 训练样本：525624。
- BC epoch：80。
- BC 训练耗时：854.33 秒，约 14 分 14 秒。
- BC best validation loss：0.6172，第 80 epoch。
- BC last shoot/dash/shield accuracy：0.8352 / 0.6207 / 0.6510。
- PPO env steps：2048。
- PPO updates：4。
- PPO 训练耗时：18.14 秒。
- PPO best rollout reward：5.0。

输出文件：

- BC 曲线 PNG：`training/runs/local_complete_bc/metrics.png`
- BC 曲线 CSV：`training/runs/local_complete_bc/metrics.csv`
- BC best checkpoint：`training/runs/local_complete_bc/best_policy.pt`
- BC last checkpoint：`training/runs/local_complete_bc/last_policy.pt`
- PPO best checkpoint：`training/runs/local_online_ppo/best_online_policy.pt`
- PPO last checkpoint：`training/runs/local_online_ppo/last_online_policy.pt`
- BC SwanLab local logs：`training/runs/local_complete_bc/swanlab/`
- PPO SwanLab local logs：`training/runs/local_online_ppo/swanlab/`

同配置本地干净复跑预估：

- 全阶段采样：约 21 到 25 分钟。
- 80 epoch BC warm-start：约 14 到 16 分钟。
- 短程 PPO：约 1 分钟以内。
- 总计：约 36 到 42 分钟。

本次从采样开始到 PPO checkpoint 落盘的实际 wall time 约 41 分钟，其中包含一次 SwanLab 编码问题修复和阶段续跑；修复后同配置复跑预计更接近 36 到 40 分钟。
