# Dual Tactical Training Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely archive pre-draw-fix generated runs and add two separately auditable tactical PPO reward profiles: legal-window pressure and score-margin discipline.

**Architecture:** Introduce a `reward_profile_id` in the match configuration and resolve named profile overrides in Godot before each match. Python tactical PPO plans pass that identifier unchanged, and the trainer records it with outcome/engagement audits. A repeatable archive script moves only explicitly classified generated directories, never catalog manifests or deployed checkpoints.

**Tech Stack:** Godot 4 GDScript, Python 3.10, PyTorch PPO, JSON plans, unittest, Godot TCP smoke.

## Global Constraints

- Do not move `training/models/*_agent.json`, `training/models/model_catalog.json`, or `training/checkpoints/hybrid/*.pt`.
- Do not resume either new policy from a pre-draw-fix PPO checkpoint; use the audited BC checkpoint only.
- Model/run/config names use `legal_window_pressure`, `score_margin_discipline`, or `pre_draw_fix`; never a bare version number.
- Draw outcome reward is zero and neither FFA nor 2v2 ties report a winner.
- Training still uses protocol-v2 tactical decisions only; `raw_step_calls` must remain zero.
- No default-model promotion is part of this work.

---

## File Structure

- `scripts/training/archive_pre_draw_fix_runs.py`: dry-run/apply archive planner with a fixed allowlist and protected-path checks.
- `tests/unit/test_archive_pre_draw_fix_runs.py`: verifies only allowed run/evaluation directories are moved and catalog/deployed assets are untouched.
- `scripts/config/match_config.gd`: transports `reward_profile_id` through reset/duplication/serialization.
- `scripts/config/reward_config.gd`: applies named reward-profile overrides and computes per-transition tactical shaping rewards.
- `scripts/arena/arena_root.gd`: resolves the named profile before configuring `RewardCalculator`.
- `scripts/rl/environment_bridge.gd`: exposes executor facts necessary to audit profile rewards without leaking private state.
- `training/rl/tactical_online_trainer.py`: passes reward profile to Godot and aggregates profile instrumentation.
- `training/train_pipeline.py`: maps JSON plan `reward_profile_id` into `TacticalOnlineConfig`.
- `training/configs/rewards/*.json`: human-readable parameter source for both profiles.
- `training/configs/training_plans/*.json`: diagnostic PPO plans with semantic names.
- `training/configs/multi_gpu/*.json`: eight independent, BC-based diagnostic workers with semantic output paths.
- `tests/unit/test_tactical_online_trainer.py`, `tests/unit/test_train_pipeline.py`, `tests/smoke/tactical_training_protocol_check.py`: profile transport and attribution regression coverage.

## Task 1: Safe pre-draw-fix archive

**Files:**
- Create: `scripts/training/archive_pre_draw_fix_runs.py`
- Create: `tests/unit/test_archive_pre_draw_fix_runs.py`
- Create: `training/runs/archived/pre_draw_fix/README.md`
- Modify: `docs/training/status/tactical-rl-progress.md`

**Interfaces:**
- Produces `build_archive_plan(root: Path) -> list[tuple[Path, Path]]` and `apply_archive_plan(plan: list[tuple[Path, Path]]) -> None`.
- The allowlist contains only the historical `hybrid_tactical_v2_*` pilot/diagnostic/expanded/resume run directories and 20260802 evaluation directories.
- Destinations live under `training/runs/archived/pre_draw_fix/`; destination collisions raise `FileExistsError`.

- [ ] **Step 1: Write the failing archive-selection tests**

```python
def test_archive_plan_moves_only_pre_draw_fix_runs(tmp_path: Path) -> None:
    root = make_training_tree(tmp_path)
    plan = build_archive_plan(root)
    sources = {source.relative_to(root).as_posix() for source, _ in plan}
    assert "training/runs/hybrid_tactical_v2_ppo_pilot" in sources
    assert "training/runs/evaluations/hybrid_tactical_v2_ppo_resume_candidate_20260802_paired_dev8" in sources
    assert all("20260804" not in source for source in sources)

def test_archive_plan_never_targets_catalog_or_checkpoint(tmp_path: Path) -> None:
    root = make_training_tree(tmp_path)
    plan = build_archive_plan(root)
    assert all("training/models" not in str(source) for source, _ in plan)
    assert all("training/checkpoints" not in str(source) for source, _ in plan)
```

