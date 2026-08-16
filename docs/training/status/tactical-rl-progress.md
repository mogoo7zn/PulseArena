# 高层战术 RL 执行进度

最后更新：2026-08-04（Asia/Shanghai）

本文件是训练与子代理任务的项目内可见状态。临时的子代理报告保存在 `/tmp/pulsearena-sdd/2026-07-30-tactical-ppo-foundation/`；项目内的代码、测试、JSON 报告和本文档是长期可查看证据。

## 当前阶段

**阶段：修复 draw-as-win 评估缺陷后的双策略训练准备。默认游戏服务仍是 `hybrid_tactical_v1`；已部署/登记 checkpoint 保持原位，旧 PPO 运行不再作为续训来源。**

2026-08-04：已将 9 个 pre-draw-fix 训练目录及 4 个 20260802 评估目录移动至
`training/artifacts/runs/archived/pre_draw_fix/`。移动由固定白名单脚本执行；
`training/models/`、`training/artifacts/checkpoints/hybrid/`、BC 基座与 20260804 修复后评估均未移动。
旧结果曾把 0:0 平局计为排序靠前玩家的胜利，因此不得再用于 PPO resume、胜率报告或模型晋级。


| 任务                               | 状态  | 产物 / 可查看位置                                                                                  | 验证                                                |
| -------------------------------- | --- | ------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| 设计与完整训练逻辑                        | 完成  | [训练方案](../tactical-rl-plan.md)                                                                     | 已获用户确认                                            |
| 逐任务计划                            | 完成  | [实施计划](../../superpowers/plans/2026-07-30-tactical-ppo-foundation.md)                          | 已自检                                               |
| Task 1：episode/seed 数据切分与质量 gate | 完成 | `training/server_agent/tactical_data_quality.py`、`training/artifacts/runs/tactical_data_quality.json` | 两种 unittest 命令均 7/7 通过；独立复审批准 |
| Task 2：Godot tactical Step API   | 完成 | `scripts/rl/training_server.gd`、`scripts/rl/environment_bridge.gd`、`scripts/arena/arena_root.gd`、`tests/smoke/tactical_training_protocol_check.py` | Godot unit、static check、TCP tactical smoke 通过 |
| Task 3：Masked Tactical PPO/GAE   | 完成 | `training/rl/tactical_ppo.py`、`training/rl/models.py`、`tests/unit/test_tactical_ppo.py`、`tests/smoke/tactical_ppo_cuda_micro_update.py` | 6/6 tactical PPO unittest 通过；A100 CUDA micro-update 通过 |
| Task 4：单 worker CUDA PPO 闭环      | 完成 | `training/rl/tactical_online_trainer.py`、`training/rl/godot_env.py`、`training/configs/training_plans/hybrid_tactical_v2_ppo_pilot.json`、`training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/` | fake-env runner unittest 通过；512 env-step Godot+CUDA pilot 完成 |
| Task 5：固定 seed 评测与晋级报告           | 进行中 | `training/evaluation/evaluate_tactical_candidate.py`、`tests/unit/test_evaluate_tactical_candidate.py`、`docs/training/runbooks/tactical-training.md` | gate/report/service-metrics 层 4/4 unittest 通过；真实 Godot paired-match runner 未接入 |
| Task 6：8 卡并行 tactical PPO 编排 | 完成 | `training/orchestration/multi_gpu_orchestrator.py`、`training/configs/multi_gpu/tactical_8gpu_parallel_pilot.json`、`training/configs/training_plans/hybrid_tactical_v2_8gpu_parallel_pilot.json`、`training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/` | 8 个独立 protocol-v2 worker 全部完成；每卡 512 env steps；所有 audit `raw_step_calls: 0` |
| Task 7：BC warm-start PPO 诊断 | 完成 | `training/configs/training_plans/hybrid_tactical_v2_bc_warmstart_ppo_pilot.json`、`training/configs/multi_gpu/tactical_8gpu_bc_warmstart_diagnostic_8192.json`、`training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192/`、`docs/training/status/tactical-service-training-report-2026-08-02.md` | 8 个 worker 全部 `returncode=0`；`raw_step_calls=0`；fallback rate 从 `17.0078%` 降到 `0.0634%`；`damage_dealt` 从 `0.4` 增到 `10.8` |
| Task 8：BC warm-start 扩大训练 | 完成 | `training/configs/multi_gpu/tactical_8gpu_bc_warmstart_expanded_65536.json`、`training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/`、`docs/training/status/tactical-expanded-training-report-2026-08-02.md` | 8 个 worker 全部 `returncode=0`；总 `env_steps=529,940`；`raw_step_calls=0`；fallback rate `0.0087%`；`damage_dealt=88.14`；safety override rate `6.9574%` |
| Task 9：PPO checkpoint 续训与候选接入 | 完成 | `training/configs/multi_gpu/tactical_8gpu_ppo_resume_expanded_262144.json`、`training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/`、`training/models/hybrid_tactical_v2_ppo_resume_candidate_20260802_agent.json`、`docs/training/status/tactical-ppo-resume-expanded-report-2026-08-02.md` | 8 个 worker 全部 `returncode=0`；总 `env_steps=2,097,664`；`raw_step_calls=0`；fallback rate `0.0190%`；`damage_dealt=323.44`；service TCP smoke 可显式请求候选；默认模型未 promotion |
| Task 10：服务链路 self-play 评测 smoke | 完成 | `training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_service_dev8/`、`docs/training/status/tactical-ppo-resume-expanded-report-2026-08-02.md` | 8 个 dev seed，`service_backed_match=1.0`；`NORMAL+BURST=49.79%`；`fire_blocked_rate=71.57%`；主要 block reason 为 `no_line_of_sight=29.33%`、`hold_fire=17.38%`、`reserved_energy=8.59%`；promotion gates 仍因缺 paired/human metrics 失败 |




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
CUDA_VISIBLE_DEVICES=0 MPLCONFIGDIR="$PWD/test-results/matplotlib" GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" .conda/bin/python training/pipeline/train_pipeline.py --profile local_constrained --plan hybrid_tactical_v2_ppo_pilot --phase ppo --execute
```

输出摘要：

- device：`cuda`，GPU：`NVIDIA A100-SXM4-80GB`；
- env_steps：512；updates：4；transitions：256；
- tactical_step_calls：128；raw_step_calls：0；
- checkpoint：`training/artifacts/runs/hybrid_tactical_v2_ppo_pilot/best_tactical_ppo.pt`；
- 最后一轮 PPO 指标：policy_loss `-0.0309892185`，value_loss `0.0000463536`，entropy `6.9279969931`，approx_kl `0.0114819944`，clip_fraction `0.1796875`。

说明：这只是有界工程 pilot，验证闭环、GPU、artifact 和 raw-step 隔离；`rollout_reward` 当前为 `0.0`，不能解释为候选强度，也不能晋级 catalog。

## Task 6：8 卡并行 pilot 摘要

Task 6 新增 `training/orchestration/multi_gpu_orchestrator.py`，提供独立训练任务的 GPU 分配、冲突拒绝、`CUDA_VISIBLE_DEVICES` 注入、dry-run、日志路径、fail-fast 和非 0 退出传播。`training/pipeline/train_pipeline.py` 新增 `ppo-multi` phase；单 worker tactical PPO 仍然只通过 `observe_tactical` / `step_tactical` 运行，不复用 legacy raw-action `online_trainer.py`，也不伪装成 DDP。

8 卡配置位于 `training/configs/multi_gpu/tactical_8gpu_parallel_pilot.json`。该配置启动 8 个独立 worker：

- GPU：`0` 到 `7` 分别独占；
- Godot 端口：`8870` 到 `8877`；
- 输出目录：`training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu0/` 到 `gpu7/`；
- 日志目录：`training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/logs/`。

2026-08-01 复验命令：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" .conda/bin/python -m unittest discover -s tests/unit -v
.conda/bin/python -c "import torch; print(torch.cuda.is_available(), torch.cuda.device_count())"
CUDA_VISIBLE_DEVICES=0 HOME="$PWD/.tools/godot-user" .conda/bin/python tests/smoke/tactical_ppo_cuda_micro_update.py
HOME="$PWD/.tools/godot-user" python3 tests/smoke/tactical_training_protocol_check.py --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --port 18767
MPLCONFIGDIR="$PWD/test-results/matplotlib" .conda/bin/python training/pipeline/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_8gpu_parallel_pilot --phase ppo-multi --execute
```

