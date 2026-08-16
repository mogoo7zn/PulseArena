# 高层 Tactical RL 扩训判断报告

日期：2026-08-01（Asia/Shanghai）

## 结论

当前**不值得直接启动完整课程全量训练**。

可以扩大到受控的 foundation 长跑诊断，但不应直接跑 `curriculum.json` 中 1500 万到数亿 env steps 的完整 league。原因是当前代码已经证明 protocol-v2 tactical PPO 工程闭环和 8 卡任务编排可用，但训练质量证据还不足：

- reward 链路可用，但主要表现为结局胜利稀疏奖励；
- 8 卡 worker 是 8 个独立策略，不是共享 learner / DDP / MAPPO；
- fallback 仍偏高，不能把 fallback 执行效果解释为模型能力；
- 固定 seed Godot paired-match evaluator 仍未接入，无法做候选晋级评估。

## 已执行的扩训诊断

### 1. 单卡 reward 诊断

命令：

```bash
CUDA_VISIBLE_DEVICES=0 \
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
HOME="$PWD/.tools/godot-user" \
.conda/bin/python training/train_pipeline.py \
  --profile local_constrained \
  --plan hybrid_tactical_v2_ppo_pilot \
  --phase ppo \
  --execute \
  --output-dir training/runs/hybrid_tactical_v2_reward_diagnostic_2048 \
  --port 8880 \
  --seed 20260821 \
  --total-env-steps 2048 \
  --rollout-steps 128
```

结果：

- 实际 `env_steps=2404`；
- `episodes=1`；
- `best_rollout_reward=5.0`；
- `raw_step_calls=0`；
- Godot 日志显示该 reward 来自 match 结束时 winner 的 `ffa_win=5.0`。

判断：512-step pilot 的全 0 reward 不是链路断裂，而是窗口太短、奖励稀疏。

### 2. 8 卡 foundation diagnostic

新增配置：

```text
training/configs/multi_gpu/tactical_8gpu_foundation_diagnostic_8192.json
```

执行命令：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_foundation_diagnostic_8192.json \
  --execute
```

结果汇总：

- 编排器返回：`0`；
- 8 个 worker 全部 `returncode=0`；
- 总 env steps：`66,252`；
- 总 episodes：`48`；
- 总 transitions：`33,126`；
- 每个 worker 都有非零 reward rollout；
- 每个 worker `best_rollout_reward=5.0`；
- 总 rollout reward：`238.28`；
- `raw_step_calls=0`；
- 平均 fallback rate：`17.01%`；
- 最大 fallback rate：`21.38%`；
- 平均 safety override rate：`1.22%`；
- 训练结束后 GPU 显存和端口 `8870-8877` 无残留占用。

增强审计后的具体分量：

```text
fallback_reason_totals:
  scripted_target: 5634

reward_component_totals:
  win: 240.0
  environment_damage_taken: -2.16
  damage_taken: -0.2
  damage_dealt: 0.4
```

这说明当前 reward 绝大部分来自 48 局结束时的 `win` 分量。交战相关 dense reward 很少，且 fallback 全部来自 `SCRIPTED_TARGET`，也就是模型大量把目标选择委托给 scripted target path。

产物：

```text
training/runs/hybrid_tactical_v2_8gpu_foundation_diagnostic_8192/
```

## 是否值得扩大

值得继续扩大到**受控 foundation 训练和诊断增强**，不值得进入完整全量训练。

### 这样做不行

以下做法当前不值得继续：

1. 直接跑完整课程 `15,000,000+` env steps。
   - 原因：8 卡只是 8 个独立 checkpoint，不会合成一个共享策略。
   - 证据：当前 `ppo-multi` 每个任务都有独立 `output_dir` 和独立 `best_tactical_ppo.pt`。
2. 把 `best_rollout_reward=5.0` 当成策略变强。
   - 原因：`5.0` 主要来自 match 结束的 `win`，不是稳定交战优势。
   - 证据：8 卡 reward components 总计 `win=240.0`，但 `damage_dealt=0.4`。
3. 忽略 fallback 继续长跑。
   - 原因：fallback 代表底层 scripted path 接管或委托，不能计入模型能力。
   - 证据：平均 fallback rate `17.01%`，最大 `21.38%`，原因总计 `scripted_target=5634`。
4. 没有 evaluator 就挑 checkpoint。
   - 原因：训练 reward 不能替代固定 seed paired-match 评测。
   - 证据：当前 fixed-seed evaluator 仍只有报告层，真实 Godot paired-match runner 未接入。

### 这样执行才值得继续

下一步值得继续的执行方式：

1. 先降低 `SCRIPTED_TARGET` 委托率。
   - 目标：foundation diagnostic 的 fallback rate 从当前 `17.01%` 降到至少 `<10%`，最好 `<5%`。
   - 理由：否则模型学到的目标选择仍大量依赖 scripted target，不是完整高层策略。
2. 增加或验证 dense 交战 reward。
   - 目标：在 8 卡 8192-step diagnostic 中，`damage_dealt`、`damage_taken`、`kill/death` 等分量不再接近 0。
   - 理由：只有 `win` 的稀疏奖励会让 PPO 学习效率很低，长跑会消耗 GPU 但信号弱。
3. 每个训练 run 必须输出可解释 audit。
   - 必需字段：`fallback_reasons`、`reward_component_totals`、`raw_step_calls`、`safety_override_count`。
   - 理由：没有这些字段时，无法区分“模型进步”和“scripted fallback 帮它兜底”。
4. 接入真实 Godot fixed-seed evaluator 后再扩到多阶段课程。
   - 目标：至少能输出 scripted-hard 对战胜率、环境死亡率、空枪/伤害指标。
   - 理由：没有评测闭环，训练 reward 无法支撑 candidate 晋级。

推荐下一步门槛：

1. 先补充更细的 rollout 诊断，至少记录每轮：
   - reward components；
   - fallback reason histogram；
   - safety override reason；
   - match result；
   - damage/kill/death/empty-fire 指标。
2. 接入真实 Godot fixed-seed paired-match evaluator。
3. 改进训练配置，使单个 candidate 至少能跨多个完整 match，并以同一策略连续训练，而不是把 8 个独立 worker 当作一个模型。
4. 只有当 foundation run 同时满足以下条件时，再启动完整课程：
   - reward 不只依赖结局 `win`；
   - fallback rate 明显低于当前 17% 水平；
   - fixed-seed evaluator 可以给出 scripted-hard 基线对比；
   - 至少一个 candidate 的 replay/audit 没有 raw-step、fallback、safety 阻断；
   - 有清晰的 checkpoint 选择和晋级规则。

## 本轮不启动全量训练的原因

完整课程目标从 `15,000,000` 到 `400,000,000` env steps 量级。当前实现还没有共享多卡 learner，8 卡并行会产出 8 个互不合并的 checkpoint。直接全量跑会得到大量独立短视 checkpoint，而不是一个可评估、可晋级的 league policy。

因此，本轮已按“值得扩大”的最小合理范围执行：从 512-step 工程 pilot 扩大到 8 卡、约 6.6 万 env steps 的 foundation diagnostic，并保留完整产物和审计证据。
