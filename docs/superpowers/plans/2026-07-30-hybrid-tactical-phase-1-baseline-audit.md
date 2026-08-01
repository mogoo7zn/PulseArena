# Hybrid Tactical Phase 1 Baseline Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a machine-readable audit that verifies Hybrid Tactical v2 configuration consistency and distinguishes code failures from unavailable GPU prerequisites.

**Architecture:** Enhance the dependency-light server preflight so CUDA-required runs verify both NVIDIA driver visibility and PyTorch CUDA. Add a baseline-audit CLI that compares Python constants, Godot constants, model manifest, model catalog, and local plan without importing PyTorch.

**Tech Stack:** Python 3.10+, standard-library `unittest`, JSON, current Godot project files.

## Global Constraints

- Godot deterministic code remains responsible for aim, movement execution, fire gates, safety overrides, and fallback; learned policy output remains high-level protocol-v2 decisions.
- Protocol version is `2`; tactical feature schema version is `2`; tactical feature dimension is `142`.
- Baseline model is `hybrid_tactical_v1`, kind `hybrid_tactical_prior`, protocol `2`, input dimension `142`.
- Commands must report missing `torch`, Godot, CUDA, or `nvidia-smi` without crashing.
- `--require-cuda` must fail if NVIDIA driver visibility or PyTorch CUDA is unavailable.
- This workspace has no Git metadata. Do not commit; use explicit JSON reports and test output as evidence.

---

## File Structure

- Create `training/baseline_audit.py`: standard-library v2 contract audit and CLI.
- Create `tests/unit/test_training_preflight.py`: CUDA prerequisite tests.
- Create `tests/unit/test_baseline_audit.py`: audit and Makefile command tests.
- Modify `training/server_agent/preflight.py`: report CUDA prerequisite state.
- Modify `Makefile`: expose `train-baseline-audit`.
- Modify `training/README.md`: document Phase 1 commands and exit codes.

### Task 1: Classify GPU-driver availability in the existing preflight

**Files:**

- Create `tests/unit/test_training_preflight.py`
- Modify `training/server_agent/preflight.py:64-126`

**Interfaces:**

- Consumes `build_report(args: argparse.Namespace) -> tuple[dict[str, Any], list[str]]`.
- Produces `report["cuda_requirements"]` with boolean keys `nvidia_smi_ok` and `torch_cuda_available`.

- [ ] **Step 1: Write the failing tests**

```python
from __future__ import annotations
import argparse, importlib.util, unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "training/server_agent/preflight.py"

def load_module():
    spec = importlib.util.spec_from_file_location("training_preflight", PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class TrainingPreflightTests(unittest.TestCase):
    def test_require_cuda_lists_driver_and_torch_failures(self):
        module = load_module()
        answers = {("godot", "--version"): {"ok": True}, ("nvidia-smi", "-L"): {"ok": False}}
        with patch.object(module, "run_command", side_effect=lambda command: answers[tuple(command)]), patch.object(module, "module_present", side_effect=lambda name: name != "torch"), patch.object(module, "torch_info", return_value={"installed": False, "cuda_available": False, "devices": []}):
            report, failures = module.build_report(argparse.Namespace(godot="godot", require_cuda=True))
        self.assertFalse(report["cuda_requirements"]["nvidia_smi_ok"])
        self.assertFalse(report["cuda_requirements"]["torch_cuda_available"])
        self.assertIn("NVIDIA driver is unavailable; nvidia-smi must succeed before GPU training", failures)
        self.assertIn("PyTorch CUDA is not available; do not run the A100 training pilot", failures)
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `python -m unittest tests.unit.test_training_preflight.TrainingPreflightTests.test_require_cuda_lists_driver_and_torch_failures -v`

Expected: FAIL because `cuda_requirements` is absent.

- [ ] **Step 3: Implement the report extension**

Immediately after computing `nvidia_status` in `build_report`, add:

```python
    cuda_requirements = {
        "nvidia_smi_ok": bool(nvidia_status.get("ok", False)),
        "torch_cuda_available": bool(torch_status.get("cuda_available", False)),
    }
    if args.require_cuda and not cuda_requirements["nvidia_smi_ok"]:
        failures.append("NVIDIA driver is unavailable; nvidia-smi must succeed before GPU training")
    if args.require_cuda and not cuda_requirements["torch_cuda_available"]:
        failures.append("PyTorch CUDA is not available; do not run the A100 training pilot")