结果摘要：

- Python unit suite：38/38 通过；
- PyTorch CUDA：`2.5.1+cu121`，CUDA 可用，`device_count=8`，8 张 `NVIDIA A100-SXM4-80GB`；
- CUDA micro-update：通过；
- Godot TCP protocol smoke：protocol `2`，feature 长度 `142`，mask 长度 `7/12/6/6`，raw 字段被拒绝；
- 8 卡 pilot：编排器返回 `0`，8 个 worker 全部 `returncode: 0`；
- 每个 worker：`env_steps=512`、`tactical_step_calls=128`、`transitions=256`、`raw_step_calls=0`、`last_tactical_ppo.pt` 存在；
- 训练结束后：GPU 显存占用为 `0MiB`，端口 `8870-8877` 无监听残留。

## 当前残余验证风险

- Task 5 当前只完成固定 seed 选择、gate 汇总、JSON/中文 Markdown 报告层。默认 evaluator 尚未接入真实 Godot paired-match runner；因此还不能用它产出候选晋级结论。
- 8 卡 pilot 是多任务资源编排，不是单 run 多卡同步 learner；不能把它解释为 MAPPO/DDP 已完成。
- 当前 `training/models/model_catalog.json` 仍只包含 `hybrid_tactical_v1`，训练 checkpoint 没有接入默认游戏服务。
- BC warm-start PPO 的 safety override rate 为 `7.3421%`，高于随机 PPO foundation 的 `1.2166%`；说明模型更积极后仍需拆解安全覆盖原因，不能直接上线。
- 8 卡训练仍是 8 个独立 checkpoint，不能把它解释为单一共享 learner 或已完成 league training。


