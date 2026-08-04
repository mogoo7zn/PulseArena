# Four-Map Combat and Resource Foundation — Implementation Plan

> **Execution:** Follow this plan in the current checkout. The repository has related, uncommitted work that must remain available to the repair; do not create a detached worktree, reset, or overwrite unrelated changes. Implement with test-driven development and commit only files attributable to this plan.

**Goal:** Repair common decision-to-fire and resource-value accounting, expose all four map mechanics as auditable events, then run the `legal_window_pressure` playability route through one balanced four-map curriculum.

**Architecture:** Godot owns authoritative causal events. `ArenaRoot` attaches the decision generation and pickup source to runtime effects, while `RewardCalculator` owns exactly-once reward/event accounting. Python treats Godot counters as authoritative, aggregates them by map, and deterministically rotates episode maps. Training configuration names immutable new post-fix artifacts rather than changing historical Dungeon runs.

**Tech stack:** Godot 4 / GDScript runtime and unit tests; Python `unittest`, PyTorch tactical PPO, JSON training plans and multi-GPU orchestration.

---

## 1. Stabilize the decision-to-fire ledger

**Files:**

- Modify: `scripts/arena/arena_root.gd`
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `scripts/rl/environment_bridge.gd`
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `tests/unit/reward_calculator_profile_test.gd`
- Modify: `tests/unit/test_tactical_online_trainer.py`

**Step 1: Write failing tests.**

- In `reward_calculator_profile_test.gd`, require `register_authorized_projectile(projectile_id, player_id, generation, facts)` to reject generation `0`, count one `fire_authorized` record for a valid exact generation, and preserve the generation through an authorized hit/damage. Exercise a later, blocked generation for the same player and prove it cannot alter the earlier projectile's commitment/hit reward.
- In `test_tactical_online_trainer.py`, feed snapshots whose current diagnostics are deliberately stale, with generation-indexed event counters. Assert that `fire_authorized`, `authorized_hit`, `authorized_damage`, and rejection reason totals come only from Godot event data; assert no counter can imply more hits than authorizations.

**Step 2: Run the focused tests and confirm they fail for the missing causal fields.**

Run: `.conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v` and the Godot unit runner filtered through `tests/run_tests.gd`.

**Step 3: Implement the ledger.**

- In `ArenaRoot.apply_tactical_decisions`, retain the monotonically increasing per-player generation already created there. `_record_tactical_execution` must pass it to `RewardCalculator.on_tactical_execution`; the root must retain an immutable per-player decision-facts snapshot for the currently executable generation.
- In `_on_projectile_requested`, obtain the owning player's current generation and immutable decision-time facts, then call the new generation-aware authorization API. Do not read the controller's later diagnostics at projectile spawn.
- In `RewardCalculator`, store `{player_id, decision_generation_id, authorized}` per projectile. Count `fire_authorized` only once, use the stored record for commitment and hit/damage attribution, and clear only the resolved projectile record. Add exact-event counters for fire intent, authorized projectiles/hits/damage, and rejection reasons.
- In `EnvironmentBridge`, whitelist `decision_generation_id` and return cumulative event counters without deriving projectile outcomes from its end-of-step diagnostics.
- In `tactical_online_trainer.py`, aggregate cumulative event counters as the source of truth, add `decision_generation_consistent`, `authorized_damage`, and rejection-reason sections to `rollout_audit.json`, while retaining snapshots only for action-state distributions.

**Step 4: Rerun focused tests and then broader tactical tests.**

Run the two focused suites, `tests/smoke/tactical_training_protocol_check.py`, and `tests/smoke/tactical_ppo_cuda_micro_update.py` with the project Godot binary environment. Expected result: no raw action calls, exactly-once event attribution, and the existing blocked-fire test remains green.

## 2. Turn pickup accounting into realized resource value

**Files:**

- Modify: `scripts/config/reward_config.gd`
- Modify: `scripts/gameplay/player.gd`
- Modify: `scripts/arena/arena_root.gd`
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `tests/unit/reward_calculator_profile_test.gd`
- Modify: `tests/unit/test_tactical_online_trainer.py`

