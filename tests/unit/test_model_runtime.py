from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import torch

from training.core.model_runtime import RuntimeAgentPolicy
from training.inference.serve_agent import validate_inference_device
from training.core.models import TacticalActorCritic


class ModelRuntimeTests(unittest.TestCase):
    def test_service_accepts_explicit_cuda_device(self) -> None:
        self.assertEqual(validate_inference_device("cuda:4"), "cuda:4")

    def test_tactical_actor_critic_checkpoint_serves_tactical_decisions(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkpoint_path = root / "candidate.pt"
            model = TacticalActorCritic(input_dim=142, hidden=32, recurrent=False)
            with torch.no_grad():
                model.fire_head.bias.fill_(-5.0)
                model.fire_head.bias[3] = 5.0
            torch.save(
                {
                    "model_state": model.state_dict(),
                    "input_dim": 142,
                    "config": {"hidden": 32, "recurrent": False},
                },
                checkpoint_path,
            )
            manifest_path = root / "candidate_agent.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "model_id": "candidate",
                        "kind": "tactical_actor_critic",
                        "checkpoint": str(checkpoint_path),
                        "input_dim": 142,
                        "hidden": 32,
                        "recurrent": False,
                        "protocol": 2,
                    }
                ),
                encoding="utf-8",
            )

            policy = RuntimeAgentPolicy(manifest_path, device="cpu")
            decision = policy.act_tactical(
                tactical_features=[0.0] * 142,
                action_masks={
                    "target_slot": [True] * 7,
                    "movement_mode": [True] * 12,
                    "fire_mode": [True] * 6,
                    "skill_mode": [True] * 6,
                },
            )

        self.assertEqual(policy.info.kind, "tactical_actor_critic")
        self.assertEqual(decision["fire_mode"], 3)
        self.assertGreaterEqual(decision["confidence"], 0.0)
        self.assertLessEqual(decision["confidence"], 1.0)


if __name__ == "__main__":
    unittest.main()
