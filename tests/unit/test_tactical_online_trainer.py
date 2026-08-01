from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from training.rl.tactical_online_trainer import TacticalOnlineConfig, train_tactical_ppo


class FakeTacticalEnv:
    tactical_steps = 0
    raw_steps = 0

    def __init__(self, **_kwargs) -> None:
        self.step_index = 0

    def reset(self, _config):
        self.step_index = 0
        return {"type": "reset_ok"}

    def observe_tactical(self):
        return self._snapshot()

    def step_tactical(self, decisions, ticks=1):
        if not decisions:
            raise AssertionError("runner sent an empty tactical decision batch")
        FakeTacticalEnv.tactical_steps += 1
        self.step_index += int(ticks)
        return self._snapshot()

    def step(self, _actions, _ticks=1):
        FakeTacticalEnv.raw_steps += 1
        raise AssertionError("runner called legacy raw step")

    def close(self):
        return None

    def _snapshot(self):
        terminated = self.step_index >= 4
        players = {}
        rewards = {}
        for player_id in ("0", "1"):
            rewards[player_id] = float(self.step_index)
            players[player_id] = {
                "player_id": int(player_id),
                "supports_tactical_decisions": True,
                "tactical_features": [0.0] * 142,
                "action_masks": {
                    "target_slot": [True] + [False] * 6,
                    "movement_mode": [True] + [False] * 11,
                    "fire_mode": [True] + [False] * 5,
                    "skill_mode": [True] + [False] * 5,
                },
                "reward_delta": 1.0,
                "reward_total": float(self.step_index),
                "reward_components": {},
                "executed_decision": {
                    "protocol_version": 2,
                    "target_slot": 0,
                    "movement_mode": 0,
                    "fire_mode": 0,
                    "skill_mode": 0,
                },
                "diagnostics": {},
            }
        return {
            "protocol": 2,
            "terminated": terminated,
            "truncated": False,
            "rewards": rewards,
            "info": {"tactical_player_ids": [0, 1]},
            "players": players,
        }


class TacticalOnlineTrainerTests(unittest.TestCase):
    def test_runner_sends_high_level_decisions_and_writes_pilot_artifacts(self) -> None:
        FakeTacticalEnv.tactical_steps = 0
        FakeTacticalEnv.raw_steps = 0
        with TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            result = train_tactical_ppo(
                TacticalOnlineConfig(
                    output_dir=output_dir,
                    map_id="dungeon",
                    mode="ffa",
                    agents=1,
                    seconds=4,
                    seed=17,
                    rollout_steps=2,
                    total_env_steps=4,
                    tick_skip=1,
                    hidden=32,
                    recurrent=False,
                    device="cpu",
                    ppo_update_epochs=1,
                    ppo_minibatch_size=2,
                ),
                env_factory=FakeTacticalEnv,
            )

            self.assertGreater(FakeTacticalEnv.tactical_steps, 0)
            self.assertEqual(FakeTacticalEnv.raw_steps, 0)
            self.assertEqual(result["device"], "cpu")
            for filename in (
                "best_tactical_ppo.pt",
                "last_tactical_ppo.pt",
                "metrics.jsonl",
                "config.json",
                "rollout_audit.json",
            ):
                self.assertTrue((output_dir / filename).exists(), filename)
            metrics = [
                json.loads(line)
                for line in (output_dir / "metrics.jsonl").read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertTrue(metrics)
            self.assertEqual(json.loads((output_dir / "rollout_audit.json").read_text(encoding="utf-8"))["raw_step_calls"], 0)


if __name__ == "__main__":
    unittest.main()
