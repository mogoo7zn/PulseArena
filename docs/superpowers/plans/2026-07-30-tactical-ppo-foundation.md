# Tactical PPO Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the single-worker, protocol-v2 foundation required to fine-tune the Hybrid Tactical high-level policy with masked PPO and evaluate it safely on fixed seeds.

**Architecture:** Godot exposes a separate tactical step API that emits the runtime-built 142-feature vector and masks, accepts `HighLevelDecision` dictionaries, and executes them through `HybridCombatExecutor`. Python adds a masked four-head actor-critic, GAE/PPO rollout logic, fixed-seed evaluation gates, and reproducible Chinese run records; raw-action PPO remains unchanged and excluded from this path.

**Tech Stack:** Godot 4.7/GDScript, Python 3.10, PyTorch CUDA, JSONL TCP, unittest, existing headless Godot smoke runner.

## Global Constraints

- The actor consumes only the Godot-returned 142-dimensional `tactical_features` and four action masks; it never consumes private Arena state.
- Tactical actions are `target_slot(7)`, `movement_mode(12)`, `fire_mode(6)`, and `skill_mode(6)` under protocol `2`.
- Godot must route tactical decisions through `HybridCombatExecutor`; the new trainer must never call legacy raw `step`.
- Invalid actions are masked in sampling and PPO log-probability, not merely corrected afterward.
- PPO uses terminated/truncated-aware GAE-lambda and bootstrap; BC checkpoint warm start is optional and never auto-promotes a catalog model.
- CUDA uses project `.conda`; do not reboot or modify NVIDIA drivers.
- Candidate evaluation is holdout-seed based; only reports are generated, never `--promote-default`.
- Add or update Chinese operational documentation under `docs/training/`.
- This directory has no Git metadata: do not assume commits/worktrees; retain subagent reports, tests and artifacts in the plan ledger.

---

### Task 1: Replay group split and tactical data-quality gate

**Files:**
- Create: `training/server_agent/tactical_data_quality.py`
- Create: `tests/unit/test_tactical_data_quality.py`
- Modify: `training/rl/tactical_bc_trainer.py`
- Modify: `docs/training/高层战术强化学习训练方案.md`

**Interfaces:**
- Consumes: `hybrid_replay_v2` JSONL rows with `episode_id`, `random_seed`, `tactical_features`, `action_masks`, `teacher_decision`, `fallback_used`.
- Produces: `build_episode_split(rows, holdout_ratio, seed) -> dict[str, set[str]]` and `audit_tactical_data(replay_dir, output) -> dict`.
- The BC trainer consumes the returned episode split and uses only train episode ids for optimisation and dev episode ids for validation.

- [ ] **Step 1: Write failing Python unit tests**

```python
def test_episode_split_never_places_one_episode_in_two_partitions():
    rows = [{"episode_id": "e1"}, {"episode_id": "e1"}, {"episode_id": "e2"}]
    split = build_episode_split(rows, holdout_ratio=0.5, seed=7)
    assert split["train"].isdisjoint(split["dev"])
    assert "e1" in split["train"] or "e1" in split["dev"]

def test_audit_fails_when_a_head_has_no_label_coverage(tmp_path):
    report = audit_tactical_data(tmp_path, tmp_path / "report.json")
    assert report["result"] == "fail"
```

- [ ] **Step 2: Run the targeted test to confirm failure**

Run: `.conda/bin/python -m unittest tests.unit.test_tactical_data_quality -v`

Expected: FAIL because the module and functions do not exist.

- [ ] **Step 3: Implement group split and quality audit**

Implement deterministic episode/seed grouping. Emit row count, episode count, map/mode coverage, each head label histogram, fallback rate, duplicate decision rate and explicit failures for missing input, malformed rows, missing legal labels and absent head coverage. Extend BC configuration with `split_mode="episode"` as the default and record split statistics in its returned result.

- [ ] **Step 4: Run unit tests and a real audit**

Run:

```bash
.conda/bin/python -m unittest tests.unit.test_tactical_data_quality -v
.conda/bin/python training/server_agent/tactical_data_quality.py \
  --replay-dir training/replays \
  --output training/runs/tactical_data_quality.json
```

Expected: tests pass and the JSON report states whether the current dataset is eligible for BC/RL warm start without modifying the catalog.

- [ ] **Step 5: Document the exact split and gate semantics in Chinese**

Add the generated-report location, group split rule and disqualification conditions to `docs/training/高层战术强化学习训练方案.md`.