## 如何自行查看

```bash
# 当前正式进度
sed -n '1,240p' docs/training/status/tactical-rl-progress.md

# 数据质量报告
sed -n '1,260p' training/artifacts/runs/tactical_data_quality.json

# 当前任务计划
sed -n '1,260p' docs/superpowers/plans/2026-07-30-tactical-ppo-foundation.md

# 运行当前任务的定向测试
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_data_quality.py' -v
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_ppo.py' -v
PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -p 'test_tactical_online_trainer.py' -v
PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_multi_gpu_orchestrator -v
CUDA_VISIBLE_DEVICES=0 HOME="$PWD/.tools/godot-user" .conda/bin/python tests/smoke/tactical_ppo_cuda_micro_update.py
```

说明：`python -m unittest tests.unit...` 在此环境会被第三方同名 `tests` 包遮蔽，因此项目统一使用 `unittest discover` 运行新增 Python 单测。

## 文档维护记录

2026-08-01：文档已按领域重组到 `docs/` 英文路径树，中文标题与正文内容保留。此次维护只更新本地文件；未添加 GitHub remote，也未执行 fetch、pull 或 push。

2026-08-01：新增 8 卡并行 tactical PPO 编排、`ppo-multi` 入口、8 卡 pilot 配置与运行指南；执行并核对 8 个短时 CUDA/Godot worker。

2026-08-01：完成扩训判断，报告见 `docs/training/status/tactical-rl-scale-analysis-2026-08-01.md`。已执行单卡 reward 诊断和 8 卡 foundation diagnostic；结论是当前可继续受控扩大 foundation 训练，但不应直接启动完整课程全量训练。

2026-08-01：增强 tactical PPO `rollout_audit.json`，新增 `fallback_reasons` 与 `reward_component_totals`。重新执行 8 卡 foundation diagnostic 后，汇总指标为：`total_env_steps=66,252`、`episodes=48`、`raw_step_calls=0`、平均 fallback rate `17.01%`、最大 fallback rate `21.38%`、fallback 原因 `scripted_target=5634`；reward 分量为 `win=240.0`、`environment_damage_taken=-2.16`、`damage_taken=-0.2`、`damage_dealt=0.4`。该证据说明当前 reward 主要来自结局胜利，交战 dense reward 很弱，完整全量训练仍不应启动。

2026-08-02：确认训练结果尚未接入默认游戏服务：`model_catalog.json` 仍默认 `hybrid_tactical_v1`，manifest `checkpoint` 为空，`serve_agent --print-info` 返回 `kind=hybrid_tactical_prior`。修复 PPO warm-start 接线，使 online PPO 可从 `training/artifacts/runs/hybrid_tactical_bc/best_tactical_policy.pt` 加载 BC encoder/trunk 与 actor heads；新增 8 卡 BC warm-start 诊断并执行完成。汇总指标为：`env_steps=66,248`、`episodes=48`、`raw_step_calls=0`、fallback rate `0.0634%`、safety override rate `7.3421%`、`damage_dealt=10.8`、`kill=3.0`、`death=-2.0`、`win=240.0`。结论：BC warm-start 路线值得继续受控扩大，但通过固定 seed evaluator 前仍不更新 catalog、不接入默认游戏服务。

