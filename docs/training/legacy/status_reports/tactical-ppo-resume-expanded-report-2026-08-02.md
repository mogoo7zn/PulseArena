# 高层策略 PPO 续训扩大结果报告

日期：2026-08-02（Asia/Shanghai）

## 当前接入状态

当前游戏服务默认模型仍是：

```text
model_id: hybrid_tactical_v1
kind: hybrid_tactical_prior
manifest: training/models/hybrid_tactical_v1_agent.json
checkpoint: 空
```

已接入 catalog、但未晋级默认模型的训练候选：

```text
model_id: hybrid_tactical_v2_ppo_expanded_candidate_20260802
manifest: training/models/hybrid_tactical_v2_ppo_expanded_candidate_20260802_agent.json
checkpoint: training/checkpoints/hybrid/hybrid_tactical_v2_ppo_expanded_candidate_20260802.pt

model_id: hybrid_tactical_v2_ppo_resume_candidate_20260802
manifest: training/models/hybrid_tactical_v2_ppo_resume_candidate_20260802_agent.json
checkpoint: training/checkpoints/hybrid/hybrid_tactical_v2_ppo_resume_candidate_20260802.pt
```

TCP service smoke 已验证：显式请求 `hybrid_tactical_v2_ppo_resume_candidate_20260802` 时，`serve_agent` 返回 protocol-v2 `tactical_decision`。默认 `default_model_id` 仍为 `hybrid_tactical_v1`，因为真实 fixed-seed evaluator 尚未完成，不能自动 promotion。

## 本轮修复

- `training/inference/model_runtime.py`：支持 `kind=tactical_actor_critic`，可加载 PPO `TacticalActorCritic` checkpoint 并输出 `act_tactical`。
- `training/import_trained_model.py`：新增 `--kind tactical_actor_critic`，导入 manifest/catalog 时保留真实模型类型。
- `training/inference/diagnose_policy.py`：诊断分支识别 `tactical_actor_critic`。
- `training/rl/tactical_online_trainer.py`：新增 `resume_checkpoint`，可以从 PPO `model_state` 继续训练，而不是每次重新从 BC checkpoint warm start。
- `training/train_pipeline.py`：新增 `--resume-checkpoint`，multi-GPU worker 可分别恢复自己的上一轮 PPO best checkpoint。

## 本轮续训扩大

新增配置：

```text
training/configs/multi_gpu/tactical_8gpu_ppo_resume_expanded_262144.json
```

执行命令：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_ppo_resume_expanded_262144.json \
  --execute
