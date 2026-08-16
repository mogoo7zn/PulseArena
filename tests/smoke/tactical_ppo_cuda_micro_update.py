#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from training.core.models import TacticalActorCritic
from training.core.tactical_ppo import (
    MaskedTacticalPPOTrainer,
    TacticalPPOConfig,
    sample_masked_tactical_actions,
)


def main() -> int:
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is unavailable")
    device = torch.device("cuda")
    torch.manual_seed(23)
    model = TacticalActorCritic(input_dim=142, hidden=64, recurrent=False).to(device)
    trainer = MaskedTacticalPPOTrainer(
        model,
        TacticalPPOConfig(update_epochs=2, minibatch_size=4, mixed_precision=False),
        device=device,
    )
    batch_size = 8
    features = torch.randn(batch_size, 142, device=device)
    masks = {
        "target_slot": torch.tensor(
            [[True, False, False, False, False, False, False]] * batch_size,
            device=device,
        ),
        "movement_mode": torch.tensor(
            [[True] + [False] * 11] * batch_size,
            device=device,
        ),
        "fire_mode": torch.tensor(
            [[True, False, False, False, False, False]] * batch_size,
            device=device,
        ),
        "skill_mode": torch.tensor(
            [[True, False, False, False, False, False]] * batch_size,
            device=device,
        ),
    }
    with torch.no_grad():
        outputs = model(features)
        actions = sample_masked_tactical_actions(outputs, masks)
        batch = {
            "features": features,
            "masks": masks,
            "actions": actions,
            "old_log_probs": actions.log_prob.detach(),
            "old_values": outputs["value"].detach(),
            "returns": outputs["value"].detach() + 1.0,
            "advantages": torch.ones(batch_size, device=device),
            "sequence_boundaries": None,
        }
    metrics = trainer.update(batch)
    torch.cuda.synchronize()
    if not all(torch.isfinite(torch.tensor(value)) for value in metrics.values()):
        raise SystemExit(f"Non-finite PPO metrics: {metrics}")
    print(
        json.dumps(
            {
                "device": torch.cuda.get_device_name(0),
                "metrics": metrics,
            },
            sort_keys=True,
        )
    )
    print("PASS: tactical PPO CUDA micro-update")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
