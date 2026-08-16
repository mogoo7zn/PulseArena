# Pulse Arena Documentation Reorganization Design

## Goal

Reorganize the Pulse Arena documentation into a GitHub-friendly, domain-oriented tree, add navigable indexes, update internal Markdown links, and strengthen `.gitignore` coverage without deleting documentation or changing runtime code.

## Scope

In scope:

- Move existing Markdown documents under `docs/` into stable English paths.
- Preserve existing document content and Chinese titles unless a link or path reference requires a targeted edit.
- Add `README.md` indexes for `docs/` and each new domain directory.
- Add one canonical entry point for tactical training documentation.
- Update Markdown relative links after every move.
- Extend `.gitignore` for local environments, generated outputs, training artifacts, and secrets.
- Validate that all Markdown links point to existing files.

Out of scope:

- Changing game, training, or tooling behavior.
- Deleting or rewriting historical `docs/superpowers/plans/` and `docs/superpowers/specs/` documents.
- Adding CI, release automation, contribution policy, or license files.
- Moving source code directories.

## Target Tree

```text
docs/
  README.md
  architecture/
    README.md
    overview.md
    hybrid-agent.md
  agents/
    README.md
    interface.md
    model-integration.md
  game/
    README.md
    design.md
    skills.md
  training/
    README.md
    strategy.md
    implementation.md
    workflow.md
    handoff.md
    tactical-rl-plan.md
    runbooks/
      tactical-training.md
    status/
      tactical-rl-progress.md
  operations/
    README.md
    linux.md
    project-structure.md
    server-training-bundle.md
  design/
    README.md
    ui.md
  superpowers/
    plans/
    specs/
```

`docs/superpowers/` remains a process-history area. Its dated filenames and document contents are preserved.

## Migration Map

| Current path | New path |
|---|---|
| `docs/architecture.md` | `docs/architecture/overview.md` |
| `docs/hybrid_agent_architecture_zh.md` | `docs/architecture/hybrid-agent.md` |
| `docs/agent_interface.md` | `docs/agents/interface.md` |
| `docs/model_agent_integration_zh.md` | `docs/agents/model-integration.md` |
| `docs/game_design.md` | `docs/game/design.md` |
| `docs/game/skills.md` | `docs/game/skills.md` |
| `docs/agent_training_strategy_zh.md` | `docs/training/strategy.md` |
| `docs/training_implementation_zh.md` | `docs/training/implementation.md` |
| `docs/hybrid_tactical_v2_training_workflow_zh.md` | `docs/training/workflow.md` |
| `docs/hybrid_training_handoff_zh.md` | `docs/training/handoff.md` |
| `docs/training/高层战术强化学习训练方案.md` | `docs/training/tactical-rl-plan.md` |
| `docs/training/高层战术训练运行与晋级指南.md` | `docs/training/runbooks/tactical-training.md` |
| `docs/training/训练执行进度.md` | `docs/training/status/tactical-rl-progress.md` |
| `docs/server_training_bundle_runbook_zh.md` | `docs/operations/server-training-bundle.md` |
| `docs/linux_port_zh.md` | `docs/operations/linux.md` |
| `docs/project_structure_zh.md` | `docs/operations/project-structure.md` |
| `docs/ui_design.md` | `docs/design/ui.md` |

## Index Responsibilities

`docs/README.md` will provide:

- project documentation map;
- recommended reading order for new contributors;
- links to architecture, agents, game, training, operations, and design;
- a note that dated superpowers documents are historical development artifacts.

Each domain README will provide:

- the domain purpose;
- the primary entry document;
- links to all documents in that directory;
- maintenance guidance when the domain has generated status or runbook documents.

`docs/training/README.md` will distinguish:

- stable training design;
- implementation details;
- operational runbooks;
- current status and evidence;
- historical plans/specs.

## `.gitignore` Policy

Keep source, configuration templates, documentation, tests, and curated reports trackable. Ignore:

- Godot generated caches, user data, export/build output, and local tools.
- Python virtual environments, `.conda`, bytecode, test caches, coverage, and local tooling caches.
- Local settings, environment files, logs, temporary files, and editor metadata.
- Training runs, checkpoints, replay data, model files, generated evaluation output, and package bundles.
- OS-specific files.

Preserve:

- `training/replays/.gitkeep`;
- checked-in configuration files under `training/configs/`;
- checked-in documentation and manually curated reports;
- explicit `.env.example` templates if present.

## Link and Validation Rules

After migration:

1. Search all Markdown files for relative links.
2. Resolve each relative link from the file containing it.
3. Report missing targets and fix them before completion.
4. Confirm no old top-level Markdown files remain except intentional indexes or historical directories.
5. Confirm all target files exist and no duplicate destination is silently overwritten.
6. Run repository static checks that do not require network or GPU access.

Because the workspace currently has no usable Git metadata, the migration will be tracked by the design document, file listing, validation output, and final progress note rather than a commit.

## Rollback

The migration is path-only and content-preserving. Rollback consists of reversing the migration map and restoring the previous `.gitignore`; no runtime state or generated training artifact is modified.