2026-08-02：执行 8 卡 BC warm-start expanded run，配置见 `training/configs/multi_gpu/tactical_8gpu_bc_warmstart_expanded_65536.json`，产物见 `training/artifacts/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/`。8 个 worker 全部 `returncode=0`，总 `env_steps=529,940`、`updates=384`、`episodes=384`、`transitions=264,970`、`raw_step_calls=0`；fallback rate `0.0087%`，safety override rate `6.9574%`，reward sum `1,950.71`，`damage_dealt=88.14`、`kill=6.0`、`death=-4.0`、`win=1,920.0`。报告见 `docs/training/status/tactical-expanded-training-report-2026-08-02.md`。该结果支持继续 BC warm-start 路线，但仍不是完整 MAPPO league，也未接入默认游戏服务。

2026-08-02：修复 inference/import/diagnose 对 `tactical_actor_critic` 的支持，新增 tactical PPO `resume_checkpoint`，使续训真正从上一轮 PPO `model_state` 继续，而不是重新从 BC warm-start。已将 `hybrid_tactical_v2_ppo_expanded_candidate_20260802` 与 `hybrid_tactical_v2_ppo_resume_candidate_20260802` 加入 `training/models/model_catalog.json` 作为非默认候选，`default_model_id` 仍为 `hybrid_tactical_v1`。执行 8 卡 PPO resume expanded run，配置见 `training/configs/multi_gpu/tactical_8gpu_ppo_resume_expanded_262144.json`，产物见 `training/artifacts/runs/hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144/`。8 个 worker 全部 `returncode=0`，总 `env_steps=2,097,664`、`updates=1,520`、`episodes=1,520`、`transitions=1,048,832`、`raw_step_calls=0`；fallback rate `0.0190%`，safety override rate `6.5353%`，reward mean `5.0669`，`damage_dealt=323.44`、`kill=30.0`、`death=-20.0`、`win=7,600.0`。报告见 `docs/training/status/tactical-ppo-resume-expanded-report-2026-08-02.md`。

2026-08-02：新增 `evaluate_tactical_candidate.py --runner godot-service`，可启动 `serve_agent` 与 Godot training server 跑真实服务链路 self-play smoke，并聚合 fire mode、fire block reason、fallback、安全覆盖、空枪和环境死亡率。已对 `hybrid_tactical_v2_ppo_resume_candidate_20260802` 执行 8 个 dev seed 短局，产物见 `training/artifacts/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_service_dev8/`；结果为 `service_backed_match=1.0`、`NORMAL+BURST=49.79%`、`fire_blocked_rate=71.57%`、`no_line_of_sight=29.33%`、`hold_fire=17.38%`、`reserved_energy=8.59%`。promotion gates 因缺少 paired baseline win/top1 与 human eval 指标保持失败。

## 接续训练 phase 0 现状（2026-08-16）

执行接续训练前的前置检查结果。**未开始任何训练**——只在阅读和检查层面推进。

### 运行前置（按 README §4 顺序）

| 项 | 结果 |
|---|---|
| Godot 二进制 | ✅ `.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64` 存在（144 MB） |
| Python / torch | ✅ Python 3.10.20、PyTorch 2.5.1+cu121、CUDA 可用、`device_count=8` |
| 端口 | ✅ 18766/18767/18945/18961–18964/8870/8877 均空闲 |
| GPU 空闲 | ✅ 8 张 A100-SXM4-80GB 显存全部 0 MiB |
| model_catalog | ✅ default=`hybrid_tactical_v1`；3 个候选；3 个"幽灵候选"manifest 仍在 |
| `tactical_legal_window_pressure_four_map_ballistic_repair.json` | ✅ 存在 |
| `legal_window_pressure_ballistic_repair_gpu4_7.json` | ✅ 存在 |
| git 状态 | �️ dirty——`M .github/workflows/linux.yml` 等 52 个 modified，3 个 untracked 计划，多个 untracked 测试与 `training/` 子树 |
| 目标输出目录 | �️ `training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/` 已存在（旧 run）；`docs/plan/02-GPU-4-isolated-diagnostic.md §2` 要求独立目录 |
| 训练入口 `training/pipelines/train_pipeline.py` 可执行 | ❌ **ROOT 路径常量失效**：`parents[1]` 在文件从 `training/pipeline/` 移到 `training/pipelines/` 后少了一层；`PROFILES_DIR`/`PLANS_DIR`/`MULTI_GPU_DIR` 都解析到 `training/training/configs/...`；`resolve_profile` 抛 `Unknown profile`，整条 CLI 在第 302 行就退出 |

