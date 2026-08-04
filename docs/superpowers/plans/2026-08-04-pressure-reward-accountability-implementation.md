# Pressure Reward Accountability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute pressure rewards and audits to realized tactical events, improve persistent firing-vantage movement, and run a gated GPU 4–7 pressure-training cohort.

**Architecture:** Godot owns event creation and cumulative per-player counters; the safe environment bridge exports only counter snapshots; Python computes deltas to produce a truthful cohort audit. The pressure movement profile retains one safe lateral route while a known target is blocked. Training remains independent per GPU and begins only after unit and TCP verification.

**Tech Stack:** Godot 4 GDScript, Python 3.10, PyTorch PPO, JSON plans, unittest, Godot TCP smoke.

## Global Constraints

- Preserve true ballistic line-of-sight, friendly-fire, mask, and emergency-evasion constraints.
- Do not modify deployed/catalog assets under `training/models/` or deployed checkpoints.
- All runs start from `training/runs/hybrid_tactical_bc/best_tactical_policy.pt`, never from pre-draw-fix PPO output.
- Use only GPU 4, 5, 6, and 7; each worker has a distinct port and output directory.
- Never promote a candidate automatically.

---

### Task 1: Realized engagement event counters

**Files:**
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `scripts/rl/environment_bridge.gd`
- Modify: `tests/unit/reward_calculator_profile_test.gd`

**Interfaces:**
- `RewardCalculator.get_tactical_event_counts(player_id: int) -> Dictionary` returns integer cumulative counters.
- `register_authorized_projectile` increments `authorized_projectile` exactly once.
- `on_damage` increments `authorized_hit` only when the projectile was authorized.

- [ ] Write a failing Godot test that registers an authorized projectile, deals damage, and asserts `authorized_projectile == 1` and `authorized_hit == 1`.
- [ ] Run `HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --path . --script res://tests/run_tests.gd`; expect failure because the counter API is absent.
- [ ] Add per-player event dictionaries, increment only at authorization and authorized-hit boundaries, and export a duplicate through `EnvironmentBridge`.
- [ ] Re-run the Godot test command; expect PASS.

### Task 2: Rewarding pressure and penalizing controllable withdrawal

**Files:**
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `scripts/config/reward_config.gd`
- Modify: `tests/unit/reward_calculator_profile_test.gd`

**Interfaces:**
- `RewardConfig.avoidable_pressure_retreat: float` defaults to zero and is negative only for `legal_window_pressure`.
- `RewardCalculator.on_tactical_execution` records one `pressure_retreat` event and applies the component only when target, actionable window, range, and threat facts all permit it.

- [ ] Write a failing test for an actionable, threat-free `RETREAT` decision and a companion emergency-threat case that must not receive the penalty.
- [ ] Run the Godot test command; expect the new assertions to fail.
- [ ] Add the profile coefficient and the narrowly defined reward condition.
- [ ] Re-run the Godot test command; expect PASS.

### Task 3: Event-based Python audit

**Files:**
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `tests/unit/test_tactical_online_trainer.py`

**Interfaces:**
- Audit output includes `tactical_event_counts` and `event_counter_consistent`.
- `update_transition_audit` computes positive deltas from `player_data["tactical_event_counts"]` instead of using snapshot `fire_allowed` as the authoritative shot count.

- [ ] Write a failing Python test with two snapshots where the second event count increments while `diagnostics.fire_allowed` is false; assert the audit records the event.
- [ ] Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v`; expect failure.
- [ ] Implement counter-delta aggregation and include the internal-consistency field in the persisted audit.
- [ ] Re-run the focused Python test; expect PASS.

### Task 4: Persistent firing-vantage direction

**Files:**
- Modify: `scripts/agents/hybrid/movement_executor.gd`
- Modify: `scripts/agents/hybrid/hybrid_agent_config.gd`
- Modify: `tests/run_tests.gd`

**Interfaces:**
- Pressure config exposes `engagement_vantage_hold_seconds`.
- A blocked target retains a safe lateral direction until its timer expires, the path becomes unsafe, an emergency threat exists, or the lane becomes clear.

- [ ] Write a failing movement test that calls `execute` twice while the target remains blocked and asserts the second direction retains the first lateral side.
- [ ] Run the Godot test command; expect failure because route state is not retained.
- [ ] Add bounded route state and reset it in `MovementExecutor.reset`.
- [ ] Re-run the Godot test command; expect PASS.

### Task 5: Four-GPU gated cohort

**Files:**
- Create: `training/configs/multi_gpu/legal_window_pressure_gpu4_7_event_gated.json`
- Modify: `training/README.md`

**Interfaces:**
- Four independent tasks use GPUs 4–7, ports 18930–18933, semantic `event_gated_pressure` paths, and the fixed 90-second plan.
- Each output contains `rollout_audit.json`; no output is deployed automatically.

- [ ] Write the JSON with four disjoint workers and semantic output paths.
- [ ] Run `PYTHONPATH=. .conda/bin/python training/train_pipeline.py --profile local_constrained --plan tactical_legal_window_pressure --phase ppo-multi --multi-gpu-config training/configs/multi_gpu/legal_window_pressure_gpu4_7_event_gated.json`; inspect that each task has one of GPUs 4–7 and no overlapping port.
- [ ] Run Godot unit tests, Python unit tests, and `HOME="$PWD/.tools/godot-user" python3 tests/smoke/tactical_training_protocol_check.py --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --port 18770`.
- [ ] Execute the four-GPU cohort only if the checks pass.
- [ ] Aggregate the four audits against the gates in `docs/superpowers/specs/2026-08-04-pressure-reward-accountability-design.md`; retain all failures as diagnostic outputs and do not deploy a candidate.
