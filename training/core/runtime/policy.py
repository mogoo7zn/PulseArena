"""Runtime inference wrapper for trained agent models.

``RuntimeAgentPolicy`` reads a manifest JSON, loads the corresponding
checkpoint, and dispatches observations through the right policy family
(behavior, actor-critic, tactical, hybrid prior).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import torch

from training.core.encoding.observation import flatten_observation
from training.core.encoding.tactical import (
    TACTICAL_FEATURE_DIM,
    TACTICAL_FIRE_MODES,
    TACTICAL_MOVEMENTS,
    TACTICAL_SKILL_MODES,
    TACTICAL_TARGETS,
)
from training.core.models import (
    ActorCriticNet,
    BehaviorPolicyNet,
    TacticalActorCritic,
    TacticalPolicyNet,
)
from training.core.runtime.checkpoint import _safe_load_checkpoint, _unit_vector, resolve_path
from training.core.runtime.info import AgentModelInfo


class RuntimeAgentPolicy:
    """Loads a manifest + checkpoint and exposes ``act`` / ``act_tactical``."""

    def __init__(self, manifest_path: Path, device: str = "auto") -> None:
        self.manifest_path = manifest_path.resolve()
        self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        selected_device = (
            "cuda" if device == "auto" and torch.cuda.is_available()
            else ("cpu" if device == "auto" else device)
        )
        self.device = torch.device(selected_device)
        self.kind = str(self.manifest.get("kind", "behavior_policy"))
        self.model_id = str(self.manifest.get("model_id", self.manifest_path.stem))
        self.checkpoint_path = (
            resolve_path(str(self.manifest.get("checkpoint", "")), self.manifest_path.parent)
            if self.manifest.get("checkpoint")
            else Path("")
        )
        checkpoint: dict[str, Any] = {}
        if self.checkpoint_path != Path(""):
            checkpoint = _safe_load_checkpoint(self.checkpoint_path, self.device)
        checkpoint_config = checkpoint.get("config", {}) if isinstance(checkpoint, dict) else {}
        self.input_dim = int(
            self.manifest.get(
                "input_dim",
                checkpoint.get(
                    "input_dim",
                    checkpoint_config.get(
                        "input_dim",
                        TACTICAL_FEATURE_DIM if self.kind.startswith("hybrid_tactical")
                        or self.kind in {"tactical_policy", "tactical_actor_critic"} else 0,
                    ),
                ),
            )
        )
        self.hidden = int(self.manifest.get("hidden", checkpoint_config.get("hidden", 256)))
        if self.input_dim <= 0:
            raise ValueError(f"Checkpoint {self.checkpoint_path} does not declare input_dim")
        if self.kind == "behavior_policy":
            self.model = BehaviorPolicyNet(self.input_dim, hidden=self.hidden).to(self.device)
        elif self.kind == "actor_critic":
            self.model = ActorCriticNet(
                self.input_dim,
                hidden=self.hidden,
                rnn_hidden=int(
                    self.manifest.get("rnn_hidden", checkpoint_config.get("rnn_hidden", 128))
                ),
                value_hidden=int(
                    self.manifest.get("value_hidden", checkpoint_config.get("value_hidden", 256))
                ),
            ).to(self.device)
        elif self.kind == "tactical_policy":
            self.model = TacticalPolicyNet(self.input_dim, hidden=self.hidden).to(self.device)
        elif self.kind == "tactical_actor_critic":
            self.model = TacticalActorCritic(
                input_dim=self.input_dim,
                hidden=self.hidden,
                recurrent=bool(
                    self.manifest.get("recurrent", checkpoint_config.get("recurrent", True))
                ),
                rnn_hidden=self.manifest.get(
                    "rnn_hidden", checkpoint_config.get("rnn_hidden")
                ),
            ).to(self.device)
        elif self.kind == "hybrid_tactical_prior":
            self.model = None
        else:
            raise ValueError(f"Unsupported policy kind: {self.kind}")
        if self.model is not None:
            self.model.load_state_dict(checkpoint["model_state"])
            self.model.eval()
        thresholds = self.manifest.get("button_thresholds", {})
        self.shoot_threshold = float(thresholds.get("shoot", 0.5))
        self.dash_threshold = float(thresholds.get("dash", 0.5))
        self.shield_threshold = float(thresholds.get("shield", 0.5))

    @property
    def info(self) -> AgentModelInfo:
        return AgentModelInfo(
            model_id=self.model_id,
            kind=self.kind,
            checkpoint=self.checkpoint_path,
            input_dim=self.input_dim,
            hidden=self.hidden,
            device=str(self.device),
            metrics=dict(self.manifest.get("metrics", {})),
        )

    @torch.no_grad()
    def act(
        self,
        observation: dict[str, Any] | None = None,
        flat_observation: list[float] | None = None,
    ) -> dict[str, Any]:
        if self.kind in {"tactical_policy", "tactical_actor_critic", "hybrid_tactical_prior"}:
            raise ValueError("Tactical policies must be queried with act_tactical")
        if flat_observation is None:
            if observation is None:
                raise ValueError("observation or flat_observation is required")
            flat_observation = flatten_observation(observation)
        if len(flat_observation) != self.input_dim:
            raise ValueError(
                f"Observation dim mismatch: got {len(flat_observation)}, "
                f"expected {self.input_dim}"
            )
        obs = torch.tensor([flat_observation], dtype=torch.float32, device=self.device)
        if self.kind == "behavior_policy":
            logits = self.model(obs)
        else:
            logits, _value, _hidden = self.model(obs)
        continuous = torch.tanh(logits[:, 0:4]).squeeze(0).detach().cpu().tolist()
        buttons = torch.sigmoid(logits[:, 4:7]).squeeze(0).detach().cpu().tolist()
        move_x, move_y = _unit_vector(float(continuous[0]), float(continuous[1]), 0.0, 0.0)
        aim_x, aim_y = _unit_vector(float(continuous[2]), float(continuous[3]), 1.0, 0.0)
        return {
            "move_x": move_x,
            "move_y": move_y,
            "aim_x": aim_x,
            "aim_y": aim_y,
            "shoot": float(buttons[0]) >= self.shoot_threshold,
            "dash": float(buttons[1]) >= self.dash_threshold,
            "shield": float(buttons[2]) >= self.shield_threshold,
            "communication": 0,
        }

    @torch.no_grad()
    def act_tactical(
        self,
        tactical_features: list[float] | None = None,
        action_masks: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        masks = action_masks or {}
        if self.kind == "hybrid_tactical_prior":
            return self._prior_tactical_decision(masks)
        if self.kind not in {"tactical_policy", "tactical_actor_critic"}:
            return self._prior_tactical_decision(masks, confidence=0.35)
        features = list(tactical_features or [])[: self.input_dim]
        while len(features) < self.input_dim:
            features.append(0.0)
        obs = torch.tensor([features], dtype=torch.float32, device=self.device)
        outputs = self.model(obs)  # type: ignore[operator]
        head_confidences = [
            self._masked_max_probability(outputs[head][0], masks.get(head), count)
            for head, count in (
                ("target_slot", len(TACTICAL_TARGETS)),
                ("movement_mode", len(TACTICAL_MOVEMENTS)),
                ("fire_mode", len(TACTICAL_FIRE_MODES)),
                ("skill_mode", len(TACTICAL_SKILL_MODES)),
            )
        ]
        confidence = (
            float(outputs["confidence"][0].detach().cpu().item())
            if isinstance(outputs.get("confidence"), torch.Tensor)
            else float(sum(head_confidences) / max(len(head_confidences), 1))
        )
        decision = {
            "target_slot": self._masked_argmax(
                outputs["target_slot"][0], masks.get("target_slot"), len(TACTICAL_TARGETS)
            ),
            "movement_mode": self._masked_argmax(
                outputs["movement_mode"][0], masks.get("movement_mode"), len(TACTICAL_MOVEMENTS)
            ),
            "fire_mode": self._masked_argmax(
                outputs["fire_mode"][0], masks.get("fire_mode"), len(TACTICAL_FIRE_MODES)
            ),
            "skill_mode": self._masked_argmax(
                outputs["skill_mode"][0], masks.get("skill_mode"), len(TACTICAL_SKILL_MODES)
            ),
            "confidence": confidence,
        }
        return decision

    def _prior_tactical_decision(
        self, masks: dict[str, Any], confidence: float = 0.62
    ) -> dict[str, Any]:
        target = self._first_legal(masks.get("target_slot"), 4, 0)
        movement = self._first_legal(masks.get("movement_mode"), 2, 0)
        fire = self._first_legal(masks.get("fire_mode"), 2, 0)
        skill = self._first_legal(masks.get("skill_mode"), 1, 0)
        if not self._mask_allows(masks.get("target_slot"), target):
            target = self._first_legal(masks.get("target_slot"), 6, 0)
        if target == 0:
            fire = 0
            movement = self._first_legal(masks.get("movement_mode"), 9, movement)
        if self._mask_allows(masks.get("movement_mode"), 10):
            movement = 10
        return {
            "target_slot": target,
            "movement_mode": movement,
            "fire_mode": fire,
            "skill_mode": skill,
            "confidence": confidence,
        }

    def _masked_argmax(self, logits: torch.Tensor, mask: Any, count: int) -> int:
        values = logits.detach().clone()
        legal = self._mask_to_bool_list(mask, count)
        if not any(legal):
            return 0
        for index, allowed in enumerate(legal):
            if not allowed:
                values[index] = -1e9
        return int(torch.argmax(values).detach().cpu().item())

    def _masked_max_probability(self, logits: torch.Tensor, mask: Any, count: int) -> float:
        values = logits.detach().clone()
        legal = self._mask_to_bool_list(mask, count)
        if not any(legal):
            return 0.0
        for index, allowed in enumerate(legal):
            if not allowed:
                values[index] = -1e9
        probabilities = torch.softmax(values, dim=-1)
        return float(torch.max(probabilities).detach().cpu().item())

    def _first_legal(self, mask: Any, preferred: int, fallback: int) -> int:
        legal = self._mask_to_bool_list(mask, max(preferred + 1, fallback + 1, 1))
        if preferred < len(legal) and legal[preferred]:
            return preferred
        if fallback < len(legal) and legal[fallback]:
            return fallback
        for index, allowed in enumerate(legal):
            if allowed:
                return index
        return fallback

    def _mask_allows(self, mask: Any, index: int) -> bool:
        legal = self._mask_to_bool_list(mask, index + 1)
        return index < len(legal) and legal[index]

    @staticmethod
    def _mask_to_bool_list(mask: Any, count: int) -> list[bool]:
        values = list(mask or [])[:count]
        while len(values) < count:
            values.append(False)
        return [bool(value) for value in values]