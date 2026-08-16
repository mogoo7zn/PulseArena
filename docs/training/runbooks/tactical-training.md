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
  --output training/artifacts/runs/tactical_data_quality.json
```

审计失败时不要训练 RL。常见阻断包括：没有 replay、malformed row、教师标签不在 mask 内、任一 action head 无标签覆盖。

## BC warm start

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
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
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan hybrid_tactical_v2_ppo_pilot \
  --phase ppo \
  --execute
```

产物写入：

- `training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/best_tactical_ppo.pt`
- `training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/last_tactical_ppo.pt`
- `training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/metrics.jsonl`
- `training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/config.json`
- `training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/rollout_audit.json`

`rollout_audit.json` 必须显示 `raw_step_calls: 0`。如果不是 0，停止使用该 run。

## 8 卡并行 tactical PPO pilot

当前接入的是多 GPU **任务编排**：8 个 protocol-v2 tactical PPO worker 独立运行，每个 worker 独占一张 GPU、一个 Godot TCP 端口和一个输出目录。它不是 DDP，也不是单个 learner 的多卡同步更新。

先 dry-run 检查 GPU、端口和输出目录分配：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi
```

确认后执行：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/pipeline/train_pipeline.py \
  --profile full_distributed_league \
  --plan hybrid_tactical_v2_8gpu_parallel_pilot \
  --phase ppo-multi \
  --execute
```

产物写入：

- `training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu0/` 到 `gpu7/`
- `training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/logs/tactical_gpu0.log` 到 `tactical_gpu7.log`

每个 worker 的 `rollout_audit.json` 都必须满足 `raw_step_calls: 0`。任一任务失败时，编排器默认 fail-fast，停止后续任务并返回非 0。

## 8 卡 BC warm-start PPO 诊断

当前更值得继续的路线是从已审计的 tactical BC checkpoint 初始化 PPO，而不是随机初始化 PPO：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_bc_warmstart_diagnostic_8192.json
```

确认 dry-run 后执行：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_bc_warmstart_diagnostic_8192.json \
  --execute
```

产物写入：

- `training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192/gpu0/` 到 `gpu7/`
- `training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192/logs/bc_warmstart_gpu0.log` 到 `bc_warmstart_gpu7.log`

判断门槛：

- `raw_step_calls` 必须为 `0`；
- fallback rate 应保持 `<1%`；
- `damage_dealt`、`kill/death` 等交战分量必须继续提升；
- safety override rate 若升高，必须先拆解原因和局面分布；
- 通过固定 seed evaluator 前，不更新 `training/models/model_catalog.json`。

扩大到每卡约 65k env steps 的配置：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_bc_warmstart_expanded_65536.json \
  --execute
```

产物写入：

- `training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/gpu0/` 到 `gpu7/`
- `training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/logs/bc_warmstart_expanded_gpu0.log` 到 `bc_warmstart_expanded_gpu7.log`

注意：这仍是 8 个独立 PPO worker，不是完整 recurrent MAPPO league。完整 league 需要共享 learner、centralized critic、league sampling 和真实 fixed-seed evaluator。

## PPO checkpoint 续训扩大

从上一轮 expanded PPO checkpoint 继续训练，而不是重新从 BC checkpoint warm start：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_ppo_resume_expanded_262144.json \
  --execute
```

产物写入：

- `training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/gpu0/` 到 `gpu7/`
- `training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/aggregate_summary.json`
- `training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/logs/ppo_resume_expanded_gpu0.log` 到 `ppo_resume_expanded_gpu7.log`

导入非默认候选：

```bash
.conda/bin/python training/model_io/import_trained_model.py \
  --checkpoint training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/gpu7/best_tactical_ppo.pt \
  --model-id hybrid_tactical_v2_ppo_resume_candidate_20260802 \
  --label "Hybrid Tactical v2 PPO Resume Candidate" \
  --kind tactical_actor_critic \
  --run-id hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144_gpu7 \
  --hidden 192 \
  --input-dim 142 \
  --metrics-json training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/aggregate_summary.json \
  --description "Non-default PPO continuation candidate selected by best last-100 rollout mean. Requires fixed-seed evaluator before default promotion." \
  --update-catalog
```

不要加 `--promote-default`，除非固定 seed 评测、部署 smoke 和人工确认全部通过。

## 固定 seed 评测

评测矩阵位于 `training/configs/evaluation_matrix.json`。当前 `training/evaluation/evaluate_tactical_candidate.py` 已提供固定 seed 选择、gate 汇总、JSON 与中文 Markdown 报告输出，并支持 `--runner godot-service` 运行真实 Godot + `serve_agent` 服务链路的 self-play smoke。真实 candidate-vs-scripted paired-match runner 仍需接入后才能运行 promotion-grade 完整矩阵。

报告层单测：

```bash
.conda/bin/python -m unittest discover -s tests/unit -p 'test_evaluate_tactical_candidate.py' -v
```

服务链路 smoke：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
HOME="$PWD/.tools/godot-user" \
PYTHONPATH=. \
.conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
  --manifest training/models/hybrid_tactical_v2_ppo_resume_candidate_20260802_agent.json \
  --output-dir training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_service_smoke \
  --runner godot-service \
  --split dev \
  --max-jobs 1 \
  --seconds 8 \
  --ticks 8 \
  --port-start 18910 \
  --model-port-start 18920 \
  --device cpu \
  --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64
```

该 smoke 会输出 `service_backed_match=1.0`、fire mode 分布、`fire_blocked_rate`、fallback/safety rate、空枪率和环境死亡率。它不提供 `win_rate` / `top1_rate` / 人工评测指标，因此 promotion gates 应保持失败。

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
