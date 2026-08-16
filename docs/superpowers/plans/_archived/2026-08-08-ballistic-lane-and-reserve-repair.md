# Ballistic Lane and Energy Reserve Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `legal_window_pressure` select and seek the same predicted ballistic lanes used by firing, expose energy-reserve causes, and validate the repair through isolated four-GPU four-map PPO diagnostics.

**Architecture:** `BallisticAimSolver` remains the single source for predicted intercept legality. `TacticalFeatureBuilder` and `MovementExecutor` consume an observation-level candidate-lane helper instead of current-position geometry. FireControl returns the decisive energy-reserve cause, which is exported by the bridge and aggregated by the PPO audit.

**Tech Stack:** Godot 4/GDScript, Python `unittest`, PyTorch PPO, JSON training plans.

## Global Constraints

- Retain the `legal_window_pressure` profile identifier and 0.72/0.88 threat thresholds.
- Retain blind-fire, wall, lifetime, cover, projectile-evasion, and emergency-safety gates.
- Preserve baseline-profile movement/visibility behavior.
- Do not auto-promote checkpoints.
- Training outputs, replay directories, seeds, and ports are isolated from prior diagnostics.

---

### Task 1: Share predicted-intercept lane legality

**Files:**
- Modify: `scripts/agents/hybrid/ballistic_aim_solver.gd`, `scripts/agents/hybrid/tactical_feature_builder.gd`, `scripts/agents/hybrid/movement_executor.gd`
- Test: `tests/run_tests.gd`

**Interfaces:** Add `BallisticAimSolver.evaluate_observation_lane(obs, target, balance, arena_map, config) -> Dictionary`, returning the normal `solve_from_observation` fields plus `current_line_of_sight`. A lane is usable only when `valid_target`, `has_solution`, `within_lifetime`, `line_of_sight`, and not `wall_blocked` or `target_invulnerable`.

- [ ] **Step 1: Write failing Godot coverage.** Add a moving enemy whose current position has an open line but whose predicted intercept point is behind `FakeHybridMap` geometry. Assert pressure masks disable `KEEP_RANGE` and retain `CHASE`; assert a candidate lateral vantage with an open predicted lane is chosen.

- [ ] **Step 2: Verify red.** Run `HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --path . -s res://tests/run_tests.gd`. Expected: the mask incorrectly permits `KEEP_RANGE` or the vantage route stays direct.

- [ ] **Step 3: Implement the helper and consumers.** Compute `current_line_of_sight` from the unled target position; use `solve_from_observation` for every candidate lane. Replace pressure-only reachable-enemy checks with the helper. In `MovementExecutor`, create a candidate-shooter observation at each probe position and accept only a usable predicted lane. Keep non-pressure code paths unchanged.

- [ ] **Step 4: Verify green.** Run the same Godot test runner. Expected: the new predicted-lane regression and existing fire/cover tests pass.

- [ ] **Step 5: Commit only Task 1 files.** `git add scripts/agents/hybrid/ballistic_aim_solver.gd scripts/agents/hybrid/tactical_feature_builder.gd scripts/agents/hybrid/movement_executor.gd tests/run_tests.gd && git commit -m "fix: align pressure movement with ballistic lanes"`.

### Task 2: Explain reserve-energy rejections

**Files:**
- Modify: `scripts/agents/hybrid/fire_control.gd`, `scripts/agents/hybrid/hybrid_combat_executor.gd`, `scripts/rl/environment_bridge.gd`, `training/rl/tactical_online_trainer.py`
- Test: `tests/run_tests.gd`, `tests/unit/test_tactical_online_trainer.py`, `tests/unit/tactical_training_protocol_test.gd`

**Interfaces:** Fire-control diagnostics gain `reserve_basis: String` and `reserve_ratio: float`; permitted bases are `base`, `low_health`, `dash_ready`, `shield_ready`, `projectile_threat`, `conservative`, `burst`, and `all_in_kill_window`. PPO audit gains `reserved_energy_by_basis` and `map_reserved_energy_by_basis`.