- [ ] **Step 2: Run the archive tests and verify RED**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_archive_pre_draw_fix_runs -v`

Expected: import failure because the archive module does not yet exist.

- [ ] **Step 3: Implement a fixed allowlist and dry-run/apply CLI**

```python
ARCHIVE_SOURCES = (
    "hybrid_tactical_v2_ppo_pilot",
    "hybrid_tactical_v2_8gpu_parallel_pilot",
    "hybrid_tactical_v2_reward_diagnostic_2048",
    "hybrid_tactical_v2_8gpu_foundation_diagnostic_8192",
    "hybrid_tactical_v2_audit_explainability_smoke",
    "hybrid_tactical_v2_audit_explainability_smoke_v2",
    "hybrid_tactical_v2_8gpu_bc_warmstart_diagnostic_8192",
    "hybrid_tactical_v2_8gpu_bc_warmstart_expanded_65536",
    "hybrid_tactical_v2_8gpu_ppo_resume_expanded_262144",
)

def apply_archive_plan(plan: list[tuple[Path, Path]]) -> None:
    for source, destination in plan:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            raise FileExistsError(destination)
        source.rename(destination)
```

The CLI defaults to printing source/destination pairs; require `--apply` to move files.

- [ ] **Step 4: Run archive tests and dry-run against the repository**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_archive_pre_draw_fix_runs -v`

Run: `PYTHONPATH=. .conda/bin/python scripts/training/archive_pre_draw_fix_runs.py --root .`

Expected: tests pass; dry-run lists only protected-safe sources.

- [ ] **Step 5: Apply the reviewed migration and write archive provenance**

Run: `PYTHONPATH=. .conda/bin/python scripts/training/archive_pre_draw_fix_runs.py --root . --apply`

Write the README explaining the draw-as-win defect, preserved assets, and the retained 20260804 post-fix evaluations.

- [ ] **Step 6: Verify migration invariants and commit**

Run: `test -f training/checkpoints/hybrid/hybrid_tactical_v2_ppo_resume_candidate_20260802.pt && PYTHONPATH=. .conda/bin/python scripts/training/archive_pre_draw_fix_runs.py --root .`

Expected: deployed checkpoint remains; a second dry-run reports no pending moves.

```bash
git add scripts/training/archive_pre_draw_fix_runs.py tests/unit/test_archive_pre_draw_fix_runs.py training/runs/archived/pre_draw_fix/README.md docs/training/status/tactical-rl-progress.md
git commit -m "chore: archive pre draw fix training runs"
```

## Task 2: Profile transport and named reward resolution

**Files:**
- Modify: `scripts/config/match_config.gd`
- Modify: `scripts/config/reward_config.gd`
- Modify: `scripts/arena/arena_root.gd`
- Modify: `tests/unit/tactical_training_protocol_test.gd`
- Modify: `tests/smoke/tactical_training_protocol_check.py`

**Interfaces:**
- `MatchConfig.reward_profile_id: String` defaults to `"baseline"`.
- `RewardConfig.for_profile(profile_id: String) -> RewardConfig` returns an independent configured copy and rejects unknown names with an empty/default profile plus explicit warning.
- `ArenaRoot` configures `RewardCalculator` with `RewardConfig.default().for_profile(config.reward_profile_id)`.

- [ ] **Step 1: Add a failing profile round-trip test**

```gdscript
func _test_reward_profile_round_trip() -> int:
    var config := MatchConfig.new()
    config.reward_profile_id = "legal_window_pressure"
    var restored := MatchConfig.from_dict(config.to_dict())
    return 0 if restored.reward_profile_id == "legal_window_pressure" else 1
```

Add a TCP smoke reset payload with `"reward_profile_id": "score_margin_discipline"` and assert the returned `info` reports that profile.

- [ ] **Step 2: Run Godot/TCP checks and verify RED**

Run: `HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --disable-crash-handler --path . --script tests/run_tests.gd`

Expected: failure because `reward_profile_id` is absent.

- [ ] **Step 3: Add profile transport and profile-specific constants**

Add to `MatchConfig` duplicate, `to_dict`, and `from_dict`:

```gdscript
@export var reward_profile_id: String = "baseline"
```

Add `for_profile` to `RewardConfig` with named constants for `baseline`, `legal_window_pressure`, and `score_margin_discipline`. Keep baseline numerical behavior unchanged.

- [ ] **Step 4: Configure the profile at match start and expose only the ID**

At `ArenaRoot._start_match`, replace the default reward configuration call with the resolved profile. Add only `reward_profile_id` to safe training info; do not expose private opponent state.

- [ ] **Step 5: Run regression checks and commit**

