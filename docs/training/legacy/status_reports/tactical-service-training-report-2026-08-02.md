# 高层策略服务接入与训练评析

日期：2026-08-02（Asia/Shanghai）

## 服务接入结论

当前训练结果**没有接入游戏服务**，也没有进入默认模型目录。

证据：

- `training/models/model_catalog.json` 的 `default_model_id` 仍是 `hybrid_tactical_v1`；
- catalog 里只有一个模型：`hybrid_tactical_v1`；
- `training/models/hybrid_tactical_v1_agent.json` 的 `kind` 是 `hybrid_tactical_prior`，`checkpoint` 为空；
- `python -m training.serve_agent --print-info` 返回 `model_id=hybrid_tactical_v1`、`kind=hybrid_tactical_prior`、`checkpoint=.`；
- 端口 `8766` 与训练端口 `8870-8877` 当前没有常驻服务监听；
- 本次训练没有修改 `training/models/model_catalog.json`，也没有执行 promotion。

因此，你在游戏里感受到的 agent 开火保守，主要来自当前活动服务仍是 `hybrid_tactical_v1` prior，加上 Hybrid executor 的确定性开火门控，而不是最新 PPO checkpoint 已经上线后的表现。

## 当前训练产物路径

已有 BC 候选：

```text
training/runs/hybrid_tactical_bc/best_tactical_policy.pt
training/runs/hybrid_tactical_bc/formal_tactical_policy_candidate.json
training/runs/hybrid_tactical_bc/metrics.csv
training/runs/hybrid_tactical_bc/metrics.png
```

随机初始化 PPO foundation 诊断：

```text
training/runs/hybrid_tactical_v2_8gpu_foundation_diagnostic_8192/
```

本轮新增 BC warm-start PPO 诊断：

```text
training/runs/hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192/
```

每个 `gpu0` 到 `gpu7` 目录都有：

```text
best_tactical_ppo.pt
last_tactical_ppo.pt
metrics.jsonl
config.json
rollout_audit.json
```

本轮训练计划和 8 卡编排配置：

```text
training/configs/training_plans/hybrid_tactical_v2_bc_warmstart_ppo_pilot.json
training/configs/multi_gpu/tactical_8gpu_bc_warmstart_diagnostic_8192.json
```

## 开火保守的原因判断

当前活动模型保守的直接原因：

1. 默认服务没有加载训练 checkpoint，仍在使用 `hybrid_tactical_prior`。
2. prior 的本地决策会大量使用 `SCRIPTED_TARGET` 和 `USE_SCRIPTED_FIRE_MODE`。
3. 执行层 `FireControl` 仍会因为 `hold_fire`、`no_target`、`no_line_of_sight`、`wall_blocked`、`weapon_cooldown`、`reserved_energy`、`defense_priority`、`low_hit_probability`、`aim_error` 等原因拒绝开火。
4. `HybridCombatExecutor` 还有安全层，在紧急弹幕威胁下会覆盖移动决策，`override_reason=emergency_projectile`。

随机初始化 PPO 的训练证据也支持这个判断：8 卡 foundation diagnostic 中 fallback 率为 `17.0078%`，fallback 原因全部是 `scripted_target`，且 `damage_dealt` 只有 `0.4`。

## 本轮修复与继续训练

修复点：

- `MaskedTacticalPPOTrainer.load_bc_checkpoint()` 兼容当前 tactical BC checkpoint 的 `fire_head` / `skill_head` 字段名；
- warm-start 现在加载 BC trunk/encoder 和四个 actor heads，形状不匹配时不会加载 trunk；
- `TacticalOnlineConfig` 新增 `bc_checkpoint`；
- `train_pipeline.py` 将训练计划中的 `tactical_ppo.bc_checkpoint` 传入 PPO；
- checkpoint、`config.json` 和训练结果都会记录 `bc_warm_start`。

已执行：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_bc_warmstart_diagnostic_8192.json \
  --execute
```

8 个 worker 全部 `returncode=0`。

## 指标对比

| 指标 | 随机 PPO foundation | BC warm-start PPO |
| --- | ---: | ---: |
| workers | 8 | 8 |
| env steps | 66,252 | 66,248 |
| updates | 96 | 96 |
| episodes | 48 | 48 |
| transitions | 33,126 | 33,124 |
| raw step calls | 0 | 0 |
| fallback count | 5,634 | 21 |
| fallback rate | 17.0078% | 0.0634% |
| safety override count | 403 | 2,432 |
| safety override rate | 1.2166% | 7.3421% |
| rollout reward sum | 238.28 | 243.52 |
| damage dealt | 0.4 | 10.8 |
| damage taken | -0.2 | -7.8 |
| kill | 0.0 | 3.0 |
| death | 0.0 | -2.0 |
| win | 240.0 | 240.0 |
| fallback reason | `scripted_target=5634` | `scripted_target=21` |
| PPO entropy mean | 7.0442 | 0.4958 |
| PPO approx KL mean | 0.0048 | 0.0027 |

## 是否值得扩大

结论：**值得继续扩大 BC warm-start 路线，但不值得直接接入游戏服务，也不值得直接跑完整 league 全量训练。**

值得继续的理由：

- fallback 从 `17.0078%` 降到 `0.0634%`，说明模型不再大量委托 `SCRIPTED_TARGET`；
- `damage_dealt` 从 `0.4` 提升到 `10.8`，并出现 `kill=3.0`，说明开火和命中相关行为有了真实训练信号；
- `raw_step_calls=0` 保持为 0，仍然走 protocol-v2 tactical 安全边界；
- 8 卡任务编排、日志、checkpoint、audit 全部产出正常。

暂时不能上线或全量的原因：

- `win=240.0` 仍是主要奖励来源，dense combat reward 还不够强；
- safety override 从 `1.2166%` 升到 `7.3421%`，说明模型更积极后触发了更多紧急弹幕安全覆盖；
- 8 卡仍是 8 个独立 checkpoint，不是共享 learner；
- 固定 seed Godot paired-match evaluator 真实对局 runner 还未接入，不能做 promotion gate；
- 未经过四图、1v1、FFA、2v2、空枪率、环境死亡率、人工观感等晋级评估。

## 下一步门槛

继续训练应满足：

- 保持 `raw_step_calls=0`；
- fallback rate 保持 `<1%`；
- safety override rate 需要从 `7.34%` 降到更合理区间，或至少拆出 override reason 和局面分布；
- `damage_dealt`、`kill/death` 继续提升，而不是只靠 `win`；
- 接入真实固定 seed evaluator 后，再选择候选 checkpoint；
- 通过 gate 前不更新 `training/models/model_catalog.json`。
