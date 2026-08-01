from __future__ import annotations

import torch
from torch import nn

from training.rl.encoding import (
    TACTICAL_FEATURE_DIM,
    TACTICAL_FIRE_MODES,
    TACTICAL_MOVEMENTS,
    TACTICAL_SKILL_MODES,
    TACTICAL_TARGETS,
)


class BehaviorPolicyNet(nn.Module):
    def __init__(self, input_dim: int, hidden: int = 256, output_dim: int = 7) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.LayerNorm(input_dim),
            nn.Linear(input_dim, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
            nn.Linear(hidden, output_dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


class ActorCriticNet(nn.Module):
    """Shared actor-critic used by PPO/MAPPO updates.

    The first four action dimensions are continuous move/aim logits. The last
    three dimensions are button logits. The value head is intentionally kept
    separate so it can later receive centralized critic features.
    """

    def __init__(
        self,
        input_dim: int,
        hidden: int = 256,
        recurrent: bool = True,
        rnn_hidden: int = 128,
        value_hidden: int = 256,
    ) -> None:
        super().__init__()
        self.recurrent = recurrent
        self.encoder = nn.Sequential(
            nn.LayerNorm(input_dim),
            nn.Linear(input_dim, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
        )
        self.rnn = nn.GRU(hidden, rnn_hidden, batch_first=True) if recurrent else None
        trunk_dim = rnn_hidden if recurrent else hidden
        self.actor = nn.Sequential(
            nn.Linear(trunk_dim, hidden),
            nn.SiLU(),
            nn.Linear(hidden, 7),
        )
        self.value = nn.Sequential(
            nn.Linear(trunk_dim, value_hidden),
            nn.SiLU(),
            nn.Linear(value_hidden, 1),
        )
        self.log_std = nn.Parameter(torch.full((4,), -0.4))

    def forward(self, obs: torch.Tensor, hidden_state: torch.Tensor | None = None) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor | None]:
        if obs.dim() == 2:
            encoded = self.encoder(obs)
            if self.rnn is not None:
                encoded, next_hidden = self.rnn(encoded.unsqueeze(1), hidden_state)
                encoded = encoded.squeeze(1)
            else:
                next_hidden = None
        elif obs.dim() == 3:
            batch, steps, features = obs.shape
            encoded = self.encoder(obs.reshape(batch * steps, features)).reshape(batch, steps, -1)
            if self.rnn is not None:
                encoded, next_hidden = self.rnn(encoded, hidden_state)
            else:
                next_hidden = None
        else:
            raise ValueError(f"Unsupported observation shape: {tuple(obs.shape)}")
        logits = self.actor(encoded)
        value = self.value(encoded).squeeze(-1)
        return logits, value, next_hidden


class TacticalPolicyNet(nn.Module):
    """High-level policy for Hybrid Tactical Agent protocol v2."""

    def __init__(self, input_dim: int = TACTICAL_FEATURE_DIM, hidden: int = 192) -> None:
        super().__init__()
        self.trunk = nn.Sequential(
            nn.LayerNorm(input_dim),
            nn.Linear(input_dim, hidden),
            nn.SiLU(),
            nn.Linear(hidden, hidden),
            nn.SiLU(),
        )
        self.target_head = nn.Linear(hidden, len(TACTICAL_TARGETS))
        self.movement_head = nn.Linear(hidden, len(TACTICAL_MOVEMENTS))
        self.fire_head = nn.Linear(hidden, len(TACTICAL_FIRE_MODES))
        self.skill_head = nn.Linear(hidden, len(TACTICAL_SKILL_MODES))
        self.confidence_head = nn.Linear(hidden, 1)

    def forward(self, features: torch.Tensor) -> dict[str, torch.Tensor]:
        encoded = self.trunk(features)
        return {
            "target_slot": self.target_head(encoded),
            "movement_mode": self.movement_head(encoded),
            "fire_mode": self.fire_head(encoded),
            "skill_mode": self.skill_head(encoded),
            "confidence": torch.sigmoid(self.confidence_head(encoded)).squeeze(-1),
        }


class TacticalActorCritic(nn.Module):
    """Masked categorical actor-critic for the Hybrid Tactical protocol."""

    def __init__(
        self,
        input_dim: int = TACTICAL_FEATURE_DIM,
        hidden: int = 192,
        recurrent: bool = True,
        rnn_hidden: int | None = None,
    ) -> None:
        super().__init__()
        self.input_dim = int(input_dim)
        self.hidden_size = int(hidden)
        self.recurrent = bool(recurrent)
        self.rnn_hidden_size = int(rnn_hidden or hidden)
        self.encoder = nn.Sequential(
            nn.LayerNorm(self.input_dim),
            nn.Linear(self.input_dim, self.hidden_size),
            nn.SiLU(),
            nn.Linear(self.hidden_size, self.hidden_size),
            nn.SiLU(),
        )
        self.rnn = (
            nn.GRU(self.hidden_size, self.rnn_hidden_size, batch_first=True)
            if self.recurrent
            else None
        )
        trunk_dim = self.rnn_hidden_size if self.recurrent else self.hidden_size
        self.target_head = nn.Linear(trunk_dim, len(TACTICAL_TARGETS))
        self.movement_head = nn.Linear(trunk_dim, len(TACTICAL_MOVEMENTS))
        self.fire_head = nn.Linear(trunk_dim, len(TACTICAL_FIRE_MODES))
        self.skill_head = nn.Linear(trunk_dim, len(TACTICAL_SKILL_MODES))
        self.value_head = nn.Sequential(
            nn.Linear(trunk_dim, self.hidden_size),
            nn.SiLU(),
            nn.Linear(self.hidden_size, 1),
        )

    def forward(
        self,
        features: torch.Tensor,
        hidden_state: torch.Tensor | None = None,
    ) -> dict[str, torch.Tensor | None]:
        if features.dim() == 2:
            encoded = self.encoder(features)
            if self.rnn is not None:
                encoded, next_hidden = self.rnn(encoded.unsqueeze(1), hidden_state)
                encoded = encoded.squeeze(1)
            else:
                next_hidden = None
        elif features.dim() == 3:
            batch, steps, feature_dim = features.shape
            if feature_dim != self.input_dim:
                raise ValueError(
                    f"Expected tactical feature dim {self.input_dim}, got {feature_dim}"
                )
            encoded = self.encoder(features.reshape(batch * steps, feature_dim))
            encoded = encoded.reshape(batch, steps, self.hidden_size)
            if self.rnn is not None:
                encoded, next_hidden = self.rnn(encoded, hidden_state)
            else:
                next_hidden = None
        else:
            raise ValueError(f"Unsupported tactical feature shape: {tuple(features.shape)}")

        return {
            "target_slot": self.target_head(encoded),
            "movement_mode": self.movement_head(encoded),
            "fire_mode": self.fire_head(encoded),
            "skill_mode": self.skill_head(encoded),
            "value": self.value_head(encoded).squeeze(-1),
            "hidden_state": next_hidden,
        }