**Step 1: Write failing tests.**

- Add Godot cases showing that a full-health health pickup creates no positive component; partial health restoration credits only the healed amount; unused shield, haste, and overcharge do not create collection reward.
- Add cases showing active shield absorption and actual authorized projectile damage while haste/overcharge are active each produce their matching realized-value counter exactly once. Prove magnet is audit-only and a contested non-magnet pickup can receive at most one capture component.
- Add a Python audit test that confirms pickup totals are cumulative across snapshots and serialized under a dedicated `resource_event_counts`/`resource_value_totals` section.

**Step 2: Run focused tests and confirm the existing collection-only path fails them.**

Run the Godot runner and `python -m unittest tests.unit.test_tactical_online_trainer -v`.

**Step 3: Implement the resource ledger.**

- Add explicit, conservative coefficients and contest radius to `RewardConfig`; default all realized-value coefficients to zero outside the `legal_window_pressure` profile. The only immediate shaping is a small, once-per-pickup contested non-magnet capture coefficient.
- Make `ArenaPlayer` expose the exact health restored by `restore_health` and source IDs/timers for pickup shield, haste, and overcharge. Preserve source only for the current effect and clear it on respawn/expiry.
- In `ArenaRoot._apply_pickup`, record a collection event with pickup type, collector, map id, immediate restored HP, and whether any alive enemy is within the configured contest radius. Do not award a generic pickup reward.
- In damage handling, report shield absorption to the active shield source and report authorized projectile damage to active haste/overcharge sources. Keep pulse on its existing real damage/kill path; record magnet only as an audit event.
- In `RewardCalculator`, make collection, realization, expiry-unused, and contested-capture event APIs exactly once per pickup/effect source. Store counters and components separately, and expose them with tactical event counts.
- Extend Python rollout audit aggregation to retain map-keyed resource event/value totals.

**Step 4: Rerun resource and full protocol tests.**

Expected result: no positive reward from uncontested full-health farming; each positive pickup component corresponds to a measurable benefit, and existing combat reward totals remain compatible.

## 3. Make map mechanics first-class training events

**Files:**

- Modify: `scripts/arena/arena_root.gd`
- Modify: `scripts/arena/map_rules/dungeon_rule.gd`
- Modify: `scripts/arena/map_rules/sky_city_rule.gd`
- Modify: `scripts/arena/map_rules/jungle_rule.gd`
- Modify: `scripts/arena/map_rules/mist_world_rule.gd`
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `tests/unit/reward_calculator_profile_test.gd`

**Step 1: Write failing taxonomy tests.**

- Require `on_environment_damage/death` to count sources separately and retain their existing global environment reward component.
- Use the map rule call sites (or lightweight root stubs) to assert the exact source labels: `dungeon_trap`, `sky_squeeze`, `sky_void`, `jungle_swamp`, `jungle_snake`, and non-damaging `mist_portal`/`mist_fog` events.

**Step 2: Run the focused Godot tests and confirm generic `environment` attribution fails them.**

**Step 3: Implement source propagation.**

- Extend `ArenaRoot.apply_environment_damage` and `kill_player_by_environment` with a source parameter and forward it to `RewardCalculator`; rename the void source to `sky_void` without changing the underlying penalty.
- Change each map-rule invocation to provide its source. On portal traversal, notify the root of `mist_portal`; on fog entry/exit/visibility change, notify it of `mist_fog` as a non-rewarded event. Record locks/forced movement as events, not new hidden reward terms.
- In `RewardCalculator`, retain source-specific cumulative map-event counters, including non-damaging events. Expose them from `ArenaRoot` and aggregate them in per-map Python audit output.

**Step 4: Rerun Godot unit tests and a headless one-match smoke on each map.**

Expected result: every map exports its full event schema even when a particular short match has zero events, and all existing environment penalties remain unchanged.

## 4. Add deterministic, balanced four-map tactical PPO scheduling

**Files:**

- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `training/train_pipeline.py`
- Modify: `tests/unit/test_tactical_online_trainer.py`
- Modify: `tests/unit/test_train_pipeline.py`
- Add: `training/configs/training_plans/tactical_legal_window_pressure_four_map.json`
- Add: `training/configs/multi_gpu/legal_window_pressure_four_map_foundation_gpu4_7.json`

**Step 1: Write failing schedule/configuration tests.**

- Extend `FakeTacticalEnv` to retain reset configs. Configure `map_ids=("dungeon", "sky_city", "jungle", "mist_world")`, force four finished episodes, and assert the reset sequence is exactly that order, each map count is one, and `rollout_audit.json` has `map_episode_counts` plus map-keyed events.
- In pipeline tests, load the new immutable plan and assert it names all four map IDs, the same legal-window profile/BC checkpoint/episode duration/opponent policy/hyperparameters, and a new output root. Dry-run must serialize `map_ids`.
- Load the multi-GPU JSON and assert all four tasks reference the new four-map plan, have unique ports/seeds/output directories, and explicitly describe independent candidate cohorts rather than a shared learner.

**Step 2: Run focused Python tests and confirm single-map configuration fails them.**

**Step 3: Implement schedule and configuration.**

- Add `map_ids: tuple[str, ...]` to `TacticalOnlineConfig`, resolve/validate it to unique supported IDs with `map_id` retained as backward-compatible fallback, and choose map by `episode_index % len(map_ids)` on every reset. First reset is Dungeon; seeds increment as before.
- Track `map_episode_counts`, `map_transition_counts`, and per-map copies of realized fire/resource/map events in the audit. Persist the normalized map list in config and checkpoints.
- Parse `tactical_ppo.map_ids` in `run_tactical_ppo` and include it in the dry run.
- Create `tactical_legal_window_pressure_four_map.json` with immutable `four_map_foundation` replay/BC/PPO output paths, fixed map order, scripted hard opponent, 60-second episodes, and the existing legal-window PPO values. The plan must specify a post-fix four-map BC output rather than reuse old Dungeon-only data.
- Create the matching 4-worker JSON with GPUs 4–7, unique ports/seeds/output directories, and a bounded diagnostic invocation as the first live run. Preserve `legal_window_pressure_gpu4_7_event_gated.json` unchanged as historical evidence.

**Step 4: Run all relevant Python tests and a pipeline dry-run.**

Run: `.conda/bin/python -m unittest tests.unit.test_tactical_online_trainer tests.unit.test_train_pipeline -v` and `training/train_pipeline.py --plan tactical_legal_window_pressure_four_map --phase ppo-multi` without `--execute`. Expected result: four independent commands, each internally balanced across four maps.

## 5. Verify before launching the bounded diagnostic and report evidence

**Files:**

- Add: `docs/training/2026-08-04-four-map-foundation-diagnostic-report.md`
- Modify only if needed: `tests/smoke/tactical_training_protocol_check.py`

**Step 1: Run the complete preflight.**

Run Godot unit tests, the two Python unit modules, tactical protocol smoke, tactical PPO CUDA micro-update, pipeline dry run, and `git diff --check`. Record command, exit status, and any environment constraint in the report.

**Step 2: Launch one bounded four-map diagnostic cohort only after preflight is green.**

Use the new plan with a small explicit `--total-env-steps` override and one worker. Save only under the new `four_map_foundation/diagnostic` path. Do not deploy or overwrite a model catalog entry.

**Step 3: Inspect and report the diagnostic.**

- Confirm all four maps appear and their episode counts differ by at most one for a non-multiple-of-four run.
- Confirm `raw_step_calls == 0`; authorized hits never exceed authorized projectiles; blocked-fire commitment/hit reward is zero; resource counters show realized rather than collection-only value; and each map exposes the event schema.
- State separately what is proven by event accounting and what still requires longer playability evaluation. Do not claim a model is ready for promotion.

## Final verification and commits

1. Run `git diff --check` and targeted/full test commands above.
2. Inspect `git status --short`, stage only plan-owned files, and make small thematic commits: ledger/resources, taxonomy/scheduling/config, diagnostic report.
3. Report committed hashes, exact tests, bounded diagnostic artifact location, and remaining gates.
