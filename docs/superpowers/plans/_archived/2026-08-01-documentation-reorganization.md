# Documentation Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize Pulse Arena documentation into a GitHub-friendly domain tree, add navigable indexes, update all internal Markdown links, and strengthen `.gitignore` without changing runtime code or synchronizing with GitHub.

**Architecture:** Keep documentation grouped by project domain: architecture, agents, game, training, operations, and design. Keep dated `docs/superpowers/plans/` and `docs/superpowers/specs/` as historical process records. Use English filesystem paths with existing Chinese document content preserved, and add root/domain README indexes as stable navigation surfaces.

**Tech Stack:** Markdown, Gitignore syntax, POSIX shell, Python 3 standard library for validation only.

## Global Constraints

- Do not configure, add, fetch, pull, push, or synchronize any GitHub remote.
- Do not change game, training, or tooling runtime code.
- Do not delete documentation; every current Markdown document must remain available at a new or explicitly preserved path.
- Preserve Chinese document titles and technical content unless a path/link update requires a targeted edit.
- Keep `docs/superpowers/plans/` and `docs/superpowers/specs/` dated filenames and contents unchanged.
- Use stable English filesystem names while allowing Chinese content inside documents.
- Keep `training/configs/`, tests, source code, and curated documentation trackable.
- Ignore local environments, generated outputs, private settings, model/checkpoint/replay artifacts, and editor/OS files.
- Because usable Git metadata is unavailable in this workspace, do not require commit or branch operations; record validation output in the final progress update.

---

### Task 1: Add Documentation Navigation Indexes

**Files:**
- Create: `docs/README.md`
- Create: `docs/architecture/README.md`
- Create: `docs/agents/README.md`
- Create: `docs/game/README.md`
- Create: `docs/training/README.md`
- Create: `docs/operations/README.md`
- Create: `docs/design/README.md`

**Interfaces:**
- Consumes: the migration map in `docs/superpowers/specs/2026-08-01-documentation-reorganization-design.md`.
- Produces: stable index paths that later migrated documents can link to.

- [ ] **Step 1: Write the root index content**

Create `docs/README.md` with:

```markdown
# Pulse Arena Documentation

## Start Here

- [Architecture](architecture/README.md)
- [Agent Interfaces](agents/README.md)
- [Game Design](game/README.md)
- [Training](training/README.md)
- [Operations](operations/README.md)
- [UI Design](design/README.md)

## Development Process

- [Plans](superpowers/plans/)
- [Specs](superpowers/specs/)

The dated `superpowers` documents are historical design and implementation records.
```

- [ ] **Step 2: Add one README per domain**

Each domain README must contain a one-sentence purpose, a “Primary Entry” link, and a flat list of all documents that will exist in that directory after migration. The training README must link separately to design, workflow, runbook, and status documents.

- [ ] **Step 3: Verify index targets**

Run:

```bash
rg -n '\]\([^)]+' docs/README.md docs/*/README.md
```

Expected: every link target is one of the planned destination paths; targets that are not created until Task 2 are documented in the migration map and verified after Task 2.

### Task 2: Move Documents to the Domain Tree

