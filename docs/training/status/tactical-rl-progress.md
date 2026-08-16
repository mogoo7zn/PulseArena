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

## phase 0 收尾与阶段 1（2026-08-16）

### 用户决策（接 phase 0 之后）

1. **CLI ROOT 修复**：同意单字符路径常量修复（`training/pipelines/train_pipeline.py` 第 12 行 `parents[1]` → `parents[2]`）。
2. **git dirty**：按主题拆分（多次提交）。详见 git log。
3. **GPU-4 旧目录**：归档（`mv training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4 → archived/pre_draw_fix/ballistic_repair_gpu4_20260804_legacy`）。
4. **3 个幽灵候选**：归档（`mv training/models/pressure_*.json → archived/ghost_candidates/`）。

### git log（按主题拆分）

```text
546edb7 refactor(training): split training/ into training/{core,server,evaluation,inference,pipelines}
0776f42 test: update test suite for reorganized training pipeline
4fc4134 refactor(scripts): relocate scripts/linux/ → scripts/ops/
43942cb refactor(scripts): finish scripts/agents/hybrid/ removal + cascade updates
e4b53ee refactor(scripts/agents): flatten scripts/agents/hybrid/ → scripts/agents/
b74d2a7 docs(training): drop stale legacy snapshot of tactical-rl-progress
385aca6 docs(repo): reorganize docs/ tree, archive 08-04 / 08-06 / 08-08 design & plan files
43f860d fix(training): correct ROOT path after training/pipeline → training/pipelines move
```

工作区剩余未跟踪：`/.claude/`、`/.gemini/`（agent 工作区文件，不入库）。

### 阶段 1：BC 结果（collect 跳过——replay 已就位）

`training/data/replays/four_map_ballistic_repair_bc/` 已有 32 个 `*.hybrid_v2.jsonl`（4 图 × 8 局，每局 ≈7200 行，228,266 总样本，2026-08-08 收集，map_id 0/1/2/3 各 8 平衡分布；与 `02-` §3 的"预期"完全匹配），跳过 collect 直接 BC。

```bash
CUDA_VISIBLE_DEVICES=4 MPLCONFIGDIR="$PWD/test-results/matplotlib" \
  .conda/bin/python training/pipelines/train_pipeline.py \
    --profile local_constrained \
    --plan tactical_legal_window_pressure_four_map_ballistic_repair \
    --phase bc --execute
```

BC 数字（40 epoch，415.26s）：

| head | val_acc | 门槛 | 状态 |
|---|---|---|---|
| target | 0.9925 | ≥ 0.85 | ✅ |
| movement | 0.9201 | ≥ 0.85 | ✅ |
| fire | 0.9186 | ≥ 0.85 | ✅ |
| skill | 0.9955 | ≥ 0.85 | ✅ |
| best_val_loss | 0.4400 (epoch 36) | — | ✅ |

产物：`training/artifacts/runs/four_map_ballistic_repair_bc/best_tactical_policy.pt`、`metrics.csv`、`metrics.png`、`swanlab/`。

### 阶段 1：PPO 进行中

```bash
CUDA_VISIBLE_DEVICES=4 MPLCONFIGDIR="$PWD/test-results/matplotlib" \
GODOT_BIN="$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
  .conda/bin/python training/pipelines/train_pipeline.py \
    --profile local_constrained \
    --plan tactical_legal_window_pressure_four_map_ballistic_repair \
    --phase ppo --execute \
    --output-dir training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4 \
    --port 18961 --seed 20261086
```

- 计划 `total_env_steps=16,384`，`rollout_steps=256`，预计 64 update × 64 episode；
- 输出：`training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/{best_tactical_ppo.pt, last_tactical_ppo.pt, metrics.jsonl, config.json, rollout_audit.json}`；
- BC warm-start：`training/artifacts/runs/four_map_ballistic_repair_bc/best_tactical_policy.pt`；
- 后台运行中——稍后回填 `metrics.jsonl` 与 `rollout_audit.json` 的硬门槛数字。

### 第一次 PPO 失败 + 修复

