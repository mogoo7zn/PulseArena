# 高层战术 RL 执行进度

最后更新：2026-08-01（Asia/Shanghai）

本文件是训练与子代理任务的项目内可见状态。临时的子代理报告保存在 `/tmp/pulsearena-sdd/2026-07-30-tactical-ppo-foundation/`；项目内的代码、测试、JSON 报告和本文档是长期可查看证据。

## 当前阶段

**阶段：Tactical PPO Foundation，Task 4 单 worker CUDA PPO pilot 已跑通；Task 5 评测报告层已开始，真实 Godot 固定 seed 矩阵 runner 未完成。**


| 任务                               | 状态  | 产物 / 可查看位置                                                                                  | 验证                                                |
| -------------------------------- | --- | ------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| 设计与完整训练逻辑                        | 完成  | [训练方案](../tactical-rl-plan.md)                                                                     | 已获用户确认                                            |
| 逐任务计划                            | 完成  | [实施计划](../../superpowers/plans/2026-07-30-tactical-ppo-foundation.md)                          | 已自检                                               |
| Task 1：episode/seed 数据切分与质量 gate | 完成 | `training/server_agent/tactical_data_quality.py`、`training/runs/tactical_data_quality.json` | 两种 unittest 命令均 7/7 通过；独立复审批准 |
| Task 2：Godot tactical Step API   | 完成 | `scripts/rl/training_server.gd`、`scripts/rl/environment_bridge.gd`、`scripts/arena/arena_root.gd`、`tests/smoke/tactical_training_protocol_check.py` | Godot unit、static check、TCP tactical smoke 通过 |
| Task 3：Masked Tactical PPO/GAE   | 完成 | `training/rl/tactical_ppo.py`、`training/rl/models.py`、`tests/unit/test_tactical_ppo.py`、`tests/smoke/tactical_ppo_cuda_micro_update.py` | 6/6 tactical PPO unittest 通过；A100 CUDA micro-update 通过 |
| Task 4：单 worker CUDA PPO 闭环      | 完成 | `training/rl/tactical_online_trainer.py`、`training/rl/godot_env.py`、`training/configs/training_plans/hybrid_tactical_v2_ppo_pilot.json`、`training/runs/hybrid_tactical_v2_ppo_pilot/` | fake-env runner unittest 通过；512 env-step Godot+CUDA pilot 完成 |
| Task 5：固定 seed 评测与晋级报告           | 进行中 | `training/evaluate_tactical_candidate.py`、`tests/unit/test_evaluate_tactical_candidate.py`、`docs/training/runbooks/tactical-training.md` | gate/report 层 3/3 unittest 通过；真实 Godot paired-match runner 未接入 |




## Task 1 实测摘要

- 有效 replay：259,630 行，29 个 episode；
- 格式错误：0；非法教师标签：0；
- 地图覆盖：4 张；模式覆盖：FFA 与 2v2；
- 回退率：99.8675%；连续相同高层决策率：99.3296%。

最后两项是数据风险信号，当前报告只记录、不会自动把它们伪装为通过策略质量的证据。后续的 BC/RL warm start 与候选晋级将据此设置独立门槛。

## Task 1 审查结论

初次审查要求修改；修复轮 1 已通过独立复审，以下问题均已解决：

1. action mask 逐元素严格要求 JSON boolean；
2. 四个 action head 独立统计标签覆盖；
3. 项目内 `tests` 包标记使模块式 unittest 稳定定位；
4. audit 与 BC loader 使用相同的顶层 replay 文件发现规则。

## Task 2 审查修复结论

Task 2 初次审查指出：遗漏玩家会继续执行旧 tactical decision、`observe_tactical` 与 `step_tactical` 的可控玩家集合不一致、缺少填充 tactical snapshot 的 durable 回归测试，以及 diagnostics allowlist 过浅。

修复后的协议约束为：每个 `step_tactical` 请求必须精确包含当前 snapshot 广告的全部 live Hybrid player id；缺失、额外或重复 id 会在任何 cache/arena 状态变更前被拒绝。非 Hybrid 玩家只返回 `supports_tactical_decisions:false`，不返回伪造的 tactical features 或 masks。diagnostics 只按固定安全 schema 序列化。

2026-08-01 复验：

