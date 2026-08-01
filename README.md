# Pulse Arena

Pulse Arena is a Godot 4.x 2D top-down projectile arena game and reinforcement-learning environment skeleton. It includes playable human-vs-agent modes, shared action/observation data structures, scripted agents, headless match startup, replay JSONL scaffolding, and focused tests.

## Implemented

- Godot project structure, Autoload services, input registration, settings persistence, audio bus manager interface.
- Modernized main menu with left-side world selection, right-side mode setup, four themed vertical-view arena layouts, in-game HUD, private local status cards, pause menu, result screen, and return-to-menu input.
- 1 Human vs 1 Agent, 1 Human vs 2 Agents, 1 Human vs 3 Agents, and 2 Humans vs 2 Agents configs.
- Movement, mouse aim, keyboard aim for player 2, projectile fire, dash, shield, health, death, respawn, score, timer.
- Procedural upright ghost characters with animated cloth/eye highlights, mouth-fire animation, contact shadow, team ring, world health bar, movement/shoot/hit/death/spawn animation states.
- Projectile cores, short trails, muzzle flashes, wall/player impact audio, generated placeholder SFX, and themed arena rendering with top-down wall thickness, floor textures, spawn pads, and map-specific palettes.
- Unified `PlayerController` interface with human, scripted, remote, ONNX, and replay controllers.
- `PlayerAction`, `AgentObservation`, `ObservationBuilder`, `VisibilityFilter`, `RewardCalculator`, `EnvironmentBridge`, `ReplayManager`.
- Headless startup path for scripted-agent matches.
- Static smoke test and Godot unit-test entry point.

## Not Yet Implemented

Full PPO/MAPPO optimizer implementation, vectorized Godot worker IPC, ONNX inference runtime, networking, final authored art/audio assets, deterministic frame-perfect replay, complex weapons, classes, accounts, store, and online multiplayer.

## Requirements

- Ubuntu 24.04 x86_64 or another modern Linux distribution with glibc 2.35+.
- Godot 4.7 with the Linux export templates installed.
- Python 3.10+ for tests and training tools; training additionally requires
  PyTorch, NumPy, and Matplotlib.
- No external game assets are required.

Create the Linux development environment and install training dependencies:

```bash
make setup
```

`GODOT_BIN` can point to a non-standard Godot binary. Otherwise the scripts
resolve `godot4` and then `godot` from `PATH`.

The full Linux setup, CUDA selection, build workflow, and legacy checkpoint
conversion are documented in [docs/operations/linux.md](docs/operations/linux.md).

## Open And Run

Open this folder in Godot or run:

```bash
godot --path .
```

## Modes

The main menu exposes a left-side map selector and a right-side mode setup panel.

Worlds:

- Dungeon Keep: stone halls, cracked tiles, and torchlit cover.
- Sky City: floating marble platforms, cloud texture, and open sightlines.
- Jungle Ruins: vine-covered blocks, roots, and overgrown rotation paths.
- Mist World: fog bands, dark monoliths, and softer distance reading.

Modes:

- Human vs 1 Agent
- Human vs 2 Agents
- Human vs 3 Agents
- 2 Humans vs 2 Agents, friendly fire off

Free-for-all modes use individual scoring. The 2 Humans vs 2 Agents mode uses team rules and hides friendly fire. Debug/training config supports 4 scripted agents through `MatchConfig.preset_training_ffa_agents()`.

Respawns are sampled randomly from safe map space at runtime, avoiding walls and dynamic blocking obstacles. Fixed spawn lists remain only as fallback data.

## Controls

Player 1:

- WASD: move
- Mouse: aim
- Left mouse: shoot
- Space: dash
- Right mouse: shield
- Esc: pause/resume
- Backspace or HUD Menu: return to menu during a match

Player 2:

- Arrow keys: move
- IJKL: aim
- Right Ctrl: shoot
- Right Shift: dash
- Enter or Numpad 0: shield

## Settings

The in-menu Settings panel writes to `SettingsManager` and persists in `user://settings.cfg`.

- Video: quality label, particle quality, shadows, screen shake, hit flash, damage numbers flag, reduced motion, frame limit.
- Audio: master, SFX, and music bus volumes.
- Controls: mouse sensitivity and gamepad flags in the settings store.
- Accessibility: high-contrast crosshair, color-blind/team-assist flags, reduced flashing, and health bar size.

## Headless

```bash
godot --headless --path . -- --training --matches=1 --agents=4 --seed=1234 --seconds=10 --map=dungeon
```

The current runner starts a single Arena in-process and exits with printed JSON when the match ends. Headless mode sets `config.headless = true`, does not create HUD, combat feedback, particles, or camera shake, and still runs the same physics and combat rules.

Training stages and hardware estimates live under `training/`:

```bash
python training/run_stage.py --list
python training/run_stage.py --stage 01_foundation_combat
python training/estimate_resources.py
```

## Tests

Static smoke check, works without Godot:

```bash
python tests/smoke/static_project_check.py
```

Map build smoke check:

```bash
godot --headless --path . --script tests/smoke/map_build_check.gd
```

Godot tests:

```bash
godot --headless --path . --script tests/run_tests.gd
```

Complete Linux smoke suite:

```bash
make test
```

Build a Linux x86_64 release package:

```bash
make export-linux
```

## Web 网页调试与预览

先使用安装了 **Web export templates** 的 Godot 4.7 导出；若 Godot 不在
`PATH`，可像上文一样设置 `GODOT_BIN`。网页预览只监听服务器本机
`127.0.0.1:8080`，不会暴露训练或推理端口（包括 `8765`、`8766`）。

```bash
make web-export
make web-start
make web-status
make web-stop
```

