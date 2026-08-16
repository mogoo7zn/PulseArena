# Pulse Arena 项目结构说明

本文档记录当前 Godot 项目的完整目录职责、核心脚本分工和运行链路，便于后续添加技能、地图、生物、训练逻辑和 UI 时快速定位代码。

## 项目根目录

```text
PulseArena/
├─ project.godot
├─ README.md
├─ LICENSE
├─ assets/
├─ docs/
├─ resources/
├─ scenes/
├─ scripts/
├─ archive/
├─ training/
└─ tests/
```

- `project.godot`：Godot 工程配置。当前主场景是 `res://scenes/app/Main.tscn`，窗口基准尺寸为 `1600x900`，物理 tick 为 `60`。
- `README.md`：项目概览、玩法说明、运行命令和测试命令。
- `LICENSE`：项目许可证。
- `.godot/`、`.godot_user/`、`.godot_user_runtime/`：Godot 生成的编辑器缓存、导入缓存和运行日志目录，不属于核心手写代码。
- `.uid` 文件：Godot 4 为资源生成的稳定标识文件，通常不需要手动编辑。
- `archive/`：历史实验、旧 checkpoint、旧 replay 和报告复现材料。当前训练逻辑不从这里默认读取。
- `training/`：强化学习课程、评测矩阵、资源预估和训练/评测命令入口。

## 自动加载服务

`project.godot` 的 `[autoload]` 注册了以下全局服务：

- `AppLog` -> `scripts/core/app_log.gd`：统一日志入口。
- `GameEvents` -> `scripts/core/game_events.gd`：全局事件总线。
- `ConfigDB` -> `scripts/config/config_db.gd`：集中加载默认平衡表、奖励表和运行配置。
- `AudioManager` -> `scripts/audio/audio_manager.gd`：音频总线与音效播放接口。
- `SettingsManager` -> `scripts/core/settings_manager.gd`：设置保存、读取与应用。
- `GameFlowManager` -> `scripts/core/game_flow_manager.gd`：主菜单、比赛场景和流程切换。
- `InputRegistry` -> `scripts/core/input_registry.gd`：运行时输入动作注册。

## `assets/` 资源目录

```text
assets/
├─ audio/
├─ fonts/
├─ generated/
├─ icons/
└─ shaders/
```

- `assets/icons/pulse_arena.svg`：项目图标。
- `assets/icons/pulse_arena.svg.import`：Godot 导入配置。
- `assets/audio/`：预留音频资源目录。
- `assets/fonts/`：预留字体资源目录。
- `assets/generated/`：生成类美术或音效资源目录。
- `assets/shaders/`：预留 shader 资源目录。

## `resources/` 数据资源目录

```text
resources/
├─ configs/
├─ maps/
└─ themes/
```

- `resources/configs/default_balance.tres`：默认数值平衡表，对应 `GameBalance`。
- `resources/configs/default_rewards.tres`：默认强化学习奖励配置，对应 `RewardConfig`。
- `resources/maps/arena_cross.json`：地图数据示例或外部地图配置入口。
- `resources/themes/pulse_theme.tres`：UI 主题资源。

## `scenes/` 场景目录

```text
scenes/
├─ app/
├─ arena/
├─ debug/
├─ gameplay/
├─ menu/
└─ ui/
```

### `scenes/app/`

- `Main.tscn`：项目主场景，承载主菜单与比赛流程入口。
- `Bootstrap.tscn`：启动辅助场景，用于初始化全局环境。

### `scenes/arena/`

- `ArenaRoot.tscn`：对战主场景，挂载 `ArenaRoot`。
- `ArenaCross.tscn`：地图容器场景，挂载 `ArenaCross`。
- `SpawnPoint.tscn`：出生点标记场景。

### `scenes/gameplay/`

- `Player.tscn`：玩家实体场景。
- `Projectile.tscn`：子弹实体场景。
- `Pickup.tscn`：地面拾取物场景。
- `ImpactEffect.tscn`：命中效果。
- `RespawnEffect.tscn`：复活效果。
- `ShieldEffect.tscn`：护盾效果。

### `scenes/menu/`

- `MainMenu.tscn`：主菜单。
- `ModeSelect.tscn`：模式选择。
- `MatchSetup.tscn`：比赛配置。
- `SettingsMenu.tscn`：设置菜单。
- `AboutMenu.tscn`：关于页面。

### `scenes/ui/`

- `GameHUD.tscn`：对战 HUD。
- `PlayerStatusCard.tscn`：玩家状态卡片。
- `Scoreboard.tscn`：比分面板。
- `PauseMenu.tscn`：暂停菜单。
- `MatchResult.tscn`：结算界面。
- `AgentBadge.tscn`：智能体标识组件。