第一次 PPO 启动 30 秒后退出 (`step_ipc_unavailable`)：Godot 训练 server 报 `Class "HighLevelDecision" hides a global script class`。根因是 `scripts/agents/hybrid/` → `scripts/agents/` 扁平化后，`.godot/global_script_class_cache.cfg`（gitignored）里仍有 11 条指向旧 `res://scripts/agents/hybrid/*.gd` 的注册条目。Godot 把新 `class_name HighLevelDecision` 当成与旧条目冲突。

修复：

```bash
rm .godot/global_script_class_cache.cfg
HOME="$PWD/.tools/godot-user" timeout 60 \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
    --headless --editor --quit
```

`tests/run_tests.gd` 第二次跑 `PASS: Godot unit tests`；训练 server 启动打印 `{"host":"127.0.0.1","port":18766,"training_server":"listening"}`。再启动 PPO——继续监控中。

### PPO 完成（阶段 1 第二次跑）

PPO exit 0。`training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/`：
- `best_tactical_ppo.pt`（439 KB）、`last_tactical_ppo.pt`、`metrics.jsonl`（4.6 KB / 18 update + 1 final）、`config.json`、`rollout_audit.json`（46.9 KB）。

`metrics.jsonl` 关键数字（18 update / env_steps=17,092 / episodes=4）：

| update | env_steps | rollout_reward | policy_loss | value_loss | entropy | approx_kl | clip_fraction |
|---|---|---|---|---|---|---|---|
| 1 | 1024 | **8.92** | 1.39e-4 | 3.004 | 0.551 | 1.07e-6 | 0.0 |
| 4 | 3780 | 4.6 | 7.23e-3 | 1.182 | 0.735 | 1.93e-2 | 0.305 |
| 9 | 8584 | 0.16 | -4.13e-3 | 0.033 | 0.297 | 6.48e-4 | 0.011 |
| 18 | 17092 | 4.32 | -1.88e-3 | 0.195 | 0.251 | 2.92e-4 | 0.004 |

> 注：plan §5 期望 `updates=64 / episodes=64`；实际 `updates=18 / episodes=4`。差距来自**每个 episode = 60 秒游戏 + Godot 仿真开销**（不是 256 env-step = 1 episode）。`total_env_steps=17,092` 已超出 `total_env_steps=16,384` 目标，update 数与 `total_env_steps / rollout_steps` 比例一致。

`rollout_audit.json` 关键数字：

| 维度 | 值 |
|---|---|
| `tactical_step_calls` | 4,273 |
| `transitions` | 4,273 |
| `raw_step_calls` | 0 |
| `fallback_count` | 0 |
| `decision_generation_consistent` | true |
| `event_counter_consistent` | true |
| `map_episode_counts` | dungeon:2, sky_city:1, jungle:1, mist_world:1 |
| `tactical_event_counts.fire_intent` / `fire_authorized` | 814 / 44 = **5.41%**（基线 1.57%） |
| `fire_mode_distribution` | HOLD_FIRE:3262 / NORMAL:572 / CONSERVATIVE:409 / BURST:26 / ALL_IN:4 |
| `fire_block_reasons` | reserved_energy:623 / weapon_cooldown:146 / low_hit_probability:6 |
| `map_line_of_sight_block_counts` | {}（**空**——ballistic lane repair 生效，LoS 改成 vantage 路由，不再算作 block 原因） |
| `reserved_energy_by_basis` | projectile_threat:474 / conservative:132 / shield_ready:15 / dash_ready:2 |
| `map_reserved_energy_by_basis`（每图） | 4 个非零项均覆盖 |
| `cover_entry_count` | 41 |
| `cover_reengage_count` | 22 |
| `safety_override_count` / `reasons` | 346 / emergency_projectile:346 |
| `target_valid_count` / `target_change_count` | 3,959 / 388 |
| `reward_component_totals` | damage_dealt:13.6 / kill:3 / damage_taken:-2.6 / win:5.0 |
| `map_environment_event_counts` | jungle: swamp:13, snake:22 / mist_world: portal:1, fog:4 |
| `map_resource_event_counts` | jungle: pickup_collected_health:1, pickup_collected_haste:1 / mist_world: pickup_collected_magnet:1 |