Run: Godot unit test command from Step 2.

Run: `HOME="$PWD/.tools/godot-user" python3 tests/smoke/tactical_training_protocol_check.py --godot .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --port 18768`

```bash
git add scripts/config/match_config.gd scripts/config/reward_config.gd scripts/arena/arena_root.gd scripts/rl/environment_bridge.gd tests/unit/tactical_training_protocol_test.gd tests/smoke/tactical_training_protocol_check.py
git commit -m "feat: add named tactical reward profiles"
```

## Task 3: Realized engagement and outcome reward attribution

**Files:**
- Modify: `scripts/rl/reward_calculator.gd`
- Modify: `scripts/agents/hybrid/hybrid_agent_controller.gd`
- Modify: `scripts/rl/environment_bridge.gd`
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `tests/unit/test_tactical_online_trainer.py`
- Modify: `tests/smoke/tactical_training_protocol_check.py`

**Interfaces:**
- `RewardCalculator.on_tactical_execution(player_id: int, decision: Dictionary, diagnostics: Dictionary) -> void` adds only decision-attributable shaping components.
- `RewardCalculator.on_damage` remains the sole source of actual damage reward.
- Snapshot diagnostics expose `fire_allowed`, `fire_block_reason`, `target_valid`, `safety_override`, and `reward_profile_id` only.

- [ ] **Step 1: Write failing audit tests**

```python
def test_audit_counts_fire_allowed_and_profile_components() -> None:
    audit = initial_audit("legal_window_pressure")
    update_transition_audit(audit, player_data_with_fire_allowed())
    assert audit["reward_profile_id"] == "legal_window_pressure"
    assert audit["fire_allowed_count"] == 1
    assert audit["profile_reward_components"]["legal_window_damage"] > 0
```

Add a smoke assertion that a blocked fire decision never receives `legal_window_damage`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v`

Expected: missing audit fields/component.

- [ ] **Step 3: Implement profile shaping using realized executor facts**

Implement these components in `RewardCalculator`:

```text
legal_window_pressure:
  legal_window_damage: +0.03 * actual_damage (existing on_damage remains base damage)
  legal_window_commitment: +0.01 only when fire_allowed and target_valid
  missed_legal_window: -0.02 only when fire_mode is HOLD_FIRE or CONSERVATIVE while fire_allowed
  avoidable_override: -0.03 when safety_override is true and override_reason is not emergency_projectile

score_margin_discipline:
  efficient_damage: +0.02 * actual_damage
  unfavorable_exchange: -0.02 * actual_damage_taken
  avoidable_override: -0.02 under the same criterion
  positive_score_margin: +0.25 only at match finish for a true positive margin
```

Do not issue an engagement bonus merely because an action intent was blocked; log block reasons instead.

- [ ] **Step 4: Aggregate attribution metrics in the Python trainer**

Persist `reward_profile_id`, `fire_intent_count`, `fire_allowed_count`, `fire_block_reasons`, `target_change_count`, `safety_override_reasons`, `draw_count`, and score-margin components in `rollout_audit.json`.

- [ ] **Step 5: Run targeted unit and TCP smoke tests**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_tactical_online_trainer tests.unit.test_evaluate_tactical_candidate -v`

Run: TCP smoke command from Task 2.

- [ ] **Step 6: Commit**

```bash
git add scripts/rl/reward_calculator.gd scripts/agents/hybrid/hybrid_agent_controller.gd scripts/rl/environment_bridge.gd training/rl/tactical_online_trainer.py tests/unit/test_tactical_online_trainer.py tests/smoke/tactical_training_protocol_check.py
git commit -m "feat: reward realized tactical engagement"
```

## Task 4: Two semantic training plans and diagnostic matrix

**Files:**
- Create: `training/configs/rewards/legal_window_pressure.json`
- Create: `training/configs/rewards/score_margin_discipline.json`
- Create: `training/configs/training_plans/tactical_legal_window_pressure.json`
- Create: `training/configs/training_plans/tactical_score_margin_discipline.json`
- Create: `training/configs/multi_gpu/legal_window_pressure_diagnostic.json`
- Create: `training/configs/multi_gpu/score_margin_discipline_diagnostic.json`
- Modify: `training/rl/tactical_online_trainer.py`
- Modify: `training/train_pipeline.py`
- Modify: `tests/unit/test_train_pipeline.py`
- Modify: `training/README.md`