### `scenes/debug/`

- `DebugOverlay.tscn`：调试覆盖层。
- `AgentObservationViewer.tscn`：智能体观测查看器。

## `scripts/` 脚本目录

```text
scripts/
├─ agents/        # hybrid tactical agent (decision + deterministic executors)
├─ app/           # bootstrap + main
├─ arena/         # arena controllers + per-map rules
├─ audio/         # audio bus manager
├─ config/        # balance / match / reward / difficulty configs
├─ controllers/   # player controllers (human, agent, replay, ...)
├─ core/          # events, flow, input, match, score, settings
├─ debug/         # debug overlays (F3 / canvas DEBUG button)
├─ gameplay/      # player, projectile, visual helpers
├─ ops/           # shell scripts: bootstrap, export, web preview
├─ replay/        # JSONL replay recorder
├─ rl/            # action, observation, environment bridge, reward
└─ ui/            # HUD, menu, status card
```

### `scripts/app/`

- `main.gd`：主应用节点，协调主菜单、HUD、对战场景和训练启动参数。
- `bootstrap.gd`：启动阶段的基础初始化脚本。

### `scripts/core/`

- `app_log.gd`：日志服务。
- `game_events.gd`：事件总线，负责跨模块信号广播。
- `game_flow_manager.gd`：游戏流程控制，例如进入比赛、返回主菜单。
- `input_registry.gd`：动态注册玩家输入动作。
- `match_manager.gd`：单局计时、比赛状态和结束判断。
- `score_manager.gd`：比分、击杀、死亡和伤害统计。
- `settings_manager.gd`：设置文件读写与应用。
- `spawn_manager.gd`：出生点、安全出生位置和重生位置选择。
- `team_rules.gd`：队伍关系与友伤规则。

### `scripts/config/`

- `game_balance.gd`：核心数值表，包含玩家、子弹、道具、地图和技能参数。
- `match_config.gd`：比赛模式配置，包括玩家数量、队伍、地图和训练参数。
- `reward_config.gd`：强化学习奖励参数。
- `agent_difficulty_config.gd`：脚本 AI 难度参数。
- `config_db.gd`：配置加载服务，向运行时提供默认资源。

### `scripts/arena/`

- `arena_root.gd`：对战主控制器，创建玩家、子弹、道具和地图，推进比赛循环。
- `arena_cross.gd`：地图容器与地图规则桥接层。
- `spawn_point.gd`：出生点标记脚本。
- `map_rules/map_rule_base.gd`：地图规则基类。
- `map_rules/dungeon_rule.gd`：地牢地图，维护牢笼陷阱、砖石环境和地形碰撞。
- `map_rules/sky_city_rule.gd`：天空之城地图，维护移动屏障、虚空陷阱和高空表现。
- `map_rules/jungle_rule.gd`：丛林地图，维护沼泽、伪装、蟒蛇和树丛障碍。
- `map_rules/mist_world_rule.gd`：迷雾地图，维护视野遮蔽、虫洞传送和暗色特效。

### `scripts/gameplay/`

- `player.gd`：玩家实体，处理移动、射击、受击、表情、技能状态和死亡复活。
- `projectile.gd`：子弹实体，处理飞行、命中、寿命和绘制。
- `pickup.gd`：地面道具实体，绘制图标并处理过期表现。
- `simple_effect.gd`：轻量一次性视觉效果。
- `camera_effects.gd`：摄像机抖动与冲击反馈。
- `combat_feedback_controller.gd`：伤害数字、命中提示和击杀反馈。
- `character_animation_controller.gd`：角色动画状态和表情过渡控制。
- `character_renderer.gd`：角色身体、轮廓、表情和状态绘制。
- `projectile_renderer.gd`：子弹核心、尾迹和命中特效绘制。
- `weapon_renderer.gd`：武器朝向和枪口表现。
- `world_health_bar.gd`：世界空间血条绘制。

### `scripts/controllers/`

- `player_controller.gd`：控制器基类，统一动作输出接口。
- `human_controller.gd`：本地键鼠/手柄控制。
- `scripted_agent_controller.gd`：脚本 AI 行为控制。
- `model_agent_controller.gd`：protocol v1 raw-action 兼容控制器，通过本地 JSONL TCP 推理服务输出动作；当前不作为默认训练/菜单路径。
- `hybrid_agent_controller.gd`：Hybrid Tactical Agent 控制器，通过 protocol v2 获取高层决策，失败时回退 Scripted Hard，并调用确定性执行器输出 `PlayerAction`。
- `onnx_agent_controller.gd`：旧引用兼容别名，实际走 protocol v1 `model_agent_controller.gd`。
- `remote_agent_controller.gd`：远程训练或外部进程动作输入。
- `replay_controller.gd`：回放帧驱动的控制器。

