# Server-agent training packet

The package is designed for a Linux server with one available A100.  Its
entrypoint is [SERVER_AGENT_PROMPT_zh.md](SERVER_AGENT_PROMPT_zh.md), which is
an executable task brief for a coding agent, not merely background reading.

The agent should start from a clean extraction directory and follow the prompt
in order.  The safe pilot launcher is:

```bash
export GODOT_BIN=/absolute/path/to/godot
bash training/server_train_hybrid_tactical_v2.sh
```

The launcher deliberately stops before behavior cloning unless `RUN_BC=1` is
set.  It first writes preflight and replay-quality reports under
`training/runs/<run-id>/reports/`.

Important: this packet does **not** provide a production tactical PPO/MAPPO
trainer.  The included `training/rl/online_trainer.py` is a legacy raw-action
prototype and must not be used for Hybrid Tactical v2 training.