**Interfaces:**
- `TacticalOnlineConfig.reward_profile_id: str = "baseline"`.
- `make_tactical_match_config` writes `"reward_profile_id": config.reward_profile_id`.
- New plans use `bc_checkpoint=training/runs/hybrid_tactical_bc/best_tactical_policy.pt`, `resume_checkpoint` omitted, one 90-second 1v1 Dungeon diagnostic stage, and semantic output paths.

- [ ] **Step 1: Write failing plan-transport tests**

```python
def test_tactical_ppo_dry_run_includes_reward_profile_id() -> None:
    plan = {"profile_id": "local_constrained", "tactical_ppo": {"enabled": True, "reward_profile_id": "legal_window_pressure"}}
    output = capture_run_tactical_ppo(plan, execute=False)
    assert output["tactical_ppo"]["reward_profile_id"] == "legal_window_pressure"
```

- [ ] **Step 2: Run focused test and verify RED**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline -v`

Expected: configuration does not yet expose the profile ID.

- [ ] **Step 3: Implement config plumbing and create plans**

Add `reward_profile_id` to `TacticalOnlineConfig`, `make_tactical_match_config`, persisted config, and `run_tactical_ppo`. Each plan uses the same seed family, rollout length, total environment steps, and only differs by profile ID/output path. Eight-worker files use one GPU per worker and distinct ports.

- [ ] **Step 4: Validate both plans without executing**

Run:

```bash
.conda/bin/python training/train_pipeline.py --profile local_constrained --plan tactical_legal_window_pressure --phase ppo
.conda/bin/python training/train_pipeline.py --profile local_constrained --plan tactical_score_margin_discipline --phase ppo
```

Expected: each dry-run prints BC base, semantic output path, and the intended reward profile; no resume checkpoint.

- [ ] **Step 5: Run unit tests and commit**

Run: `PYTHONPATH=. .conda/bin/python -m unittest tests.unit.test_train_pipeline tests.unit.test_tactical_online_trainer -v`

```bash
git add training/configs/rewards training/configs/training_plans training/configs/multi_gpu training/rl/tactical_online_trainer.py training/train_pipeline.py tests/unit/test_train_pipeline.py training/README.md
git commit -m "feat: add dual tactical training diagnostics"
```

## Task 5: Controlled diagnostics and comparison report

**Files:**
- Create: `docs/training/status/legal-window-pressure-vs-score-margin-discipline-<date>.md`
- Create generated outputs: `training/runs/legal_window_pressure/` and `training/runs/score_margin_discipline/`
- Create generated evaluations beneath `training/runs/evaluations/`

**Interfaces:**
- Each diagnostic starts from the same BC checkpoint and produces `config.json`, `metrics.jsonl`, `rollout_audit.json`, `best_tactical_ppo.pt`, and `last_tactical_ppo.pt`.
- The comparison report labels findings as fixed-seed evidence, training-audit evidence, or open uncertainty.

- [ ] **Step 1: Verify GPU and protocol readiness**

Run: `.conda/bin/python -c "import torch; assert torch.cuda.is_available(); assert torch.cuda.device_count() >= 1"`

Run: TCP smoke command from Task 2.

- [ ] **Step 2: Execute identical bounded diagnostics**

Run each profile’s multi-GPU diagnostic with `--execute`; do not use `resume_checkpoint`.

- [ ] **Step 3: Execute fixed-seed 90-second paired evaluation for each selected worker checkpoint**

Use `training/evaluate_tactical_candidate.py --runner godot-service`; write separate output directories per profile. A failed promotion gate does not invalidate the generated report.

- [ ] **Step 4: Write the comparison report**

Report true win/non-draw rates, score margin, damage, legal-window conversion, fire-block reason distribution, fire-mode distribution, fallback, safety override, environment death, and checkpoint provenance. Explicitly state whether either profile qualifies for a longer run.

- [ ] **Step 5: Run final verification and commit source/docs only**

Run: `PYTHONPATH=. .conda/bin/python -m unittest discover -s tests/unit -v`

Run: `git diff --check`

Commit code/config/test/doc changes only; generated runs stay ignored.

## Plan Self-Review

- Spec coverage: Task 1 implements safe archive and protected assets; Tasks 2-4 implement profile transport, realized shaping, semantic plans, and named output; Task 5 supplies controlled comparison and gates.
- Placeholder scan: no unresolved implementation placeholders; all task interfaces, commands, and requested fields are explicit.
- Type consistency: `reward_profile_id` is a `String` in Godot and `str` in Python; both profile IDs use exactly `legal_window_pressure` and `score_margin_discipline`.