### `scripts/rl/`

- `agent_observation.gd`：智能体观测数据结构。
- `observation_builder.gd`：将比赛状态编码为智能体观测。
- `visibility_filter.gd`：按视野和地图规则过滤可观测对象。
- `player_action.gd`：动作数据结构。
- `reward_calculator.gd`：训练奖励计算。
- `environment_bridge.gd`：Godot 与外部训练环境的桥接。
- `training_runner.gd`：头less 自动对局和训练 smoke 运行入口。

### `scripts/agents/`

- `tactical_decision.gd`：版本化高层动作 schema 和 action mask 修正。
- `tactical_feature_builder.gd`：v2 tactical features 和 action masks。
- `ballistic_aim_solver.gd`：解析式提前瞄准和 LOS/撞墙/友伤检查。
- `fire_control.gd`：确定性射击门控、能量保留和 burst 状态。
- `projectile_threat_analyzer.gd`：子弹威胁和躲避候选评估。
- `movement_executor.gd`：移动意图到 `move` 向量转换。
- `cover_analyzer.gd`：掩体、安全空间和墙体距离分析。
- `stuck_recovery.gd`：防卡墙和角落震荡恢复。
- `hybrid_combat_executor.gd`：低层执行器总线，最终输出 `PlayerAction`。
- `hybrid_agent_config.gd`：v2 schema 和执行器阈值配置。

### `scripts/ui/`

- `main_menu.gd`：主菜单交互逻辑。
- `game_hud.gd`：对战 HUD、状态刷新、暂停和结算菜单。
- `player_status_card.gd`：玩家状态卡片。
- `pulse_background.gd`：菜单背景动效。
- `simple_page.gd`：简单页面基类。
- `ui_tokens.gd`：UI 颜色、间距和样式令牌。

### `scripts/audio/`

- `audio_manager.gd`：音频管理服务，封装总线音量和音效播放。

### `scripts/replay/`

- `replay_manager.gd`：比赛输入帧记录、序列化和恢复。

### `scripts/debug/`

- `debug_overlay.gd`：调试信息覆盖层。
- `agent_observation_viewer.gd`：AI 观测向量可视化。

## `docs/` 文档目录

- `README.md`：文档总入口。
- `architecture/overview.md`：架构概览。
- `game/design.md`：玩法设计说明。
- `design/ui.md`：UI 设计说明。
- `agents/interface.md`：智能体接口说明。
- `training/strategy.md`：正式 agent 训练路线、阶段和资源预估。
- `training/status/tactical-rl-progress.md`：高层战术 RL 当前进度。
- `game/skills.md`：地面道具和技能清单。
- `operations/project-structure.md`：当前项目结构说明。

## `training/` 训练目录

```text
training/
├─ pipeline/       # 入口：run_stage.py + train_pipeline.py
├─ evaluation/     # baseline_audit.py + evaluate_tactical_candidate.py
├─ model_io/       # import_trained_model.py + migrate_legacy_checkpoint.py
├─ orchestration/  # multi_gpu_orchestrator.py + package_server_bundle.py + estimate_resources.py
├─ inference/      # serve_agent.py + model_runtime.py + diagnose_policy.py
├─ rl/             # 算法与 replay 编码（tactical_ppo、tactical_bc_trainer、tactical_online_trainer、encoding、godot_env、models、replay_integrity、swanlab_utils、league）
├─ server_agent/   # preflight、prepare_hybrid_replays、audit_hybrid_replays、tactical_data_quality
├─ tools/          # 历史归档脚本（archive_pre_draw_fix_runs.py）
├─ configs/        # 训练计划、profile、奖励、GPU 资源、multi_gpu、local_settings
├─ models/         # model_catalog.json + 候选 agent manifest
├─ data/           # 输入：replays / incoming_models / experiments
├─ artifacts/      # 输出：runs / checkpoints / packages / godot_user
└─ server_train_hybrid_tactical_v2.sh
```

