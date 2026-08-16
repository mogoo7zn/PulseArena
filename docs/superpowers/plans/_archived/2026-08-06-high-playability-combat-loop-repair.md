# High-Playability Combat Loop Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep `legal_window_pressure` and repair its four-map PPO behavior so it uses cover under pressure, re-engages, and converts legal firing windows without weakening emergency safety.

**Architecture:** The existing profile remains the only profile identifier. Configuration gains only the pressure-specific controls currently embedded in teacher and executor code; rollout auditing records cover entry/re-engagement from executed tactical decisions. An isolated GPU-4 plan recollects balanced demonstrations, retrains BC, and warm-starts PPO from that repaired tactical prior; it never deploys automatically.

**Tech Stack:** Godot 4/GDScript, Python `unittest`, PyTorch PPO, JSON training plans.

## Global Constraints

- Preserve `legal_window_pressure`; do not create a profile ID.
- Preserve high-threat/emergency thresholds: 0.72 / 0.88.
- Preserve target visibility and all blind-fire safety checks.
- Change training-only behavior only; never auto-promote a checkpoint.
- Run all actual training with `CUDA_VISIBLE_DEVICES=4`.

---

### Task 1: Record the cover-to-reengagement lifecycle

**Files:**

- Modify: `training/rl/tactical_online_trainer.py:initial_rollout_audit`, `training/rl/tactical_online_trainer.py:update_transition_audit`
- Test: `tests/unit/test_tactical_online_trainer.py`

**Interfaces:** consumes `executed_decision.movement_mode`, `player_id`, and optional `map_id`; produces `cover_entry_count`, `cover_reengage_count`, `map_cover_event_counts`, and `_last_movement_modes_by_player`.

- [ ] **Step 1: Write the failing test.**

```python
def test_transition_audit_counts_cover_entry_and_reengagement_by_map(self) -> None:
    audit = initial_rollout_audit("legal_window_pressure")
    cover = {"executed_decision": {"fire_mode": 0, "movement_mode": 6, "target_slot": 1}, "reward_components": {}, "diagnostics": {}}
    chase = {"executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1}, "reward_components": {}, "diagnostics": {"fire_allowed": True}}
    update_transition_audit(audit, "0", cover, map_id="dungeon")
    update_transition_audit(audit, "0", chase, map_id="dungeon")
    self.assertEqual(audit["cover_entry_count"], 1)
    self.assertEqual(audit["cover_reengage_count"], 1)
    self.assertEqual(audit["map_cover_event_counts"]["dungeon"], {"cover_entry": 1, "cover_reengage": 1})
```

- [ ] **Step 2: Verify red.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer.TacticalOnlineTrainerTests.test_transition_audit_counts_cover_entry_and_reengagement_by_map -v`. Expected: fail because the counters do not exist.

- [ ] **Step 3: Implement the smallest state transition.** Add the four audit keys. After parsing `movement_mode`, compare it with the prior value for the same player: `6` after a different mode increments cover entry; transition from `6` to `1`, `2`, or `7` increments reengagement. Record nested map counts only when `map_id` exists, then persist the current mode.

- [ ] **Step 4: Verify green.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v`. Expected: pass including four-map rotation and cumulative-event tests.

- [ ] **Step 5: Commit.** Stage only `training/rl/tactical_online_trainer.py` and `tests/unit/test_tactical_online_trainer.py`; use message `feat: audit cover reengagement lifecycle`.

### Task 2: Expose the existing pressure safety controls

**Files:**

- Modify: `scripts/agents/hybrid/hybrid_agent_config.gd`, `scripts/agents/hybrid/tactical_teacher.gd`, `scripts/controllers/hybrid_agent_controller.gd`, `scripts/agents/hybrid/fire_control.gd`
- Test: `tests/run_tests.gd`

**Interfaces:** consumes existing `legal_window_pressure` and `threat_info`; produces five configuration fields: `cover_health_threshold`, `cover_threat_threshold`, `dash_ready_reserved_energy_ratio`, `shield_ready_reserved_energy_ratio`, `threat_reserved_energy_floor`.

- [ ] **Step 1: Write failing Godot assertions.** Add a pressure-only case: health `0.44`, nearby cover, threat `0.50` selects `SEEK_COVER`; with threat `0.80` it selects `EVADE_PROJECTILE`. Add a visible legal normal-shot case with energy `0.28`, ready dash/shield, threat `0.30`: baseline rejects and existing pressure profile authorizes.

- [ ] **Step 2: Verify red.** Run `HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --path . -s res://tests/run_tests.gd`. Expected: fail because the pressure-specific values and teacher config parameter do not exist.