### Task 2: Godot protocol-v2 tactical training step API

**Files:**
- Modify: `scripts/rl/training_server.gd`
- Modify: `scripts/rl/environment_bridge.gd`
- Modify: `scripts/arena/arena_root.gd`
- Modify: `tests/run_tests.gd`
- Create: `tests/unit/tactical_training_protocol_test.gd`

**Interfaces:**
- Consumes TCP JSONL `{cmd:"observe_tactical"}` and `{cmd:"step_tactical", decisions:{player_id: HighLevelDecision dict}, ticks:int}`.
- Produces snapshots with `protocol:2`, per-player `tactical_features`, `action_masks`, `executed_decision`, `reward_delta`, `terminated`, `truncated`, and safe diagnostics.
- `EnvironmentBridge.apply_tactical_decisions(decisions)` must apply masks and invoke the existing hybrid executor path; it must not call raw `apply_training_actions`.

- [ ] **Step 1: Add failing Godot tests**

```gdscript
func test_tactical_snapshot_has_runtime_feature_schema() -> void:
    var snapshot := bridge.get_tactical_snapshot()
    assert_eq((snapshot["players"][0] as Dictionary)["tactical_features"].size(), 142)
    assert_true((snapshot["players"][0] as Dictionary).has("action_masks"))

func test_tactical_step_rejects_raw_action_payload() -> void:
    assert_false(bridge.apply_tactical_decisions({0: {"move_x": 1.0}}))
```

- [ ] **Step 2: Run Godot tests to confirm failure**

Run: `.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --path . --script tests/run_tests.gd`

Expected: FAIL because tactical snapshot and decision application methods do not exist.

- [ ] **Step 3: Implement the tactical-only bridge and server commands**

Build features using the same `TacticalFeatureBuilder` and current decision state used at runtime. Parse each decision with `HighLevelDecision.from_dict`, call `apply_masks`, execute through the existing hybrid controller/executor seam, and return each player’s actual decision plus diagnostics. Retain `step` unchanged for legacy tests; reject raw fields in `step_tactical` with a JSON error.

- [ ] **Step 4: Run Godot protocol tests and TCP smoke**

Run the Godot suite and a Python `GodotStepEnv` smoke that sends `observe_tactical` and `step_tactical` on one two-player dungeon match. Assert protocol `2`, 142 features, all four masks and a legal returned decision.

### Task 3: Masked tactical actor-critic, GAE and PPO update

**Files:**
- Modify: `training/rl/models.py`
- Create: `training/rl/tactical_ppo.py`
- Create: `tests/unit/test_tactical_ppo.py`

**Interfaces:**
- `TacticalActorCritic(input_dim=142, hidden=192, recurrent=True)` returns four logits dictionaries, scalar values and optional GRU hidden state.
- `sample_masked_tactical_actions(outputs, masks) -> TacticalActionBatch` returns legal actions, joint log-probability and joint entropy.
- `compute_gae(rewards, values, terminated, truncated, bootstrap_value, gamma, gae_lambda)` returns returns and advantages.
- `MaskedTacticalPPOTrainer.update(batch)` consumes actions, masks, old log-probs, values, returns, advantages and optional sequence boundaries.

- [ ] **Step 1: Write failing unit tests**