- [ ] **Step 1: Write failing tests.** Assert a ready dash wins over the base reserve, a threat reserve wins at high threat, and a `reserved_energy` transition increments both global and map-local reserve-basis counters after bridge-safe diagnostics are serialized.

- [ ] **Step 2: Verify red.** Run the focused Godot runner and `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v`. Expected: absent diagnostic fields/counters.

- [ ] **Step 3: Implement the smallest data flow.** Track the currently maximal reserve reason alongside `reserve_ratio` in `_reserved_energy`; attach both to all FireControl diagnostics. Whitelist them in the bridge and increment PPO counters only for `reserved_energy` rejections. Do not change reserve values.

- [ ] **Step 4: Verify green.** Run both focused suites. Expected: reserve basis survives executor → bridge → trainer and counter tests pass.

- [ ] **Step 5: Commit only Task 2 files.** `git add scripts/agents/hybrid/fire_control.gd scripts/agents/hybrid/hybrid_combat_executor.gd scripts/rl/environment_bridge.gd training/rl/tactical_online_trainer.py tests/run_tests.gd tests/unit/test_tactical_online_trainer.py tests/unit/tactical_training_protocol_test.gd && git commit -m "feat: audit pressure reserve causes"`.

### Task 3: Create isolated four-GPU training contract

**Files:**
- Create: `training/configs/training_plans/tactical_legal_window_pressure_four_map_ballistic_repair.json`
- Create: `training/configs/multi_gpu/legal_window_pressure_ballistic_repair_gpu4_7.json`
- Modify: `tests/unit/test_train_pipeline.py`, `docs/training/runbooks/four-map-foundation.md`

**Interfaces:** Collection records 32 sixty-second, pressure-curriculum matches into `training/replays/four_map_ballistic_repair_bc`; BC writes `training/runs/four_map_ballistic_repair_bc`; four PPO jobs use GPUs 4–7, ports 18961–18964, unique seeds, 16,384 steps, and isolated `training/runs/legal_window_pressure/ballistic_repair_gpu{4,5,6,7}` outputs.

- [ ] **Step 1: Write failing Python plan tests.** Assert all four map IDs, fresh replay/BC paths, ports 18961–18964, exactly GPUs 4–7, and 16,384 PPO steps per job.

- [ ] **Step 2: Verify red.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline -v`. Expected: plan file missing.

- [ ] **Step 3: Add JSON/runbook contract.** Use `legal_window_pressure`, fresh BC warm-start, 32 collection matches, and no catalog promotion. Document the preflight command and aggregate gates.

- [ ] **Step 4: Verify green.** Re-run the plan tests. Expected: the contract is parseable and GPU assignment is exactly 4–7.

### Task 4: Verify and run diagnostics

**Files:**
- Read: `training/runs/legal_window_pressure/ballistic_repair_gpu{4,5,6,7}/rollout_audit.json`

- [ ] **Step 1: Run local verification.** Run all unit tests with host loopback permissions, the Godot runner, and `git diff --check`.

- [ ] **Step 2: Collect and train BC.** On GPU 4 run `training.train_pipeline --plan tactical_legal_window_pressure_four_map_ballistic_repair --phase collect --execute`, then `--phase bc --execute`; audit replay integrity and BC validation metrics.

- [ ] **Step 3: Launch four PPO jobs.** Use the multi-GPU contract with `CUDA_VISIBLE_DEVICES=4,5,6,7`; start only after ports 18961–18964 and the GPUs are free.

- [ ] **Step 4: Apply gates.** Aggregate only realized events. Require zero raw steps, zero transport/service fallback, both consistency flags, all maps, authorization at least 1.5%, hit conversion at least 25%, and Sky/Mist improvement against their 0.71%/1.46% authorization and 68.4%/72.0% line-block baselines. Report reserve basis before changing thresholds.
