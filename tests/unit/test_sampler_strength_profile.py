from __future__ import annotations

import unittest

import torch

from training.core.ppo.sampling import (
    DEFAULT_STRENGTH,
    STRENGTH_PROFILES,
    resolve_strength_profile,
    sample_masked_tactical_actions,
    sample_with_strength_profile,
)


def _mock_outputs_and_masks() -> tuple[dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    """Build a fixed-logit / fixed-mask setup so the test is deterministic."""
    torch.manual_seed(0)
    outputs: dict[str, torch.Tensor] = {
        "target_slot": torch.tensor([2.0, 1.0, 0.5, 0.0, -0.5, -1.0, -2.0]),
        "movement_mode": torch.tensor([1.5, 0.5, 0.0, -0.5, -1.0, -1.5, -2.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        "fire_mode": torch.tensor([2.0, 1.0, 0.0, -1.0, -2.0, -3.0]),
        "skill_mode": torch.tensor([1.0, 0.5, 0.0, -0.5, -1.0, -2.0]),
    }
    masks: dict[str, torch.Tensor] = {
        "target_slot": torch.tensor([True, True, True, True, True, True, True]),
        "movement_mode": torch.tensor([True, True, True, True, True, True, True, False, False, False, False, False]),
        "fire_mode": torch.tensor([True, True, True, True, True, True]),
        "skill_mode": torch.tensor([True, True, True, True, True, True]),
    }
    return outputs, masks


class StrengthProfileTests(unittest.TestCase):
    def test_resolve_strength_profile_default_is_normal(self) -> None:
        self.assertEqual(DEFAULT_STRENGTH, "normal")
        profile = resolve_strength_profile(None)
        self.assertEqual(profile, STRENGTH_PROFILES["normal"])

    def test_resolve_strength_profile_unknown_raises(self) -> None:
        with self.assertRaises(ValueError):
            resolve_strength_profile("impossible")

    def test_strength_profile_parameters_strictly_monotonic(self) -> None:
        order = ["easy", "casual", "normal", "strong", "elite"]
        temps = [STRENGTH_PROFILES[s]["temperature"] for s in order]
        softs = [STRENGTH_PROFILES[s]["mask_soften"] for s in order]
        thresholds = [STRENGTH_PROFILES[s]["safety_override_threshold"] for s in order]
        self.assertEqual(temps, sorted(temps, reverse=True), "temperature must strictly decrease")
        self.assertEqual(softs, sorted(softs, reverse=True), "mask_soften must strictly decrease")
        self.assertEqual(thresholds, sorted(thresholds), "safety_override_threshold must strictly increase")

    def test_higher_temperature_yields_higher_entropy(self) -> None:
        outputs, masks = _mock_outputs_and_masks()
        torch.manual_seed(1)
        easy_batch = sample_with_strength_profile(outputs, masks, "easy")
        torch.manual_seed(1)
        elite_batch = sample_with_strength_profile(outputs, masks, "elite")
        self.assertGreater(easy_batch.entropy.mean().item(), elite_batch.entropy.mean().item())

    def test_default_sample_uses_temperature_one(self) -> None:
        outputs, masks = _mock_outputs_and_masks()
        torch.manual_seed(3)
        default_temp_1 = sample_masked_tactical_actions(outputs, masks, temperature=1.0)
        torch.manual_seed(3)
        default_no_arg = sample_masked_tactical_actions(outputs, masks)
        self.assertTrue(torch.equal(default_temp_1.target_slot, default_no_arg.target_slot))
        self.assertTrue(torch.equal(default_temp_1.movement_mode, default_no_arg.movement_mode))

    def test_strength_normal_uses_documented_temperature(self) -> None:
        profile = resolve_strength_profile("normal")
        self.assertEqual(profile["temperature"], 0.85)
        self.assertEqual(profile["mask_soften"], 0.10)
        self.assertEqual(profile["safety_override_threshold"], 0.75)

    def test_higher_temperature_changes_distribution(self) -> None:
        outputs, masks = _mock_outputs_and_masks()
        torch.manual_seed(4)
        cool = sample_masked_tactical_actions(outputs, masks, temperature=0.25)
        torch.manual_seed(4)
        hot = sample_masked_tactical_actions(outputs, masks, temperature=1.6)
        # Cool sampler should produce lower entropy (more greedy) than hot
        self.assertLess(cool.entropy.mean().item(), hot.entropy.mean().item())


if __name__ == "__main__":
    unittest.main()