### 已就位、未验证（00- §3 摘要）

代码改动落到位但**未经 TDD**：

- decision 账本（`arena_root.gd` + `reward_calculator.gd` + `environment_bridge.gd` + `tactical_online_trainer.py`）；
- 资源兑现账本（`pickup.gd` + `player.gd` + `reward_config.gd` + `reward_calculator.gd`）；
- 4 张地图 source-tagged（`dungeon/sky_city/jungle/mist_world_rule.gd` + `arena_root.gd`）；
- ballistic lane 共享（`ballistic_aim_solver.gd` + `tactical_feature_builder.gd` + `movement_executor.gd`）；
- reserve 拆原因（`fire_control.gd` + `hybrid_combat_executor.gd` + `environment_bridge.gd`）；
- cover→re-engage 生命周期（`tactical_online_trainer.py`）；
- pressure 控件暴露（`hybrid_agent_config.gd` + `tactical_teacher.gd` + `hybrid_agent_controller.gd` + `fire_control.gd`）。

### "幽灵候选"（00- §4）

`pressure_contact_reset_fallback_free_candidate_agent.json`、`pressure_curriculum_geometric_fire_gpu7_candidate_agent.json`、`pressure_curriculum_resource_gpu6_candidate_agent.json` 三个 manifest 仍存在；未登记到 `model_catalog.json`。

### phase 0 阻塞（关键）

1. **CLI 入口 ROOT 路径常量失效**：单字符问题，但训练管线任何 `--phase` 之前就会失败。直接 `python -c "from training.core.tactical_online_trainer import train_tactical_ppo"` 等**底层模块导入正常**；只是 CLI driver `training/pipelines/train_pipeline.py` 第 12 行 `ROOT = Path(__file__).resolve().parents[1]` 因文件从 `training/pipeline/` 移到 `training/pipelines/` 少了一层。
2. **git dirty**：`docs/plan/02-` §1 第 6 项"不要在 dirty 状态跑"。
3. **目标目录已占用**：`training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/` 已有旧 run；需要按 `02-` §2 处理（归档或 `_v2` 后缀）。
4. **scope 边界冲突**：`docs/plan/README.md §1` 说"不修改任何 Godot/Python 业务代码"；但 ROOT 路径修复是**路径常量**（不是业务逻辑），属于 phase 0 的前置修复而非计划内容。需要用户确认。

### 阶段 1 决策表（00- §7）草拟

| 问题 | 草拟答案 |
|---|---|
| `git status` 里 52 个 modified 是阶段 1 输入吗？ | 部分。`docs/`、`archive/`、`tests/unit/` 等都是结构整理；`scripts/agents/hybrid/` 移到 `scripts/agents/`、新增 `training/pipelines/` 等也是结构整理；**真正的"业务代码未提交改动"是 ballistic lane / reserve basis / cover lifecycle 等模块**，需要先冻结到新 spec 再进入阶段 1。 |
| 3 个"幽灵候选"是否归档？ | 待定——`docs/plan/00-` 建议归档；本轮未动。 |
| 是否需要新写"修复 plan" 冻结未提交改动？ | **建议：是**——08-06 / 08-08 设计稿从 `_archived/` 复活到 `docs/superpowers/specs/`，并写一份"修复 plan" 到 `docs/superpowers/plans/`。 |
| 阶段 1 GPU | 推荐 GPU-4（按 `02-` §1）。 |
| 阶段 1 plan | 推荐 `tactical_legal_window_pressure_four_map_ballistic_repair`（按 `02-`）。 |

### 当前状态

**未动 `scripts/`、`training/core/`、`training/server/`、`training/pipelines/`、`docs/`、`archive/`、`tests/`、`Makefile`、`.github/` 等任何文件**——本轮只读不写。phase 0 阻塞已记录，等待用户决策 ROOT 修复 + git dirty 处理 + 目录归档三件事后再进入阶段 1。