```

输出目录：

```text
training/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/
```

每个 `gpu0` 到 `gpu7` 均输出：

```text
best_tactical_ppo.pt
last_tactical_ppo.pt
metrics.jsonl
config.json
rollout_audit.json
```

汇总文件：

```text
training/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/aggregate_summary.json
```

## 指标结果

| 指标 | PPO resume expanded |
| --- | ---: |
| workers | 8 |
| env steps | 2,097,664 |
| PPO updates | 1,520 |
| episodes | 1,520 |
| transitions | 1,048,832 |
| tactical step calls | 524,416 |
| raw step calls | 0 |
| fallback count | 199 |
| fallback rate | 0.0190% |
| safety override count | 68,544 |
| safety override rate | 6.5353% |
| rollout reward sum | 7,701.64 |
| rollout reward mean | 5.0669 |
| reward min | 4.52 |
| reward max | 7.00 |
| last reward mean | 4.93 |
| last-100 mean avg | 5.0717 |
| damage dealt | 323.44 |
| damage taken | -219.76 |
| environment damage taken | -71.76 |
| kill | 30.0 |
| death | -20.0 |
| win | 7,600.0 |
| PPO entropy mean | 0.4295 |
| PPO approx KL mean | 0.0019 |
| PPO clip fraction mean | 0.0408 |
| PPO value loss mean | 0.2020 |

候选选择：

```text
best recent mean: gpu7
checkpoint: training/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/gpu7/best_tactical_ppo.pt
reward_last100_mean: 5.0980
reward_mean: 5.0718
reward_max: 6.56
fallback_rate: 0.0168%
safety_override_rate: 6.7769%
```

## 是否值得继续扩大

结论：**值得继续受控扩大，但不值得直接晋级默认游戏服务。**

支持继续的理由：

- 本轮是真 PPO checkpoint 续训，不再是重新从 BC checkpoint 启动；
- `raw_step_calls=0`，协议隔离保持正确；
- fallback rate 仍极低，为 `0.0190%`；
- `damage_dealt` 从上一轮 expanded 的 `88.14` 增至 `323.44`；
- PPO 更新稳定，`approx_kl=0.0019`、`clip_fraction=0.0408`，没有更新爆炸；
- 所有 8 个 worker 均 `returncode=0`，结束后 8 张 GPU 显存为 `0MiB`，端口 `8766/8870-8877` 无残留监听。

不能直接晋级的理由：

- rollout reward 均值从上一轮 `5.0800` 到本轮 `5.0669`，没有持续上移；
- `win=7600.0` 仍是最大 reward 来源，dense combat reward 仍不足以独立证明策略更强；
- safety override rate 仍约 `6.5%`，需要拆解是否来自合理避弹、射击门控或策略保守；
- 本轮仍是 8 个独立 PPO worker，不是共享 learner、DDP 或 MAPPO；
- fixed-seed paired-match evaluator 尚未完成，缺少四图、1v1、FFA、2v2、空枪率、环境死亡率和人工观感评估。

## 开火保守评析

`TACTICAL_FIRE_MODES` 映射为：

```text
0 HOLD_FIRE
1 CONSERVATIVE
2 NORMAL
3 BURST
4 ALL_IN
5 USE_SCRIPTED_FIRE_MODE
```

对零特征 smoke 请求，两个 PPO 候选均返回 `fire_mode=1`，即 `CONSERVATIVE`。这说明“开火保守”的感受有现实依据；同时，真实局面还会经过 Godot deterministic executor、fire gate 和 safety override。

已新增真实 Godot + `serve_agent` 服务链路 self-play evaluator，并执行 8 个 dev seed 的短局 smoke：

```text
output: training/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_service_dev8/
matches: 8
samples: 182 per match
service_backed_match: 1.0
paired_baseline_match: 0.0
result: fail（缺 paired baseline win/top1/human metrics，符合预期）
```

聚合 fire 行为：

| 指标 | 数值 |
| --- | ---: |
| HOLD_FIRE | 17.31% |
| CONSERVATIVE | 32.21% |
| NORMAL | 44.09% |
| BURST | 5.70% |
| ALL_IN | 0.00% |
| USE_SCRIPTED_FIRE_MODE | 0.69% |
| fire blocked rate | 71.57% |
| fallback rate | 0.69% |
| safety override rate | 7.21% |
| empty fire rate | 0.00% |
| environment death rate | 0.00% |

主要 fire block reason：

| reason | rate |
| --- | ---: |
| no_line_of_sight | 29.33% |
| hold_fire | 17.38% |
| reserved_energy | 8.59% |
| weapon_cooldown | 5.63% |
| low_hit_probability | 5.36% |
| intercept_after_lifetime | 3.43% |
| aim_error | 1.24% |
| defense_priority | 0.55% |

结论：真实服务链路中模型不是只会 `CONSERVATIVE`；`NORMAL+BURST` 合计约 `49.79%`。但 `fire_blocked_rate=71.57%` 很高，最大原因是 `no_line_of_sight=29.33%`，其次是 `hold_fire=17.38%` 和 `reserved_energy=8.59%`。因此“保守/不开火”的主要体感更可能来自 executor 的视线、能量保留和门控条件，而不只是 policy head 选择。下一步应实现 candidate-vs-scripted paired evaluator，并针对 LOS/能量保留做定向 ablation。

## 验证记录

已执行并通过：

```bash
PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer.TacticalOnlineTrainerTests.test_runner_resumes_ppo_checkpoint_before_bc_warm_start -v
MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline.TrainPipelineTests.test_tactical_ppo_dry_run_includes_resume_checkpoint_override -v
PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer tests.unit.test_train_pipeline -v
PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_evaluate_tactical_candidate -v
MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m py_compile training/inference/model_runtime.py training/import_trained_model.py training/inference/diagnose_policy.py training/rl/tactical_ppo.py training/rl/tactical_online_trainer.py training/train_pipeline.py training/multi_gpu_orchestrator.py
git diff --check
```

TCP service smoke：

```text
request model_id: hybrid_tactical_v2_ppo_resume_candidate_20260802
response type: tactical_decision
protocol: 2
fire_mode: 1
confidence: 0.2032
```
