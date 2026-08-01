from __future__ import annotations

import unittest

import torch

from training.rl.tactical_ppo import (
    MaskedTacticalPPOTrainer,
    TacticalActionBatch,
    TacticalActorCritic,
    TacticalPPOConfig,
    compute_gae,
    sample_masked_tactical_actions,
)


class TrackingTacticalActorCritic(TacticalActorCritic):
    def __init__(self) -> None:
        super().__init__(input_dim=142, hidden=32, recurrent=True)
        self.seen_feature_dims: list[int] = []

    def forward(self, features: torch.Tensor, hidden_state=None):
        self.seen_feature_dims.append(features.dim())
        return super().forward(features, hidden_state)


class TacticalPpoTests(unittest.TestCase):
    def test_masked_sampler_never_selects_an_illegal_action(self) -> None:
        torch.manual_seed(7)
        model = TacticalActorCritic(input_dim=142, hidden=64, recurrent=False)
        features = torch.randn(4, 142)
        outputs = model(features)
        masks = {
            "target_slot": torch.tensor(
                [[True, False, False, False, False, False, False]] * 4, dtype=torch.bool
            ),
            "movement_mode": torch.tensor(
                [[True] + [False] * 11] * 4, dtype=torch.bool
            ),
            "fire_mode": torch.tensor(
                [[False, True, False, False, False, False]] * 4, dtype=torch.bool
            ),
            "skill_mode": torch.tensor(
                [[False, False, True, False, False, False]] * 4, dtype=torch.bool
            ),
        }

        batch = sample_masked_tactical_actions(outputs, masks)

        self.assertTrue(torch.all(masks["target_slot"][torch.arange(4), batch.target_slot]))
        self.assertTrue(torch.all(masks["movement_mode"][torch.arange(4), batch.movement_mode]))
        self.assertTrue(torch.all(masks["fire_mode"][torch.arange(4), batch.fire_mode]))
        self.assertTrue(torch.all(masks["skill_mode"][torch.arange(4), batch.skill_mode]))

    def test_gae_stops_bootstrap_at_terminal_transition(self) -> None:
        rewards = torch.tensor([1.0, 2.0, 3.0])
        values = torch.tensor([0.5, 0.25, 0.0])
        terminated = torch.tensor([False, False, True])
        truncated = torch.tensor([False, False, False])

        returns, advantages = compute_gae(
            rewards,
            values,
            terminated,
            truncated,
            bootstrap_value=10.0,
            gamma=0.99,
            gae_lambda=0.95,
        )

        self.assertEqual(float(returns[-1]), 3.0)
        self.assertEqual(float(advantages[-1]), 3.0)

    def test_gae_bootstraps_but_stops_trace_at_truncation(self) -> None:
        rewards = torch.tensor([1.0, 2.0])
        values = torch.tensor([0.0, 100.0])
        terminated = torch.tensor([False, False])
        truncated = torch.tensor([True, False])

        returns, _advantages = compute_gae(
            rewards,
            values,
            terminated,
            truncated,
            bootstrap_value=0.0,
            gamma=0.5,
            gae_lambda=1.0,
        )

        self.assertEqual(float(returns[0]), 51.0)

    def test_trainer_update_runs_on_legal_masked_batch(self) -> None:
        torch.manual_seed(11)
        model = TacticalActorCritic(input_dim=142, hidden=64, recurrent=False)
        trainer = MaskedTacticalPPOTrainer(
            model,
            TacticalPPOConfig(
                clip_ratio=0.2,
                value_coef=0.5,
                entropy_coef=0.01,
                max_grad_norm=0.5,
                update_epochs=2,
                minibatch_size=4,
                lr=3e-4,
                mixed_precision=False,
            ),
            device=torch.device("cpu"),
        )
        features = torch.randn(8, 142)
        masks = {
            "target_slot": torch.tensor(
                [[True, False, False, False, False, False, False]] * 8, dtype=torch.bool
            ),
            "movement_mode": torch.tensor(
                [[True] + [False] * 11] * 8, dtype=torch.bool
            ),
            "fire_mode": torch.tensor(
                [[True, False, False, False, False, False]] * 8, dtype=torch.bool
            ),
            "skill_mode": torch.tensor(
                [[True, False, False, False, False, False]] * 8, dtype=torch.bool
            ),
        }
        actions = TacticalActionBatch(
            target_slot=torch.zeros(8, dtype=torch.long),
            movement_mode=torch.zeros(8, dtype=torch.long),
            fire_mode=torch.zeros(8, dtype=torch.long),
            skill_mode=torch.zeros(8, dtype=torch.long),
            log_prob=torch.zeros(8),
            entropy=torch.zeros(8),
        )
        batch = {
            "features": features,
            "masks": masks,
            "actions": actions,
            "old_log_probs": torch.zeros(8),
            "old_values": torch.zeros(8),
            "returns": torch.ones(8),
            "advantages": torch.ones(8),
            "terminated": torch.zeros(8, dtype=torch.bool),
            "truncated": torch.zeros(8, dtype=torch.bool),
            "sequence_boundaries": [(0, 4), (4, 8)],
        }

        metrics = trainer.update(batch)

        self.assertGreaterEqual(metrics["approx_kl"], 0.0)
        self.assertTrue(all(torch.isfinite(torch.tensor(list(metrics.values())))))
        self.assertTrue(torch.all(masks["target_slot"][torch.arange(8), actions.target_slot]))

    def test_recurrent_update_preserves_sequence_boundaries(self) -> None:
        torch.manual_seed(19)
        model = TrackingTacticalActorCritic()
        trainer = MaskedTacticalPPOTrainer(
            model,
            TacticalPPOConfig(
                update_epochs=1,
                minibatch_size=4,
                mixed_precision=False,
            ),
            device=torch.device("cpu"),
        )
        size = 8
        masks = {
            "target_slot": torch.ones(size, 7, dtype=torch.bool),
            "movement_mode": torch.ones(size, 12, dtype=torch.bool),
            "fire_mode": torch.ones(size, 6, dtype=torch.bool),
            "skill_mode": torch.ones(size, 6, dtype=torch.bool),
        }
        actions = TacticalActionBatch(
            target_slot=torch.zeros(size, dtype=torch.long),
            movement_mode=torch.zeros(size, dtype=torch.long),
            fire_mode=torch.zeros(size, dtype=torch.long),
            skill_mode=torch.zeros(size, dtype=torch.long),
            log_prob=torch.zeros(size),
            entropy=torch.zeros(size),
        )
        trainer.update(
            {
                "features": torch.randn(size, 142),
                "masks": masks,
                "actions": actions,
                "old_log_probs": torch.zeros(size),
                "old_values": torch.zeros(size),
                "returns": torch.ones(size),
                "advantages": torch.ones(size),
                "sequence_boundaries": [(0, 4), (4, 8)],
            }
        )

        self.assertIn(3, model.seen_feature_dims)

    def test_bc_loader_requires_exact_feature_dimension_and_head_shapes(self) -> None:
        model = TacticalActorCritic(input_dim=142, hidden=32, recurrent=False)
        trainer = MaskedTacticalPPOTrainer(model, TacticalPPOConfig(mixed_precision=False), device=torch.device("cpu"))
        state = {
            "target_head.weight": torch.randn_like(model.target_head.weight),
            "target_head.bias": torch.randn_like(model.target_head.bias),
            "movement_head.weight": torch.randn_like(model.movement_head.weight),
            "movement_head.bias": torch.randn_like(model.movement_head.bias),
            "fire_mode_head.weight": torch.randn_like(model.fire_head.weight),
            "fire_mode_head.bias": torch.randn_like(model.fire_head.bias),
            "skill_mode_head.weight": torch.randn_like(model.skill_head.weight),
            "skill_mode_head.bias": torch.randn_like(model.skill_head.bias),
        }

        loaded = trainer.load_bc_checkpoint({"input_dim": 142, "model_state": state})

        self.assertEqual(set(loaded), {"target_slot", "movement_mode", "fire_mode", "skill_mode"})
        with self.assertRaises(ValueError):
            trainer.load_bc_checkpoint({"input_dim": 141, "model_state": state})


if __name__ == "__main__":
    unittest.main()