- `training/configs/curriculum.json`：完整课程阶段，从基础战斗到人类评测微调。
- `training/configs/evaluation_matrix.json`：固定评测地图、种子、对手和晋级门槛。
- `training/configs/gpu_resource_estimate.json`：GPU、CPU、内存和预计训练时长。
- `training/configs/training_plans/hybrid_tactical_local.json`：默认本地 Hybrid Tactical 训练计划。
- `training/configs/training_plans/hybrid_tactical_full.json`：默认服务器 Hybrid Tactical 训练计划。
- `training/inference/serve_agent.py`：v2 tactical 推理服务。
- `training/models/model_catalog.json`：当前活动模型目录，只保留可用于默认入口的模型。
- `training/data/replays/`：新采集的 `hybrid_replay_v2` replay 输出目录。
- `training/rl/tactical_bc_trainer.py`：高层 tactical decision 行为克隆训练器。
- `training/pipeline/run_stage.py`：生成或执行 Godot headless 阶段 smoke 命令。
- `training/pipeline/train_pipeline.py`：统一训练流水线入口，负责 validate/collect/bc/ppo 阶段调度。
- `training/orchestration/estimate_resources.py`：汇总训练步数和显卡资源档位。
- `training/README.md`：训练目录使用说明。

## `tests/` 测试目录

```text
tests/
├─ integration/
├─ smoke/
├─ unit/
└─ run_tests.gd
```

- `tests/run_tests.gd`：Godot 集成测试入口。
- `tests/smoke/static_project_check.py`：不依赖 Godot 的静态项目检查。
- `tests/smoke/run_headless_smoke.sh`：Linux 无头 smoke 启动脚本。
- `tests/smoke/map_build_check.gd`：地图构建 smoke 测试。
- `tests/smoke/hud_layout_check.gd`：HUD 布局 smoke 测试。
- `tests/smoke/camera_fit_check.gd`：摄像机适配 smoke 测试。
- `tests/integration/README.md`：集成测试目录说明。
- `tests/unit/README.md`：单元测试目录说明。

## 主要运行链路

1. Godot 读取 `project.godot`，创建自动加载服务。
2. 主场景 `scenes/app/Main.tscn` 启动 `scripts/app/main.gd`。
3. 普通模式进入 `MainMenu`，玩家选择地图和模式后创建 `ArenaRoot`。
4. 训练或 smoke 模式通过命令行参数创建 `TrainingRunner`，由 runner 按阶段和局数创建 `ArenaRoot`。
5. `ArenaRoot` 加载 `GameBalance`、`MatchConfig`、`RewardConfig`，创建 `MatchManager`、`ScoreManager`、`SpawnManager`。
6. `ArenaRoot` 创建 `ArenaCross`，`ArenaCross` 根据地图 ID 挂载对应 `MapRuleBase` 子类。
7. `ArenaRoot` 创建玩家控制器、玩家实体、HUD、反馈控制器和地图规则。
8. 每个物理帧中，比赛按“控制器输入 -> 玩家更新 -> 道具更新 -> 延迟脉冲 -> 子弹更新 -> 地图规则更新 -> HUD 节流刷新”的顺序推进。
9. 比赛结束后，`GameHUD` 显示结算与返回菜单入口，`GameFlowManager` 负责回到主菜单。

## 地图扩展入口

新增地图通常需要同时处理以下位置：

- 在 `MatchConfig` 或菜单地图列表中添加地图 ID。
- 在 `ArenaCross` 中创建并挂载新的 `MapRuleBase` 子类。
- 在 `scripts/arena/map_rules/` 下新增地图规则脚本。
- 在地图规则中实现安全点判定、障碍查询、绘制逻辑和特殊机制。
- 如果地图机制影响 AI 观测，需要同步检查 `ObservationBuilder` 与 `VisibilityFilter`。

## 道具与技能扩展入口

新增地面道具通常需要同时处理以下位置：

- `GameBalance`：新增持续时间、数值、范围、权重等参数。
- `ArenaRoot`：加入道具类型、生成权重、拾取效果和持续更新逻辑。
- `ArenaPickup`：绘制新的图标与颜色。
- `ArenaPlayer`：如果技能会挂在玩家身上，需要新增状态、计时和效果应用。
- `docs/game/skills.md`：同步记录设计规则和当前数值。

## 测试与验证建议

- 改动静态资源、脚本路径或关键字段后，运行 `python tests/smoke/static_project_check.py`。
- 改动地图、道具、玩家或 HUD 后，运行 `tests/smoke/run_headless_smoke.sh`。
- 改动单个地图机制后，用 `godot --headless --path . -- --training --agents=4 --seconds=20 --map=<map_id>` 做定向 smoke。
- 改动 UI 布局后，运行 `godot --headless --path . --script tests/smoke/hud_layout_check.gd`。
