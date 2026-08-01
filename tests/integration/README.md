# Integration Tests

Planned Godot integration coverage:

- Human vs 1 Agent
- Human vs 3 Agents
- 2 Humans vs 2 Agents
- Headless scripted-agent match completion
- Pause timer freeze
- Seeded spawn determinism

The Linux smoke entry point is `tests/smoke/run_headless_smoke.sh`. It runs
the static check, Godot tests, map build check, and a short headless match.