- [ ] **Step 3: Implement only the named controls.** Use baseline-preserving defaults: `0.34`, `0.0`, `0.26`, `0.24`, `0.26`; a zero cover-threat threshold preserves the baseline's existing low-health cover rule. Set only `legal_window_pressure` to `0.46`, `0.38`, `0.20`, `0.22`, `0.16`, respectively. Add optional final `HybridAgentConfig` input to `TacticalTeacher.build_label` and pass the controller config at the production call. Retain the existing high-threat early return; after it, select cover only if health is below the configured threshold, threat is at least its configured threshold, and cover is observable. Replace FireControl's literal ready-dash, ready-shield, and threat-lerp floor values with the fields. Do not alter defensive maximum reserve, line-of-sight gating, or emergency response.

- [ ] **Step 4: Verify green.** Run `HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --path . -s res://tests/run_tests.gd`. Expected: pass including baseline fire rejection, high-threat evasion, visibility masking, and vantage-routing tests.

- [ ] **Step 5: Commit.** Stage the four implementation files and `tests/run_tests.gd`; use message `fix: expose pressure cover and fire reserves`.

### Task 3: Add an isolated four-map GPU-4 diagnostic contract

**Files:**

- Create: `training/configs/training_plans/tactical_legal_window_pressure_four_map_repair_diagnostic.json`
- Modify: `tests/unit/test_train_pipeline.py`, `docs/training/runbooks/four-map-foundation.md`

**Interfaces:** consumes fresh balanced replays at `training/replays/four_map_repair_diagnostic_bc`; produces `training/runs/four_map_repair_diagnostic_bc/best_tactical_policy.pt` and a non-deployed PPO output at `training/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4` on port `18945`.

- [ ] **Step 1: Write the failing plan test.** Load the new JSON and assert `reward_profile_id == "legal_window_pressure"`, the exact four map IDs, `training_spawn_policy == "pressure_curriculum"`, `total_env_steps == 32768`, and `port == 18945`.

- [ ] **Step 2: Verify red.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline.TrainPipelineTests.test_repair_diagnostic_plan_keeps_high_playability_profile_on_gpu4 -v`. Expected: `FileNotFoundError`.

- [ ] **Step 3: Create the JSON and runbook entry.** Clone the foundation four-map contract with the same profile, maps, pressure curriculum, 60-second matches, 32,768 PPO steps, and CUDA requirement. Set fresh seeds, replay directory `training/replays/four_map_repair_diagnostic_bc`, BC output `training/runs/four_map_repair_diagnostic_bc`, and make PPO warm-start that BC checkpoint. Set PPO output `training/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4`, port `18945`, and `multi_gpu.enabled` false. Add the exact GPU-4 command and audit gates to the runbook.

- [ ] **Step 4: Verify green.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline tests.unit.test_tactical_online_trainer -v`. Expected: pass.

- [ ] **Step 5: Commit.** Stage the plan, test, and runbook; use message `docs: add four-map combat repair diagnostic`.

### Task 4: Verify and run GPU-4 PPO diagnostic

**Files:**

- Read: `training/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4/rollout_audit.json`, `training/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4/metrics.jsonl`

**Interfaces:** consumes Tasks 1–3 and the repaired four-map BC checkpoint; produces only non-deployed diagnostics and a data-backed continue/stop decision.

- [ ] **Step 1: Run complete local verification.** Run `MPLCONFIGDIR="$PWD/test-results/matplotlib" PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -v`, then the Godot test command from Task 2, then `git diff --check`. Expected: all pass.

- [ ] **Step 2: Start GPU-4 training.** Check port `18945` first. Start a managed tmux session with `CUDA_VISIBLE_DEVICES=4 .conda/bin/python training/train_pipeline.py --profile local_constrained --plan tactical_legal_window_pressure_four_map_repair_diagnostic --phase all --execute --output-dir training/runs/legal_window_pressure/four_map_repair_diagnostic_gpu4 --port 18945 --seed 20261086`.

- [ ] **Step 3: Apply acceptance gates.** Require zero raw steps and fallback; nonzero episode count for every map; both consistency flags true; positive cover-entry and cover-reengagement counts; authorized-projectile/fire-intent above `0.012`; and authorized-hit/authorized-projectile at least `0.25`. Compare line-of-sight and reserve blocks to the prior diagnostic. If a gate fails: persistent LoS needs vantage work; reserve needs FireControl tracing; cover without reengagement needs movement work; hit collapse restores prior thresholds. Do not enlarge PPO before every gate passes.

- [ ] **Step 4: Commit source artifacts only.** Stage source, tests, plan, and runbook changes; use message `fix: validate high-playability combat repair`. Do not stage checkpoints, replays, metrics, or GPU logs.