**Files:**
- Move: `docs/architecture.md` -> `docs/architecture/overview.md`
- Move: `docs/hybrid_agent_architecture_zh.md` -> `docs/architecture/hybrid-agent.md`
- Move: `docs/agent_interface.md` -> `docs/agents/interface.md`
- Move: `docs/model_agent_integration_zh.md` -> `docs/agents/model-integration.md`
- Move: `docs/game_design.md` -> `docs/game/design.md`
- Keep: `docs/game/skills.md`
- Move: `docs/agent_training_strategy_zh.md` -> `docs/training/strategy.md`
- Move: `docs/training_implementation_zh.md` -> `docs/training/implementation.md`
- Move: `docs/hybrid_tactical_v2_training_workflow_zh.md` -> `docs/training/workflow.md`
- Move: `docs/hybrid_training_handoff_zh.md` -> `docs/training/handoff.md`
- Move: `docs/training/高层战术强化学习训练方案.md` -> `docs/training/tactical-rl-plan.md`
- Move: `docs/training/高层战术训练运行与晋级指南.md` -> `docs/training/runbooks/tactical-training.md`
- Move: `docs/training/训练执行进度.md` -> `docs/training/status/tactical-rl-progress.md`
- Move: `docs/server_training_bundle_runbook_zh.md` -> `docs/operations/server-training-bundle.md`
- Move: `docs/linux_port_zh.md` -> `docs/operations/linux.md`
- Move: `docs/project_structure_zh.md` -> `docs/operations/project-structure.md`
- Move: `docs/ui_design.md` -> `docs/design/ui.md`

**Interfaces:**
- Consumes: the Task 1 indexes and current Markdown documents.
- Produces: the target file tree without content loss.

- [ ] **Step 1: Create destination directories**

Run:

```bash
mkdir -p docs/architecture docs/agents docs/game docs/training/runbooks docs/training/status docs/operations docs/design
```

- [ ] **Step 2: Move each document exactly according to the migration map**

Use `apply_patch` moves or an equivalent non-destructive path move. Do not overwrite an existing destination. Keep `docs/superpowers/` untouched.

- [ ] **Step 3: Verify source removal and destination completeness**

Run:

```bash
test ! -e docs/architecture.md
test -f docs/architecture/overview.md
test -f docs/training/status/tactical-rl-progress.md
test -f docs/training/runbooks/tactical-training.md
test -f docs/operations/server-training-bundle.md
test -f docs/design/ui.md
```

Expected: all old paths listed as moved are absent and every destination exists.

### Task 3: Update Markdown Links and Document Headers

**Files:**
- Modify: all moved Markdown documents containing old relative links.
- Modify: `docs/README.md`
- Modify: `docs/*/README.md`
- Modify: `docs/training/status/tactical-rl-progress.md`

**Interfaces:**
- Consumes: the final target tree from Task 2.
- Produces: valid relative links from each document’s new directory.

- [ ] **Step 1: Find all Markdown links and old paths**

Run:

```bash
rg -n '\]\([^)]*\)|docs/(architecture|agent_interface|model_agent|game_design|server_training|linux_port|project_structure|ui_design|training_)|训练方案|训练运行与晋级指南|训练执行进度' docs
```

- [ ] **Step 2: Rewrite links relative to the containing document**

Examples:

```markdown
[Training plan](tactical-rl-plan.md)
[Training status](status/tactical-rl-progress.md)
[Implementation plan](../superpowers/plans/2026-07-30-tactical-ppo-foundation.md)
```

Do not use absolute filesystem paths or GitHub URLs for local documentation links.

- [ ] **Step 3: Add canonical titles and navigation breadcrumbs**

Each moved document keeps its original H1 title. Add one short “Related documents” section only where the document currently has no navigation path and the relationship is unambiguous.

- [ ] **Step 4: Validate every relative Markdown link**

Run a Python standard-library checker:

```bash
.conda/bin/python - <<'PY'
from pathlib import Path
import re

root = Path("docs")
missing = []
for path in root.rglob("*.md"):
    text = path.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)#]+)", text):
        if "://" in target or target.startswith("#"):
            continue
        resolved = (path.parent / target).resolve()
        if not resolved.exists():
            missing.append(f"{path}: {target}")
if missing:
    raise SystemExit("\n".join(missing))
print("PASS: Markdown relative links")
PY
```

Expected: `PASS: Markdown relative links`.

### Task 4: Strengthen `.gitignore` for Open-Source Development

**Files:**
- Modify: `.gitignore`

**Interfaces:**
- Consumes: existing ignore rules and the project’s actual generated directories.
- Produces: a categorized ignore file that does not hide source, docs, tests, or configuration templates.