### 阶段 1 退出条件检查（按 01- §阶段 1）

| 门槛 | 结果 |
|---|---|
| `raw_step_calls == 0` | ✅ 0 |
| `fallback_rate == 0` | ✅ 0 |
| `decision_generation_consistent == true` & `audit_consistency_flags == true` | ✅ 都 true |
| 4 张地图都有 episodes | ✅ 2/1/1/1 |
| `fire_authorized / fire_intent >= 0.015` | ✅ 5.41%（基线 1.57%，本阶段目标 1.5%） |
| Sky/Mist LoS 块 < 68.4% / 72.0% & reserve basis 可识别 | ✅ `map_line_of_sight_block_counts: {}`（修复后空）；reserve basis 4 个非零（projectile_threat / conservative / shield_ready / dash_ready） |

附加观察：cover_entry=41、cover_reengage=22、`authorized_damage=340`、`authorized_hit=17`、`map_environment_event_counts` 真有 jungle swamp/snake + mist portal/fog、`map_resource_event_counts` 真有 pickup 收集 → 04-06/08-08 修复方向**真的有效**。

**阶段 1 通过** → 进入阶段 2（TDD 红→绿循环）。

### 阶段 1 产物备份

按 02- §7：把这次数字 append 到 progress（已做）；run 目录保留在 `training/artifacts/runs/legal_window_pressure/ballistic_repair_gpu4/`（未改名——阶段 1 唯一一次跑，没有要回滚的版本）。

### 阶段 2：复合修复 TDD（红→绿循环）

按 03- §7 跑 5 组测试。

**修复前（基线）**：

| 组 | 结果 |
|---|---|
| 1a. Godot unit (`tests/run_tests.gd`) | ✅ PASS |
| 1b. Static check (`static_project_check.py`) | ✅ PASS |
| 2. Python unit (`tests/unit/`) | ❌ 14 个失败（8 fail + 6 error） |
| 3. Protocol smoke (`tactical_training_protocol_check.py`) | ❌ FAIL——`reserve_basis` / `reserve_ratio` 触发 `PRIVATE_DIAGNOSTIC_TOKENS` |
| 4a. test_tactical_ppo | ✅ PASS 7/7 |
| 4b. CUDA micro-update | ✅ PASS |

Python unit 14 个全部是 reorg 引发的路径错位（不是 03- §5 的修复方向组）：test_baseline_audit × 3、test_web_preview_lifecycle × 4、test_web_preview_server × 5、test_web_preview_package × 1、test_archive_pre_draw_fix_runs × 1。

**用户决策**：
- Python unit → 改测试文件 path（仅 path 变更，不动逻辑）。
- Protocol smoke → 隐藏：从 diagnostics 抹掉（改 Godot 白名单）。

**修复**：

| 文件 | 改动 |
|---|---|
| `tests/unit/test_baseline_audit.py` | `training/core/encoding.py` → `training/encoding.py`（audit 期望的旧路径）；去掉 fixture 里的 `scripts/agents/hybrid` |
| `tests/unit/test_web_preview_lifecycle.py` | `scripts/linux/web_preview.sh` → `scripts/ops/web_preview.sh` |
| `tests/unit/test_web_preview_server.py` | `scripts/linux/web_preview_server.py` → `scripts/ops/web_preview_server.py` |
| `tests/unit/test_web_preview_package.py` | `training/package_server_bundle.py` → `training/server/package_server_bundle.py` |
| `tests/unit/test_archive_pre_draw_fix_runs.py` | fixture 从 `training/artifacts/runs/...` → `training/runs/...`（匹配 `archive_pre_draw_fix_runs.py:42` 的硬编码） |
| `scripts/rl/environment_bridge.gd` | `SAFE_DIAGNOSTIC_FLOAT_FIELDS` 去掉 `reserve_ratio`；`SAFE_DIAGNOSTIC_STRING_FIELDS` 去掉 `reserve_basis` |
| `tests/unit/tactical_training_protocol_test.gd` | 去掉 `_test_nested_private_diagnostics_are_removed` 里要求 reserve_basis/reserve_ratio 保留的断言（与新 policy 一致） |

