# 5 档强度分层 + 真人录入

## 启动顺序

3 个进程：Godot training server + serve_agent + 游戏客户端。任意顺序启动都可以，建议先起 server 和 serve_agent，再起 Godot 客户端。

```bash
# 终端 1：Godot training server（已经在跑训练时占用 18961-18968 范围；本机玩家用 18766 起步）
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
    --headless --disable-crash-handler --path . \
    -- --training-server --port=18766

# 终端 2：serve_agent（Python inference server）
PYTHONPATH=. .conda/bin/python -u training/inference/serve_agent.py \
  --catalog training/models/model_catalog.json \
  --port 8766 --device cuda

# 终端 3：Godot 客户端（带 UI 的主菜单）
HOME="$PWD/.tools/godot-user" \
  .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 \
    --path .
```

主菜单的右侧 **Agent Difficulty** 现在是 5 档（easy / casual / normal / strong / elite），选哪档会自动把 **Agent Model** 切到对应的 `hybrid_tactical_v2_promoted_<档>_<日期>`。默认 `normal`。

## 模型 ↔ 推理参数（同一份 checkpoint）

| 档位 | model_id | temperature | mask_soften | safety_threshold |
|---|---|---|---|---|
| easy | `hybrid_tactical_v2_promoted_easy_20260816` | 1.6 | 0.30 | 0.55 |
| casual | `hybrid_tactical_v2_promoted_casual_20260816` | 1.1 | 0.20 | 0.65 |
| normal（默认） | `hybrid_tactical_v2_promoted_normal_20260816` | 0.85 | 0.10 | 0.75 |
| strong | `hybrid_tactical_v2_promoted_strong_20260816` | 0.55 | 0.05 | 0.85 |
| elite | `hybrid_tactical_v2_promoted_elite_20260816` | 0.25 | 0.0 | 0.95 |

D2 门：5 档严格单调（温度降、mask_soften 降、safety 升）。已用 `tests/unit/test_sampler_strength_profile.py` 测过。

## 真人录入的位置与格式

每局一旦玩家人数 ≥1 且对手不是 scripted，`HumanEvalRecorder`（autoload）会开一个 JSONL 文件：

```
training/data/replays/human_eval_continual/<YYYY-MM-DD_HH-MM-SS>_<map_id>_s<seed>.hybrid_v2.jsonl
```

例如：

```
training/data/replays/human_eval_continual/2026-08-17_22-13-05_dungeon_s1234567.hybrid_v2.jsonl
```

每行一个 step：

```json
{
  "schema_version": 2,
  "replay_schema": "hybrid_replay_v2",
  "episode_id": "2026-08-17_22-13-05_dungeon_s1234567",
  "match_id": "2026-08-17_22-13-05_dungeon_s1234567",
  "player_id": 0,
  "map_id": "dungeon",
  "mode_id": 0,
  "difficulty": "normal",
  "timestamp": 1755459185.123,
  "step_index": 47,
  "action": {"move_x": ..., "move_y": ..., "aim_x": ..., "aim_y": ..., "shoot": false, "dash": true, "shield": false, ...},
  "observation": {...},
  "outcome": {},
  "label_source": "human_playthrough",
  "teacher_label_version": "human_eval_v1",
  "label_weight": 1.0
}
```

文件路径可在 MatchConfig 里覆盖：`human_eval_replay_dir = "..."`（不填就用 `training/data/replays/human_eval_continual/`）。

> ⚠️ `replay_dir` 在 `.gitignore` 里——这些是玩家数据，不会被 commit。

## 用录入数据做持续学习（阶段 6）

跑命令筛 + 重训：

```bash
# 质量门：去掉 30s 内死亡的去局、去掉纯 fallback 的局
.conda/bin/python training/evaluation/human_eval_harness.py \
  filter \
    --input-dir training/data/replays/human_eval_continual \
    --output-dir training/data/replays/human_eval_continual_filtered \
    --min-game-duration 30 \
    --drop-fallback-only

# 看当前 7 天滑动窗口的 5 档胜率
.conda/bin/python training/evaluation/human_eval_harness.py \
  monitor \
    --log-dir training/artifacts/human_eval \
    --output training/artifacts/runs/continual/tier_suggestion_$(date +%Y%m%d).json
```

持续 BC 闭环的脚本结构（`docs/plan/06-持续学习闭环.md` §3）已 ready，但目前没真实玩家数据所以只跑骨架。

## 出问题怎么办

| 现象 | 处理 |
|---|---|
| 主菜单找不到 5 档 | 看 console：catalog 加载失败。检查 `training/models/model_catalog.json` 是否能被 Godot 读取（路径用 `res://training/models/...`） |
| 模型动作很怪 / 不响应 | 检查 `serve_agent` 日志里的 `strength_profile echo` 是否和菜单选的一致；不一致说明 `MatchConfig.agent_difficulty` 没传过去 |
| 录到了空文件 | 玩家人数必须 ≥1 + 对手不能 scripted。solo scripted 训练局不录 |
| 想换录到的目录 | MatchConfig.human_eval_replay_dir 设个绝对路径 |