- [ ] **Step 1: Add categorized local-development rules**

Ensure `.gitignore` contains rules for:

```gitignore
# Local Python environments
.conda/
.venv/
venv/
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
htmlcov/

# Local configuration and secrets
.env
.env.*
!.env.example
training/local_settings.json

# Godot and local tools
.godot/
.godot_user/
.tools/
training/godot_user/

# Generated outputs
build/
dist/
test-results/
*.log
logs/
tmp/

# Training artifacts
training/runs/
training/checkpoints/
training/replays/*
!training/replays/.gitkeep
training/replays_decision/
training/eval_results/
training/data_cache/
training/packages/
*.onnx
*.pt
*.pth
*.ckpt

# Editors and operating systems
.vscode/
.idea/
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Preserve trackable project material**

Verify these paths are not ignored:

```bash
git check-ignore -v docs/README.md training/configs/evaluation_matrix.json tests/run_tests.gd
```

If Git metadata is unavailable, verify the rules textually and use `git check-ignore` only when the command is supported.

- [ ] **Step 3: Check for accidental tracked-artifact patterns**

Run:

```bash
rg --files training | rg '(^|/)(runs|checkpoints|replays|eval_results|data_cache)/|\\.(pt|pth|ckpt|onnx)$' | sed -n '1,80p'
```

Review any output manually; do not delete existing artifacts during this cleanup.

### Task 5: Final Repository Documentation Validation

**Files:**
- Modify: `docs/README.md` if validation finds stale paths.
- Modify: `docs/training/README.md` if training entry points are incomplete.
- Modify: `docs/training/status/tactical-rl-progress.md` with the final reorganization note.

**Interfaces:**
- Consumes: all completed Tasks 1–4.
- Produces: a self-contained local documentation tree with auditable validation evidence.

- [ ] **Step 1: Verify the final tree**

Run:

```bash
rg --files docs | sort
```

Expected: all moved files appear only at their target paths, and `docs/superpowers/plans/` plus `docs/superpowers/specs/` remain present.

- [ ] **Step 2: Verify no stale moved paths remain**

Run:

```bash
test ! -e docs/architecture.md
test ! -e docs/agent_interface.md
test ! -e docs/game_design.md
test ! -e docs/ui_design.md
```

Expected: all commands succeed.

- [ ] **Step 3: Run project-level static checks**

Run:

```bash
python3 tests/smoke/static_project_check.py
HOME="$PWD/.tools/godot-user" .tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64 --headless --disable-crash-handler --path . --script tests/run_tests.gd
```

Expected: both existing checks pass. The Godot harness may emit its existing ObjectDB leak warning; treat the exit code as authoritative.

- [ ] **Step 4: Record local-only completion evidence**

Append a short section to `docs/training/status/tactical-rl-progress.md` or `docs/README.md` stating:

```markdown
## Documentation Maintenance

The documentation tree is organized by domain, all internal Markdown links were validated locally, and generated/local artifacts are excluded by `.gitignore`. No GitHub remote was configured or synchronized during this cleanup.
```

- [ ] **Step 5: Check local Git identity without changing remote state**

Run:

```bash
git config --get user.name || true
git config --get user.email || true
git remote -v || true
```

Do not add or modify a remote. If the identity is absent and the user later requests it, set only:

```bash
git config --global user.name "mogoo7zn"
git config --global user.email "znwang@hotmail.com"
```

## Self-Review Checklist

- [ ] Every document in the design migration map has one destination.
- [ ] No document is deleted.
- [ ] `docs/superpowers/` is untouched.
- [ ] All root and domain indexes link to existing destinations after migration.
- [ ] Relative Markdown links resolve from their containing file.
- [ ] `.gitignore` ignores generated/local artifacts but not source, docs, tests, or tracked configs.
- [ ] No GitHub remote is added and no network synchronization is attempted.