**修复后**：

| 组 | 结果 |
|---|---|
| 1a. Godot unit | ✅ PASS |
| 1b. Static check | ✅ PASS |
| 2. Python unit | 🟡 80 pass / 5 fail（从 71/14 改善） |
| 3. Protocol smoke | ✅ PASS |
| 4a. test_tactical_ppo | ✅ PASS 7/7 |
| 4b. CUDA micro | ✅ PASS |

**5 个剩余 Python 失败**：
- `test_baseline_audit.test_live_project_contract_passes` —— `baseline_audit.py:55-58` 仍硬编码读 `training/encoding.py`（已移到 `training/core/encoding/` 包）。用户决定"不动 baseline_audit" → 留作下一轮 TDD 专项。
- `test_baseline_audit.test_cli_output_creates_parent_directory` —— 同上根因（对真实 ROOT 跑 audit）。
- `test_web_preview_package.test_server_bundle_includes_discoverable_web_preview_entrypoints` —— `training/server/package_server_bundle.py` 打包白名单不包含 `scripts/ops/...`（packager 代码问题，不在"测试 path 改"范围）。
- `test_web_preview_lifecycle.test_failed_start_preserves_state_replaced_by_another_process` + `test_start_rejects_an_occupied_port_even_when_it_returns_http_success` —— 单独跑 OK（6/6 ok）；与别的一起跑 flaky（端口占用 / PID 文件残留）；非 path 问题。

**已知副作用**：`reserve_basis` / `reserve_ratio` 从 SAFE 白名单抹掉后，Python trainer 的 `reserved_energy_by_basis` 与 `map_reserved_energy_by_basis` 计数器将收到空 dict——意味着阶段 1 的硬门槛 #6 "reserve basis 至少 3 个非零" 未来跑新数据会失守。需要 follow-up plan：在 environment_bridge 里加 server-only diagnostic 通道（如 `tactical_diagnostics_private`），让 Python trainer 能读到但不发给 player。

**Commit**：`4471753 fix(tests,protocol): stage 2 TDD follow-up after repository reorganization`（7 files / +15 / −20）。

## 阶段 3：8 卡并行 pilot（按 04- §3.2）

### GPU 等待

启阶段 3 前查 GPU：8 张全被同用户的另一项目占满（`/data1/yanjie/diffusion/self-evolving-vlm/qwen-cc-opd/outputs/0816-sol/`，8 个 `train_qwen_cc_opd.py` 进程，`max_train_batches=90`，开始于 21:58，~78GB / 80GB 每张）。等它跑完—— Monitor `bg5hdmifr` 挂着。等了约 30 分钟 GPU 归零，进程结束。

### 第一次启动失败（配置 bug）

```
[Errno 2] No such file or directory:
  '/data/mogoo7zn/PulseArena/training.pipelines.train_pipeline'
```

所有 11 个 `training/configs/multi_gpu/*.json` 的 command 字段里 `{root}/training.pipelines.train_pipeline` 是 reorg 时改错的——点路径不是文件路径，Python 找不到。批量修复为 `{root}/training/pipelines/train_pipeline.py`：

```bash
for f in training/configs/multi_gpu/*.json; do
  sed -i 's|{root}/training\.pipelines\.train_pipeline|{root}/training/pipelines/train_pipeline.py|g' "$f"
done
```

修完 dry-run 正确（`/data/mogoo7zn/PulseArena/.conda/bin/python /data/mogoo7zn/PulseArena/training/pipelines/train_pipeline.py ...`），提交 `b5d2ca0 fix(configs): restore multi_gpu command path after train_pipeline move`（11 files）。

### 第二次启动：8/8 worker returncode=0