在远程服务器上使用 Cursor Remote SSH 时，无需另建浏览器 SSH 隧道：在已连接
工作区的 **Ports** 面板转发端口 `8080`，再从本地浏览器打开
`http://127.0.0.1:8080/`。停止预览时执行 `make web-stop`；该命令只会终止由
本项目预览脚本记录并验证过的进程。

网页端的开发调试面板默认隐藏。按 **F3** 或使用画布右上角的 **DEBUG** 控件可
切换它；面板仅显示 FPS、帧耗时、对局状态、地图、剩余时间、玩家/投射物数量和
最多 50 条公开事件。它不包含训练、推理、控制器、策略、私有能量/储备或冷却数据，
也不会建立浏览器网络连接；无头和训练对局不会创建该面板。

## Directory Map

- `assets/`: generated and placeholder assets.
- `scenes/`: app, menu, arena, gameplay, UI, debug scenes.
- `scripts/app`: startup and scene routing.
- `scripts/core`: events, flow, input, rules, score, spawn, settings.
- `scripts/gameplay`: player, projectile, and retained visual helper prototypes.
- `scripts/gameplay/player.gd`, `projectile.gd`: current runtime character/projectile drawing and animation; kept self-contained so gameplay does not depend on indirect renderer helper chains.
- `scripts/gameplay/character_animation_controller.gd`, `character_renderer.gd`, `weapon_renderer.gd`, `world_health_bar.gd`, `projectile_renderer.gd`, `combat_feedback_controller.gd`, `camera_effects.gd`: retained prototypes/reference modules; normal gameplay scenes do not instantiate them.
- `scripts/arena/map_rules`: per-map runtime rules. `dungeon_rule.gd` controls cage traps, `sky_city_rule.gd` controls moving/resizing blockers, `jungle_rule.gd` controls swamp slow zones, and `mist_world_rule.gd` controls fog visibility zones.
- `scripts/controllers`: human/agent/remote/ONNX/replay controller interfaces.
- `scripts/rl`: action, observation, bridge, reward, training runner, visibility filtering.
- `scripts/replay`: JSONL replay recorder.
- `training/`: staged curriculum configs, evaluation matrix, GPU resource estimate, and headless job launcher.
- `resources/`: configs, themes, map resources.
- `tests/`: Godot and static smoke tests.
- `docs/`: architecture and interface notes.

## Agent Interface

All controllers implement:

```gdscript
func reset() -> void
func get_action(observation: AgentObservation, delta: float) -> PlayerAction
```

Add a new scripted agent by subclassing or replacing `ScriptedAgentController`, keeping all decisions outside `ArenaPlayer`.

## Observation And Action

`PlayerAction` serializes movement, aim, shoot, dash, shield, and communication. The action space was kept compatible with the existing controllers.

`AgentObservation` serializes:

- Self private state: health, energy/charge, shoot/dash/shield cooldown ratios, alive/shield/protection flags, score, position, velocity, and aim direction.
- Other player public state only: relative position/velocity, aim direction, health ratio, teammate flag, alive/shield/dash/protection flags, and validity.
- Projectile public state: relative position/velocity, owner team relation, lifetime ratio, damage ratio, and validity.
- Map state: boundary distances, 16 ray samples, map id, and game mode id.

Other characters' exact energy/charge, ammo-like values, reserve values, magazine values, reload timers, internal weapon cooldowns, controller internals, policy state, targets, and pathing are not exposed through HUD or observation. `VisibilityFilter` contains the privacy scan used by tests, and `ObservationBuilder.build_observation_for_actor()` is the single observation entry point.

Scoreboard/result data contains names, human/agent type, team, kills, deaths, score, and alive/public combat state. It does not contain private charge or cooldown values.

## Debug Overlay

`scenes/debug/DebugOverlay.tscn` and `scripts/debug/debug_overlay.gd` are development-only scaffolds. Default gameplay does not show debug data. If a full authoritative-state overlay is added later, keep it separate from normal match HUD and from Agent observation.

## Adding Maps And Modes

Add a scene or map builder under `scenes/arena` / `scripts/arena`, expose wall rects, `is_point_blocked()`, `is_line_blocked()`, `ray_distance()`, and `is_spawn_area_clear()`, then reference it from match setup. Add map-specific live rules under `scripts/arena/map_rules` so timers, durations, radii, and obstacle behavior stay isolated from core combat.

## Hybrid Tactical Training

Recommended entry points:

- `scripts/controllers/hybrid_agent_controller.gd` for protocol v2 tactical decisions.
- `scripts/agents/hybrid/*` for deterministic low-level execution.
- `scripts/rl/environment_bridge.gd` for reset/step/batch observation APIs.
- `scripts/rl/reward_calculator.gd` for reward shaping.
- `scripts/controllers/remote_agent_controller.gd` for Python socket or IPC actions.
- `training/inference/serve_agent.py` for deployed tactical policy inference.
- `training/rl/tactical_bc_trainer.py` for v2 replay warm starts.
- `training/configs/training_plans/hybrid_tactical_local.json` for local training.
- `training/configs/training_plans/hybrid_tactical_full.json` for server training.
- `training/configs/curriculum.json` for staged training gates.
- `training/configs/evaluation_matrix.json` for promotion evaluation.

Historical raw-action PPO/BC outputs are archived in `archive/legacy_raw_ai/`.

## Current Known Issues

- Godot CLI validation is available through the commands in the Tests section; direct single-script `--check-only` runs can report false positives for project autoload names, so prefer the project-level smoke commands above.
- The current SFX are short generated placeholders routed through `AudioManager`; replace them with authored assets through the same event surface.
- Replay records decision frames but is not frame-perfect playback yet.
- Current EnvironmentBridge is single-Arena; production training still needs vectorized worker IPC.