```

Add `"cuda_requirements": cuda_requirements` to the JSON report. Replace the previous CUDA-only failure branch so the PyTorch reason is produced once.

- [ ] **Step 4: Verify focused and live behavior**

Run: `python -m unittest tests.unit.test_training_preflight -v && python training/server_agent/preflight.py --require-cuda`

Expected: tests PASS; live command exits `2` on this machine with driver and PyTorch evidence, not a traceback.

### Task 2: Add a standard-library protocol-v2 baseline audit

**Files:**

- Create `tests/unit/test_baseline_audit.py`
- Create `training/baseline_audit.py`

**Interfaces:**

- Consumes the project root and active `encoding.py`, `tactical_decision.gd`, `tactical_feature_builder.gd`, `hybrid_tactical_v1_agent.json`, `model_catalog.json`, and `hybrid_tactical_local.json`.
- Produces `build_report(root: Path) -> dict[str, Any]`; CLI exits `0` on pass and `2` on failure.

- [ ] **Step 1: Write failing contract tests**

```python
from __future__ import annotations
import importlib.util, json, unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "training/baseline_audit.py"

def load_module():
    spec = importlib.util.spec_from_file_location("baseline_audit", PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class BaselineAuditTests(unittest.TestCase):
    def test_live_project_contract_passes(self):
        report = load_module().build_report(ROOT)
        self.assertEqual(report["result"], "pass")
        self.assertEqual(report["checks"]["python_feature_dim"], 142)
        self.assertEqual(report["checks"]["godot_protocol"], 2)

    def test_manifest_dimension_mismatch_fails(self):
        module = load_module()
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ("training/models", "training/configs/training_plans", "training/rl", "scripts/agents/hybrid"):
                (root / relative).mkdir(parents=True, exist_ok=True)
            (root / "training/models/model_catalog.json").write_text(json.dumps({"default_model_id": "hybrid_tactical_v1", "models": [{"model_id": "hybrid_tactical_v1", "manifest": "training/models/hybrid_tactical_v1_agent.json", "protocol": 2}]}), encoding="utf-8")
            (root / "training/models/hybrid_tactical_v1_agent.json").write_text(json.dumps({"model_id": "hybrid_tactical_v1", "kind": "hybrid_tactical_prior", "input_dim": 141, "protocol": 2}), encoding="utf-8")
            (root / "training/configs/training_plans/hybrid_tactical_local.json").write_text(json.dumps({"tactical_behavior_clone": {"enabled": True}}), encoding="utf-8")
            (root / "training/rl/encoding.py").write_text("HYBRID_PROTOCOL_VERSION = 2\\nTACTICAL_FEATURE_SCHEMA_VERSION = 2\\nTACTICAL_FEATURE_DIM = 142\\n", encoding="utf-8")
            (root / "scripts/agents/hybrid/tactical_decision.gd").write_text("const PROTOCOL_VERSION: int = 2\\n", encoding="utf-8")
            (root / "scripts/agents/hybrid/tactical_feature_builder.gd").write_text("const FEATURE_DIM: int = 142\\n", encoding="utf-8")
            report = module.build_report(root)
        self.assertEqual(report["result"], "fail")
        self.assertIn("manifest input_dim 141 does not equal Python feature dimension 142", report["failures"])
```

- [ ] **Step 2: Run tests and confirm initial failure**

Run: `python -m unittest tests.unit.test_baseline_audit -v`

Expected: FAIL because `training/baseline_audit.py` is absent.

- [ ] **Step 3: Implement the audit module**

Implement this public helper and use it for Python and Godot declarations:

```python
def read_int_constant(path: Path, name: str) -> int:
    match = re.search(rf"{re.escape(name)}\\s*(?::\\s*int)?\\s*(?::=|=)\\s*(\\d+)", path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"{path}: missing integer constant {name}")
    return int(match.group(1))
```

`build_report` must return `schema_version`, `root`, `checks`, `failures`, and `result`. `checks` contains: `python_protocol`, `python_feature_schema`, `python_feature_dim`, `godot_protocol`, `godot_feature_dim`, `manifest_model_id`, `manifest_kind`, `manifest_protocol`, `manifest_input_dim`, `catalog_default_model_id`, `catalog_protocol`, and `tactical_bc_enabled`.

Append exact failures for these bad states: Python protocol/schema/dimension is not `2`/`2`/`142`; Godot protocol or feature dimension differs from Python; manifest model id is not `hybrid_tactical_v1`, kind is not `hybrid_tactical_prior`, protocol differs, or input dimension differs; catalog default id or entry protocol differs; local plan disables tactical BC. In particular dimension failure text must be `manifest input_dim <actual> does not equal Python feature dimension <actual>`.

Add `--root` defaulting to the project root and optional `--output PATH`. Print indented JSON; write exactly that JSON plus a newline when output is requested.

- [ ] **Step 4: Verify unit and live audit**

Run: `python -m unittest tests.unit.test_baseline_audit -v && python training/baseline_audit.py`

Expected: tests PASS; live command emits `"result": "pass"` or exits `2` with an exact inconsistency.

- [ ] **Step 5: Preserve baseline evidence after pass**

Run: `python training/baseline_audit.py --output test-results/hybrid-baseline-audit.json`

Expected: exit `0` and report file created. A failure must be repaired before a passing evidence file is used to advance the project.

### Task 3: Expose and document Phase 1 checks

**Files:**

- Modify `tests/unit/test_baseline_audit.py`
- Modify `Makefile:3-25`
- Modify `training/README.md:20-58`

**Interfaces:**

- Consumes `training/baseline_audit.py` and the existing preflight CLI.
- Produces `make train-baseline-audit` and a documented GPU-training stop condition.

- [ ] **Step 1: Add the failing Makefile test**

```python
    def test_makefile_exposes_baseline_audit_target(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("train-baseline-audit:", makefile)
        self.assertIn("$(PYTHON) training/baseline_audit.py", makefile)
```

- [ ] **Step 2: Run test and verify failure**

Run: `python -m unittest tests.unit.test_baseline_audit.BaselineAuditTests.test_makefile_exposes_baseline_audit_target -v`

Expected: FAIL because the target is absent.

- [ ] **Step 3: Add command and documentation**

Add `train-baseline-audit` to `.PHONY` and the help string, then add:

```make
train-baseline-audit:
	$(PYTHON) training/baseline_audit.py
```

Add a `## Phase 1 Baseline Audit` section before `## Local Workflow` in `training/README.md` containing both commands below and their exit conditions:

```bash
make train-baseline-audit
python training/server_agent/preflight.py --require-cuda
```

Document that the first command returns `0` when Python, Godot, manifest, catalog, and local plan agree, without requiring CUDA; the second returns `0` only when project prerequisites, Godot, NVIDIA driver visibility, and PyTorch CUDA are all available. State that exit `2` stops GPU training.

- [ ] **Step 4: Run final Phase 1 verification**

Run: `python -m unittest tests.unit.test_training_preflight tests.unit.test_baseline_audit -v && make train-baseline-audit && python training/server_agent/preflight.py --require-cuda`

Expected: unit tests and baseline audit PASS. Current CUDA preflight exits `2` with driver and PyTorch evidence, not an exception.

- [ ] **Step 5: Record non-Git handoff state**

Run: `git rev-parse --is-inside-work-tree`

Expected: command fails because this workspace is not a Git repository. Leave files uncommitted, list changed files in the handoff, and retain `test-results/hybrid-baseline-audit.json` as evidence.

## Plan Self-Review

- Spec coverage: Task 1 isolates GPU prerequisites; Task 2 validates all v2 contract surfaces; Task 3 supplies repeatable commands and a clear stop/go rule.
- Placeholder scan: tasks name files, interfaces, test content, commands, expected outcomes, and report fields.
- Type consistency: `build_report(root: Path) -> dict[str, Any]` is shared by CLI and unit tests; `cuda_requirements` consistently has two booleans.