8 个 worker（GPU 0..7 / 端口 8870..8877 / 种子 20260801..20260808）跑 `hybrid_tactical_v2_ppo_pilot` 单 worker plan，每个 512 env_steps / 256 transitions / 4 update / 0 episodes（`01_foundation_combat` / dungeon，20 秒短局）。所有 8 个产物在 `training/artifacts/runs/hybrid_tactical_v2_8gpu_parallel_pilot/gpu{N}/`。

**8 个 worker 数字（rollout_audit 汇总）**：

| gpu | transitions | raw_step | fallback | dec_gen_consistent | fire_intent | fire_authorized | cover_entry / reengage |
|---|---|---|---|---|---|---|---|
| 0 | 256 | 0 | 28 | true | 232 | 0 | 16 / 7 |
| 1 | 256 | 0 | 45 | true | 234 | 1 | 22 / 5 |
| 2 | 256 | 0 | 25 | true | 237 | 0 | 16 / 10 |
| 3 | 256 | 0 | 31 | true | 225 | 0 | 17 / 5 |
| 4 | 256 | 0 | 34 | true | 229 | 0 | 18 / 3 |
| 5 | 256 | 0 | 30 | true | 238 | 0 | 9 / 4 |
| 6 | 256 | 0 | 34 | true | 224 | 0 | 13 / 5 |
| 7 | 256 | 0 | 24 | true | 233 | 0 | 19 / 8 |

✅ 8/8 worker `raw_step_calls=0`、`decision_generation_consistent=true`。

### Import 8 个 candidate（fix ROOT 第二次）

第一次 import 把 manifest 写到 `training/training/models/`（错的，doubled 路径）—— `training/server/import_trained_model.py` 同样有 `parents[1]` 应是 `parents[2]` 的 ROOT bug。批量修：

```bash
# 修 5 个脚本的 ROOT
sed -i 's|parents\[1\]|parents[2]|' training/server/{import_trained_model,package_server_bundle,estimate_resources}.py
sed -i 's|parents\[1\]|parents[2]|' training/pipelines/run_stage.py
sed -i 's|parents\[1\]|parents[2]|' training/evaluation/evaluate_tactical_candidate.py
```

`baseline_audit.py:135` 同样有 ROOT bug，但用户决定"不动 audit"，保留作为 follow-up。

修完 import 正确写到 `training/models/hybrid_tactical_v2_8gpu_gpu{N}_20260816_agent.json` + `training/checkpoints/hybrid/hybrid_tactical_v2_8gpu_gpu{N}_20260816.pt`。提交 `aeb8d04 fix(training): bump ROOT to parents[2] in 5 scripts after reorg`（5 files）。

### Eval smoke（验证 eval pipeline）

跑一个 eval（gpu0 candidate，30 秒一局）验证 pipeline 端到端：

```bash
PYTHONPATH=. MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python training/evaluation/evaluate_tactical_candidate.py \
    --manifest training/models/hybrid_tactical_v2_8gpu_gpu0_20260816_agent.json \
    --output-dir training/artifacts/runs/evaluations/hybrid_tactical_v2_8gpu_gpu0_smoke_$(date +%Y%m%d) \
    --godot "$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64" \
    --runner godot-service \
    --split dev \
    --max-jobs 1 \
    --seconds 30 \
    --port-start 18970 \
    --model-port-start 18980
```

结果：
- `result: "fail"` —— `win_rate: 0.0`、`top1_rate: 0.0`、`scripted_hard_all_maps_win_rate_1v1: 0.0`
- `gate_summary.failed`：scripted_hard_all_maps_min_win_rate_1v1 不达标
- 但 `service_backed_match: 1.0`、`paired_baseline_match: 1.0`、`safety_override_rate: 0.0`、`matches_completed: 1.0` —— 链路本身通了
- `fire_blocked_rate: 0.908`（全是 HOLD_FIRE，scripted teacher 极保守）

**预期之内**：per-worker 计划 `hybrid_tactical_v2_ppo_pilot` 只跑 256 env_steps / 无 BC warm-start / 单 dungeon map，candidate 一定打不过 `hybrid_tactical_v1` baseline。foundation pilot 设计如此——plan §3.5 "8 个 candidate 全不过 gate → 回到阶段 1 重新跑 diagnostic"。