```bash
HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --disable-crash-handler --path . --script tests/run_tests.gd
python3 tests/smoke/static_project_check.py
HOME="$PWD/.tools/godot-user" python3 tests/smoke/tactical_training_protocol_check.py --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --port 18766
```

结果：Godot unit tests 通过；static project check 通过；TCP smoke 返回 protocol `2`、两个 142 维 feature、mask 长度 `7/12/6/6`、拒绝 `move_x` raw 字段、拒绝遗漏玩家、mixed match 只广告 Hybrid player id `[1]`。

## Task 3/4 PPO pilot 摘要

Task 3 新增 `TacticalActorCritic` 与 `training/rl/tactical_ppo.py`，实现四个 masked categorical head、联合 log-prob/entropy、terminated/truncated-aware GAE、sequence minibatch、PPO clip/value/entropy/KL 指标、gradient clipping 和 BC head warm-start 维度检查。

Task 4 新增 `training/rl/tactical_online_trainer.py` 和 plan `hybrid_tactical_v2_ppo_pilot`。runner 只调用 `observe_tactical` / `step_tactical`，不调用 legacy raw `step`；输出 `best_tactical_ppo.pt`、`last_tactical_ppo.pt`、`metrics.jsonl`、`config.json`、`rollout_audit.json`。

2026-08-01 本机 GPU 证据：

```text
nvidia-smi: 8 x NVIDIA A100-SXM4-80GB, no running processes before pilot
.conda PyTorch: 2.5.1+cu121, CUDA available, device_count=8
```

512 env-step pilot 命令：

```bash
CUDA_VISIBLE_DEVICES=0 MPLCONFIGDIR="$PWD/test-results/matplotlib" GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" .conda/bin/python training/train_pipeline.py --profile local_constrained --plan hybrid_tactical_v2_ppo_pilot --phase ppo --execute
```

输出摘要：

- device：`cuda`，GPU：`NVIDIA A100-SXM4-80GB`；
- env_steps：512；updates：4；transitions：256；
- tactical_step_calls：128；raw_step_calls：0；
- checkpoint：`training/runs/hybrid_tactical_v2_ppo_pilot/best_tactical_ppo.pt`；
- 最后一轮 PPO 指标：policy_loss `-0.0309892185`，value_loss `0.0000463536`，entropy `6.9279969931`，approx_kl `0.0114819944`，clip_fraction `0.1796875`。

说明：这只是有界工程 pilot，验证闭环、GPU、artifact 和 raw-step 隔离；`rollout_reward` 当前为 `0.0`，不能解释为候选强度，也不能晋级 catalog。

## 当前残余验证风险

- 完整 Python unit suite 在非沙箱环境中跑到 31 个测试，其中本次新增 tactical 相关测试全部通过；一个既有 `test_failed_start_preserves_state_replaced_by_another_process` web preview 生命周期测试失败，表现为失败启动时 log 被 `[Errno 98] Address already in use` 覆盖。该失败与高层 tactical RL runner 无关，未在本轮混入修复。
- Godot unit harness 仍报告 `28 ObjectDB instances were leaked at exit` warning，但 exit code 为 0；这是既有测试清理噪声。
- Task 5 当前只完成固定 seed 选择、gate 汇总、JSON/中文 Markdown 报告层。默认 evaluator 尚未接入真实 Godot paired-match runner；因此还不能用它产出候选晋级结论。


## 如何自行查看

```bash
# 当前正式进度
sed -n '1,240p' docs/training/status/tactical-rl-progress.md

# 数据质量报告
sed -n '1,260p' training/runs/tactical_data_quality.json

# 当前任务计划
sed -n '1,260p' docs/superpowers/plans/2026-07-30-tactical-ppo-foundation.md

# 运行当前任务的定向测试
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_data_quality.py' -v
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_ppo.py' -v
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_online_trainer.py' -v
CUDA_VISIBLE_DEVICES=0 HOME="$PWD/.tools/godot-user" .conda/bin/python tests/smoke/tactical_ppo_cuda_micro_update.py
```

说明：`python -m unittest tests.unit...` 在此环境会被第三方同名 `tests` 包遮蔽，因此项目统一使用 `unittest discover` 运行新增 Python 单测。

## 文档维护记录

2026-08-01：文档已按领域重组到 `docs/` 英文路径树，中文标题与正文内容保留。此次维护只更新本地文件；未添加 GitHub remote，也未执行 fetch、pull 或 push。