```python
def test_masked_sampler_never_selects_an_illegal_action():
    actions = sample_masked_tactical_actions(outputs, masks)
    assert masks["fire_mode"][0, actions.fire_mode[0]]

def test_gae_stops_bootstrap_at_terminal_transition():
    returns, advantages = compute_gae(rewards, values, terminated, truncated, bootstrap_value=10.0, gamma=0.99, gae_lambda=0.95)
    assert returns[-1].item() == rewards[-1].item()
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `.conda/bin/python -m unittest tests.unit.test_tactical_ppo -v`

Expected: FAIL because the tactical PPO module does not exist.

- [ ] **Step 3: Implement model and trainer**

Use four categorical distributions with logits masked before both sampling and `log_prob`. Sum per-head log-probabilities and entropy. Implement GAE with terminated versus truncated semantics, advantage normalization, clipped policy/value objectives, entropy term, KL and clip-fraction metrics, AMP and gradient clipping. Load BC actor heads only when checkpoint feature/action dimensions match exactly.

- [ ] **Step 4: Run tests and CUDA micro-update**

Run the new unit suite and a one-batch CUDA update with synthetic legal masks. Assert finite loss, finite KL and no sampled illegal action.

### Task 4: Single-worker tactical PPO runner and pipeline entry

**Files:**
- Modify: `training/rl/godot_env.py`
- Create: `training/rl/tactical_online_trainer.py`
- Modify: `training/train_pipeline.py`
- Create: `training/configs/training_plans/hybrid_tactical_v2_ppo_pilot.json`
- Create: `tests/unit/test_tactical_online_trainer.py`

**Interfaces:**
- `GodotStepEnv.observe_tactical()` and `GodotStepEnv.step_tactical(decisions, ticks)` use only the v2 commands.
- `train_tactical_ppo(TacticalPPOConfig)` writes `best_tactical_ppo.pt`, `last_tactical_ppo.pt`, `metrics.jsonl`, `config.json` and `rollout_audit.json`.
- Pipeline `--plan hybrid_tactical_v2_ppo_pilot --phase ppo --execute` invokes the new trainer; legacy plans remain disabled.

- [ ] **Step 1: Write failing runner tests with a fake tactical environment**

```python
def test_runner_sends_high_level_decisions_not_raw_actions(tmp_path):
    result = train_tactical_ppo(config, env_factory=FakeTacticalEnv)
    assert FakeTacticalEnv.received_tactical_steps > 0
    assert not FakeTacticalEnv.received_raw_steps
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `.conda/bin/python -m unittest tests.unit.test_tactical_online_trainer -v`

Expected: FAIL because the tactical runner does not exist.

- [ ] **Step 3: Implement bounded pilot runner**

Collect legal tactical rollouts from one Godot worker, preserve episode boundaries and hidden state, calculate reward deltas from explicit reward components, checkpoint on a fixed dev metric, and write all configuration/seeds. The pilot plan must use `01_foundation_combat`, two agents, fixed seed, CUDA, bounded total environment steps and no catalog update.

- [ ] **Step 4: Verify fake-env tests, Godot integration smoke and CUDA pilot**

Run unit tests, one short headless tactical-step integration run, then a bounded CUDA pilot. Confirm artifacts contain protocol `2`, device `cuda`, finite PPO metrics and no legacy raw-action request.

### Task 5: Fixed-seed evaluation and promotion report

**Files:**
- Create: `training/evaluate_tactical_candidate.py`
- Create: `tests/unit/test_evaluate_tactical_candidate.py`
- Modify: `training/configs/evaluation_matrix.json`
- Modify: `docs/training/高层战术强化学习训练方案.md`
- Create: `docs/training/高层战术训练运行与晋级指南.md`

**Interfaces:**
- `evaluate_candidate(manifest, matrix, output_dir, godot_bin) -> dict` runs only fixed seeds and writes `evaluation.json` plus `evaluation_report_zh.md`.
- Reads `evaluation_matrix.json` gates and emits explicit pass/fail for every gate; it never calls catalog promotion.

- [ ] **Step 1: Write failing evaluator tests**

```python
def test_gate_report_fails_when_holdout_environment_death_rate_is_too_high(tmp_path):
    report = evaluate_gate_summary(metrics={"holdout_environment_death_rate": 0.07}, gates={"holdout_max_environment_death_rate": 0.06})
    assert report["result"] == "fail"

def test_evaluator_uses_only_configured_holdout_seeds():
    assert selected_seeds(matrix, "holdout") == matrix["fixed_seed_sets"]["holdout"]
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `.conda/bin/python -m unittest tests.unit.test_evaluate_tactical_candidate -v`

Expected: FAIL because evaluator functions do not exist.

- [ ] **Step 3: Implement deterministic evaluation and Chinese reports**

Run paired candidate/baseline matches using the matrix’s map, mode and holdout seeds. Collect wins/ranks, environment deaths, empty-fire, fallback, safety override, latency and regressions. Produce exact gate values, input manifests, command lines and run timestamps in JSON and Chinese Markdown. Make catalog promotion a separate manual command outside this evaluator.

- [ ] **Step 4: Verify evaluator and publish operational documentation**

Run unit tests and a bounded one-map evaluation smoke. Ensure `docs/training/高层战术训练运行与晋级指南.md` contains preflight, collect, BC, PPO pilot, evaluation, artifact layout, failure diagnosis, resume and manual promotion steps.

## Deferred follow-on plan

After Tasks 1–5 pass, create a separate plan for multi-port Godot workers, curriculum scheduler, league archive opponent wiring and multi-GPU scaling. Those features depend on the single-worker tactical protocol and evaluation gate and must not be started before their pilot evidence exists.