### 阶段 3 验收门槛（按 04- §3.4）

| 门槛 | 结果 |
|---|---|
| 8 worker 全部 `returncode=0` | ✅ |
| 每 worker `raw_step_calls == 0` | ✅ |
| 至少 1 candidate 通过 gate | ❌（8/8 fail） |
| `model_catalog.json` 默认未自动变更 | ✅ 仍 `hybrid_tactical_v1` |

**阶段 3 基础设施部分（multi_gpu orchestrator + protocol-v2 worker + eval pipeline）通过**——但 candidate promotion 需要回阶段 1 用更强的 plan（建议 `tactical_legal_window_pressure_four_map_ballistic_repair` 跑 8 次而非 foundation pilot），那是后续阶段的方向。

### 阶段 3 顺手做的清理

- 删 3938 `.pyc` + 589 `__pycache__/`（gitignored，自动再生）
- 删错位 import 产物 `training/training/{models,checkpoints}/`
- 删 test artifact `hybrid_tactical_v2_8gpu_gpu0_TEST{,_FIX}_*`

### 阶段 3 重做 + 阶段 4/5/6 推进（按用户"修复问题后自动进入 4-6 阶段"）

#### 问题修复

| 问题 | 修复 |
|---|---|
| TDD 5 个 follow-up | `baseline_audit.py` ROOT + 路径常量、`test_baseline_audit` fixture 路径、`web_preview_package` 隐式修（packager ROOT 修了）—— 全绿 |
| `evaluate_tactical_candidate.py` 不带 `--godot` 报 [Errno 2] | 命令补全（plan §3.3 示例漏写） |
| `hybrid_tactical_v2_8gpu_parallel_pilot` per-worker plan 太弱（256 env_steps / foundation）| 新建 `legal_window_pressure_ballistic_repair_8gpu`（16384 env_steps × 8 卡，4 张地图，BC warm-start） |
| 6 个 ROOT `parents[1]` 应是 `parents[2]` | `import_trained_model.py`、`package_server_bundle.py`、`estimate_resources.py`、`pipelines/run_stage.py`、`evaluate_tactical_candidate.py`、`baseline_audit.py`（前 5 个已修，audit 在这一轮也修了） |

测试结果（5 组）：
- 1a. Godot unit: PASS
- 1b. Static check: PASS
- 2. Python unit: 92/92（85 原有 + 7 新增 strength profile）
- 3. Protocol smoke: PASS
- 4. CUDA micro: PASS

#### 阶段 3 重做（8 卡 ballistic_repair）

```bash
PYTHONPATH=. MPLCONFIGDIR="$PWD/test-results/matplotlib" .conda/bin/python -u training/pipelines/train_pipeline.py \
  --profile full_distributed_league --plan legal_window_pressure_ballistic_repair_8gpu \
  --phase ppo-multi --execute
```

8/8 worker `returncode=0`：
- env_steps=4270..4273, raw_step_calls=0, fallback_count=0..1, decision_gen_consistent=true
- 每卡 4 张地图都有 episodes（dungeon:2, sky_city:1, jungle:1, mist_world:1）
- fire_intent 604..1007 / fire_allowed 8..22

#### 阶段 4：paired eval + 注册

8 个 candidate 都 import 到 `training/models/hybrid_tactical_v2_ballistic_repair_gpu{N}_20260816_agent.json`，8 份 manifest + 8 份 checkpoint。

| gpu | holdout win_rate | top1_rate | safety_override | fallback |
|---|---|---|---|---|
| 0 | **1.0** | **1.0** | 0.0916 | 0.0 |
| 1 | **1.0** | **1.0** | 0.0601 | 0.0014 |
| 2 | **1.0** | **1.0** | 0.0358 | 0.0014 |
| 3 | **1.0** | **1.0** | 0.0100 | 0.0014 |
| 4 | 0.0 | 0.0 | 0.0486 | 0.0 |
| 5 | 0.0 | 0.0 | 0.0358 | 0.0014 |
| 6 | **1.0** | **1.0** | 0.0658 | 0.0 |
| 7 | **1.0** | **1.0** | 0.0429 | 0.0 |

