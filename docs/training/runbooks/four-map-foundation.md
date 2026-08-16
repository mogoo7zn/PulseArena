# 四地图可玩性训练运行手册

本路线的共享训练资产位于 `training/data/replays/four_map_foundation_bc/`。每个顶层
`*.jsonl` 是一局可独立审计的 `hybrid_replay_v2` 回放；`quarantine/` 只保存中断或
损坏的文件，训练加载器不会读取它。

在任何 BC 或 PPO warm-start 前，先运行：

```bash
PYTHONPATH=. .conda/bin/python -m training.replay_integrity \
  training/data/replays/four_map_foundation_bc
```

退出码 `0` 才允许训练。输出必须同时满足：

- `invalid_line_count` 为 `0`；
- `schema_row_counts` 仅包含 `hybrid_replay_v2`；
- `map_row_counts` 含 `dungeon`、`sky_city`、`jungle`、`mist_world`，且场数/行数没有明显失衡。

若采集被中断，保留完整文件，将报告中列出的精确文件移至同目录的 `quarantine/`。不要
截断、拼接或手动修补 JSONL；从下一个缺失种子续采，以保持四图轮换可复现。四图循环顺序为
Dungeon → Sky City → Jungle → Mist World。

当前基线目标是每图至少 8 局、60 秒、两名 hybrid 代理。完成后依次执行 BC、单 worker
受限 PPO 诊断，审阅每图的开火授权、资源争夺与地图事件审计；没有通过该诊断前不启动大规模
PPO。

## 高可玩性战斗修复诊断（GPU 4）

`tactical_legal_window_pressure_four_map_repair_diagnostic` 保持原有
`legal_window_pressure` 奖励档，不创建新策略档。它先重新采集四图各 8 局的教师示范，
训练隔离 BC 初始策略，再进行 PPO；这样“受压找掩体、脱险后重新接敌”的修复能进入 PPO
的初始策略，而不是只改执行器。

启动前确认端口 `18945` 未占用，且仅允许 GPU 4：

```bash
CUDA_VISIBLE_DEVICES=4 .conda/bin/python training/pipeline/train_pipeline.py \
  --profile local_constrained \
  --plan tactical_legal_window_pressure_four_map_repair_diagnostic \
  --phase all --execute \
  --output-dir training/artifacts/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4 \
  --port 18945 --seed 20261086
```

完成后审阅 `rollout_audit.json`。只有同时满足下列条件，才允许扩大 PPO：

- `raw_step_calls` 和 `fallback_count` 均为 `0`；
- 四张地图都有非零 `map_episode_counts`；
- `event_counter_consistent` 与 `decision_generation_consistent` 均为 `true`；
- `cover_entry_count`、`cover_reengage_count` 都大于 `0`；
- `authorized_projectile / fire_intent_count` 大于旧探针的 `0.012`；
- `authorized_hit / authorized_projectile` 至少为 `0.25`。

若未通过，按主因修复而非增加 PPO 步数：`no_line_of_sight` 为主时检查侧移找视线；
`reserved_energy` 为主时追踪 `FireControl` 的动态预留；进入掩体但没有重新接敌时检查移动
执行；命中率显著下降时恢复先前射击阈值。
