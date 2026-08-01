# 服务器训练包运行说明

> 当前推荐使用 `training/server_agent/SERVER_AGENT_PROMPT_zh.md` 作为服务器端 coding agent 的唯一执行规范，并通过 `training/server_train_hybrid_tactical_v2.sh` 运行有界单卡 pilot。旧的“直接全阶段 collect + BC”流程会采集过量物理帧回放，不能作为默认入口。

## 打包

在本地工程根目录运行：

```bash
python training/package_server_bundle.py
```

输出位置：

```text
training/packages/
```

会生成：

- `pulsearena_hybrid_tactical_v2_training_<stamp>.tar.gz`
- `pulsearena_hybrid_tactical_v2_training_<stamp>.manifest.json`

压缩包包含 Godot 项目、训练代码、配置、文档和测试；不包含历史归档、回放、训练输出、本地 checkpoint、缓存目录。

## 上传后解压

在 Ubuntu 服务器：

```bash
tar -xzf pulsearena_hybrid_tactical_v2_training_<stamp>.tar.gz
cd pulsearena_hybrid_tactical_v2_training_<stamp>
```

## 环境准备

需要系统已有：

- Python 3.10+
- PyTorch
- NumPy
- Matplotlib
- Godot headless/console binary

设置 Godot 路径：

```bash
export GODOT_BIN=/path/to/godot
```

如果使用离线日志：

```bash
export SWANLAB_MODE=offline
```

## 运行完整 BC 训练链路

```bash
bash training/server_train_hybrid_tactical_v2.sh
```

等价分步命令：

```bash
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase validate
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase collect --execute
python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_bc --phase bc --execute --swanlab-mode offline
```

## 训练结果

默认输出：

```text
training/replays/
training/runs/hybrid_tactical_v2_bc_s01/
```

关键文件：

- `best_tactical_policy.pt`
- `last_tactical_policy.pt`
- `metrics.csv`
- `metrics.png`
- `swanlab/`

把 `best_tactical_policy.pt` 和关键 metrics 拷回本地 `training/incoming_models/` 后，用：

```bash
python training/import_trained_model.py \
  --checkpoint training/incoming_models/hybrid_tactical_v2_bc_s01.pt \
  --metrics-json training/incoming_models/hybrid_tactical_v2_bc_s01_metrics.json \
  --model-id hybrid_tactical_v2_bc_s01 \
  --run-id hybrid_tactical_v2_bc_s01 \
  --hidden 256 \
  --update-catalog
```

## 交给服务器 agent 的任务描述

可以直接让服务器 agent 执行：

```text
解压训练包，进入目录，设置 GODOT_BIN，运行 bash training/server_train_hybrid_tactical_v2.sh。
训练结束后，汇总 training/runs/hybrid_tactical_v2_bc_s01/ 下的 checkpoint、metrics.csv、metrics.png 和日志。
```