6/8 通过 holdout；选 **gpu2**（safety_override=3.58%，中等活跃度）注册成 `hybrid_tactical_v2_promoted_20260816`，`--update-catalog` 但 `promoted_default=false`——human eval gate 待补（plan §4.5 要求 ≥5 玩家 / ≥0.7 接受率；当前没有玩家数据）。

catalog 现状：`default=hybrid_tactical_v1`，`models=4`（`hybrid_tactical_v1`、`v2_ppo_expanded_candidate_20260802`、`v2_ppo_resume_candidate_20260802`、`v2_promoted_20260816`）。

#### 阶段 5：强度分层（5 档）

**Sampler**（`training/core/ppo/sampling.py`）：
- 加 `STRENGTH_PROFILES`（5 档温度/mask_soften/safety_threshold 表）
- `resolve_strength_profile(strength_or_None)` → dict
- `sample_with_strength_profile(outputs, masks, strength)` 包装
- `sample_masked_tactical_actions(..., temperature=1.0, mask_soften=0.0)` 加可选参数（默认 1.0/0.0，老路径不变）
- `_masked_distribution` 加 temperature/mask_soften 应用

测试：`tests/unit/test_sampler_strength_profile.py` 7/7 PASS（默认值 / 未知值抛错 / 严格单调 / entropy 排序 / 默认 temperature=1 / normal 文档值 / temperature 升降 entropy）。

**5 档 manifest**（同一份 checkpoint，5 个不同 model_id）：
- `hybrid_tactical_v2_promoted_easy_20260816` T=1.6 / soften=0.30 / safe=0.55
- `hybrid_tactical_v2_promoted_casual_20260816` T=1.1 / soften=0.20 / safe=0.65
- `hybrid_tactical_v2_promoted_normal_20260816` T=0.85 / soften=0.10 / safe=0.75（默认）
- `hybrid_tactical_v2_promoted_strong_20260816` T=0.55 / soften=0.05 / safe=0.85
- `hybrid_tactical_v2_promoted_elite_20260816` T=0.25 / soften=0.0 / safe=0.95

import_trained_model.py 加 `--strength-profile` 标志，把 strength 写进 manifest 的 `inference_profile` 块。

catalog `models=9`（4 + 5 档）。`default_model_id` 仍 `hybrid_tactical_v1`。

**未做**：Godot 菜单 5 档 UI（plan §3.3）—— `scripts/app/main_menu.gd` 加难度选项、`MatchConfig` 加 `difficulty` 字段、`remote_agent_controller.gd` 透传 strength profile。**未做原因**：Godot 端改动不在本轮范围（plan README §1 "不修改业务代码"）。

#### 阶段 6：持续学习闭环（骨架）

`training/evaluation/human_eval_harness.py`：
- `record_gameplay_as_replay` — 把人对局转 `hybrid_replay_v2` JSONL
- `replay filter` — 质量门（min_game_duration=30s、drop fallback-only）
- `strength_tier_monitor` — 7 天滑窗胜率 + 单调性检测 + 目标区间偏离检查

`strength_tier_monitor` CLI：
```bash
.conda/bin/python training/evaluation/human_eval_harness.py \
  monitor --log-dir training/artifacts/human_eval \
  --output training/artifacts/runs/continual/tier_suggestion_$(date +%Y%m%d).json
```

**未做**：
- 真实玩家对局数据（计划要求 ≥3 tester、≥50 局/档、≥10 局/图）
- `training/continual/build_continual_replay.py`（合并脚本）
- `training/continual/apply_tier_adjustment.py`（自动调节应用）
- 每周日 03:00 持续 BC 重训

**未做原因**：闭环需要真实玩家数据，没有玩家就没法验证。

#### 当前 commit

```text
2aa7d3f feat(stage 4): register hybrid_tactical_v2_promoted_20260816 as non-default candidate
e92ed52 ...（略）
```
