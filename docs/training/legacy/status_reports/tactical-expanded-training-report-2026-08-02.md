# 高层策略扩大训练结果报告

日期：2026-08-02（Asia/Shanghai）

## 当前接入游戏的 Hybrid Tactical Agent

当前游戏默认接入的 Hybrid Tactical Agent 是：

```text
model_id: hybrid_tactical_v1
kind: hybrid_tactical_prior
manifest: training/models/hybrid_tactical_v1_agent.json
catalog: training/models/model_catalog.json
checkpoint: 空
```

它不是本轮训练出来的 PPO checkpoint。`training/models/model_catalog.json` 的 `default_model_id` 仍是 `hybrid_tactical_v1`。因此未显式指定 `model_id` 的游戏服务请求仍使用 protocol-v2 tactical prior，加上 Godot 侧 deterministic executor、fire gate、safety override 和 scripted fallback。

后续接入修复已把训练 checkpoint 作为 **非默认候选** 加入 catalog，但没有 promotion 默认模型：

```text
hybrid_tactical_v2_ppo_expanded_candidate_20260802
hybrid_tactical_v2_ppo_resume_candidate_20260802
```

最新续训报告见 `docs/training/status/tactical-ppo-resume-expanded-report-2026-08-02.md`。

## 是否值得扩大

结论：**BC warm-start PPO 路线值得继续扩大；随机初始化 PPO 不值得继续扩大；当前仍不应直接晋级到游戏服务。**

判断依据：

- 随机初始化 PPO 的 8 卡 foundation diagnostic 中，fallback rate 是 `17.0078%`，`damage_dealt` 只有 `0.4`；
- BC warm-start 的 8 卡 8192 诊断中，fallback rate 降到 `0.0634%`，`damage_dealt` 提升到 `10.8`；
- 本轮 expanded run 进一步把总量扩大到约 `529,940` env steps 后，fallback rate 降到 `0.0087%`，`damage_dealt` 到 `88.14`，且 `raw_step_calls=0`。

这说明“继续训练”应沿 BC warm-start 路线推进，而不是回到随机 PPO。

## 本轮扩大训练

新增配置：

```text
training/configs/multi_gpu/tactical_8gpu_bc_warmstart_expanded_65536.json
```

执行命令：

```bash
MPLCONFIGDIR="$PWD/test-results/matplotlib" \
.conda/bin/python -m training.multi_gpu_orchestrator \
  --config training/configs/multi_gpu/tactical_8gpu_bc_warmstart_expanded_65536.json \
  --execute
```

输出目录：

```text
training/runs/hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536/
```

每个 `gpu0` 到 `gpu7` 都有：

```text
best_tactical_ppo.pt
last_tactical_ppo.pt
metrics.jsonl
config.json
rollout_audit.json
```

8 个 worker 全部 `returncode=0`。训练结束后 8 张 GPU 显存占用为 `0MiB`，`8766` 与 `8870-8877` 没有残留监听进程。

## 指标对比

| 指标 | 随机 PPO 8192 | BC warm-start 8192 | BC warm-start expanded |
| --- | ---: | ---: | ---: |
| workers | 8 | 8 | 8 |
| env steps | 66,252 | 66,248 | 529,940 |
| PPO updates | 96 | 96 | 384 |
| episodes | 48 | 48 | 384 |
| transitions | 33,126 | 33,124 | 264,970 |
| tactical step calls | 16,563 | 16,562 | 132,485 |
| raw step calls | 0 | 0 | 0 |
| fallback count | 5,634 | 21 | 23 |
| fallback rate | 17.0078% | 0.0634% | 0.0087% |
| safety override count | 403 | 2,432 | 18,435 |
| safety override rate | 1.2166% | 7.3421% | 6.9574% |
| rollout reward sum | 238.28 | 243.52 | 1,950.71 |
| rollout reward mean | 2.4821 | 2.5367 | 5.0800 |
| reward min | -0.24 | -0.24 | 4.52 |
| reward max | 5.0 | 6.4 | 7.0 |
| last reward mean | 5.0 | 5.045 | 5.1 |
| damage dealt | 0.4 | 10.8 | 88.14 |
| damage taken | -0.2 | -7.8 | -60.27 |
| kill | 0.0 | 3.0 | 6.0 |
| death | 0.0 | -2.0 | -4.0 |
| win | 240.0 | 240.0 | 1,920.0 |
| PPO entropy mean | 7.0442 | 0.4958 | 0.4325 |
| PPO approx KL mean | 0.0048 | 0.0027 | 0.0021 |
| PPO value loss mean | 0.5477 | 0.5137 | 0.2313 |

## 结果评析

正向结果：

- fallback 基本被压住：从随机 PPO 的 `17.0078%` 降到 expanded 的 `0.0087%`；
- 交战信号明显增强：`damage_dealt=88.14`，高于上一轮 `10.8`，远高于随机 PPO 的 `0.4`；
- 所有 transition 仍保持 tactical protocol：`raw_step_calls=0`；
- reward 不再有负数/零值 rollout，expanded run 的 `reward_min=4.52`；
- PPO 指标稳定：`approx_kl` 均值 `0.0021`，`clip_fraction` 均值 `0.0455`，没有出现更新爆炸。

风险和阻断：

- `win=1920.0` 仍是主要 reward 来源，dense combat reward 仍不足以单独证明策略质量；
- safety override rate 仍偏高，为 `6.9574%`，说明模型更积极后仍触发较多紧急安全覆盖；
- 当前 8 卡训练是 8 个独立 checkpoint，不是共享 learner、DDP 或 MAPPO；
- 真实 Godot fixed-seed paired-match evaluator 尚未接入，不能做 catalog promotion；
- 没有四图、1v1、FFA、2v2、空枪率、环境死亡率和人工观感评估。

## 是否执行“全量训练”

本轮没有执行 profile 中描述的完整 recurrent MAPPO league 全量训练。

原因是当前仓库的 `full_distributed_league` 只是完整 league 的目标配置，`hybrid_tactical_full` 仍写明“先做 replay warm start；v2 rollout metrics 和 promotion gates 完成后再添加 tactical PPO/MAPPO”。当前已实现的是多任务 8 卡独立 PPO 编排，不是共享 actor/centralized critic 的全量 league learner。

因此，本轮执行的是当前代码可支持、且根据指标值得继续的最大安全扩训：8 卡 BC warm-start PPO expanded run，总计约 `529,940` env steps。它可以作为下一步 evaluator 和更大课程训练的候选输入，但不能伪装成完整 league policy。

## 继续执行建议

继续值得做，但顺序应是：

1. 接入真实 Godot fixed-seed evaluator，先评估 expanded run 的 8 个 checkpoint；
2. 拆解 safety override reason 和 fire block reason，确认 `6.9574%` 是否来自合理避弹；
3. 在 evaluator 通过前，不把任何候选设为 `default_model_id`；
4. 如果 evaluator 显示至少一个 checkpoint 显著优于 `hybrid_tactical_v1`，再启动更长的 BC warm-start curriculum；
5. 真正 full league 需要实现共享 learner / centralized critic / league sampling，不能只靠当前 8 个独立 PPO worker。
