"""Generic (non-tactical) policy and actor-critic networks.

These architectures back the legacy continuous-action pipeline (move + aim +
buttons) used by RL baselines and the serve_agent inference entrypoint.
"""
from __future__ import annotations

import torch
from torch import nn


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

    def forward(
        self,
        obs: torch.Tensor,
        hidden_state: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor | None]:
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