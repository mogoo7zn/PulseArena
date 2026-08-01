# 高层战术训练运行与晋级指南

## 预检

```bash
nvidia-smi
.conda/bin/python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.device_count())'
HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --disable-crash-handler --path . --script tests/run_tests.gd
```

要求：本机 CUDA 可见，Godot tactical protocol 单测通过。不要重启机器，不修改 NVIDIA driver。

## 数据审计

```bash
.conda/bin/python training/server_agent/tactical_data_quality.py \
  --replay-dir training/replays \
  --output training/runs/tactical_data_quality.json
```

审计失败时不要训练 RL。常见阻断包括：没有 replay、malformed row、教师标签不在 mask 内、任一 action head 无标签覆盖。

## BC warm start

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/train_pipeline.py \
  --profile local_constrained \
  --plan hybrid_tactical_local \
  --phase bc \
  --execute \
  --swanlab-mode offline
```

BC checkpoint 只作为 tactical PPO warm start 候选，不自动写入 `training/models/model_catalog.json`。

## Tactical PPO pilot

```bash
CUDA_VISIBLE_DEVICES=0 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
.conda/bin/python training/train_pipeline.py \
  --profile local_constrained \
  --plan hybrid_tactical_v2_ppo_pilot \
  --phase ppo \
  --execute
```

产物写入：

- `training/runs/hybrid_tactical_v2_ppo_pilot/best_tactical_ppo.pt`
- `training/runs/hybrid_tactical_v2_ppo_pilot/last_tactical_ppo.pt`
- `training/runs/hybrid_tactical_v2_ppo_pilot/metrics.jsonl`
- `training/runs/hybrid_tactical_v2_ppo_pilot/config.json`
- `training/runs/hybrid_tactical_v2_ppo_pilot/rollout_audit.json`

`rollout_audit.json` 必须显示 `raw_step_calls: 0`。如果不是 0，停止使用该 run。

## 固定 seed 评测

评测矩阵位于 `training/configs/evaluation_matrix.json`。当前 `training/evaluate_tactical_candidate.py` 已提供固定 seed 选择、gate 汇总、JSON 与中文 Markdown 报告输出；真实 Godot paired-match runner 仍需接入后才能运行完整矩阵。

报告层单测：

```bash
.conda/bin/python -m unittest discover -s tests/unit -p 'test_evaluate_tactical_candidate.py' -v
```

完整评测完成后应输出：

- `evaluation.json`
- `evaluation_report_zh.md`

报告器不会执行 catalog 晋级。

## 晋级规则

只有同时满足以下条件，才允许进入单独的人工 promotion 流程：

- 固定 holdout seed、四图、1v1、FFA、2v2 报告完整；
- Scripted Hard 1v1 四图胜率不低于 `0.72`；
- FFA top-1 不低于 `0.40`；
- holdout 环境死亡率不高于 `0.06`；
- 空枪率不高于 `0.10`；
- 人工评测每图胜率不低于 `0.55`；
- fallback、安全覆盖、延迟、卡死和 BC 回归无阻断；
- 部署 smoke 通过；
- 人工确认。

任何训练或评测命令不得直接修改 `training/models/model_catalog.json`。

## 故障诊断

- CUDA 在沙箱里不可见但 `nvidia-smi` 可见：用非沙箱权限运行 GPU 验证。
- Godot TCP smoke 报 socket permission：用非沙箱权限运行 loopback 测试。
- `rollout_reward` 长期为 0：先检查奖励分量是否在 tactical snapshot 中稳定返回，再检查 rollout 是否跨过 countdown 和有效交战窗口。
- `fallback_count` 偏高：检查模型响应、mask 修正和 Hybrid executor diagnostics，不把 fallback 计入模型能力。
- `raw_step_calls` 非 0：立即停止该 runner，说明 tactical/raw 隔离被破坏。

## 恢复运行

pilot runner 会覆盖同一 `output_dir` 内的 `best_tactical_ppo.pt`、`last_tactical_ppo.pt` 和 run 配置。需要保留历史证据时，复制 plan 并改 `output_dir`，不要覆盖已有报告。
