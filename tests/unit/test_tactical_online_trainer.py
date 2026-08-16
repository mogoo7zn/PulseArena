from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import torch

from training.core.tactical_online_trainer import (
    TacticalOnlineConfig,
    initial_rollout_audit,
    make_tactical_match_config,
    train_tactical_ppo,
    update_transition_audit,
    _update_cumulative_audit,
)
from training.core.models import TacticalActorCritic


class FakeTacticalEnv:
    tactical_steps = 0
    raw_steps = 0

    def __init__(self, **_kwargs) -> None:
        self.step_index = 0
        self.reset_configs: list[dict[str, object]] = []

    def reset(self, config):
        self.reset_configs.append(config)
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
                "reward_components": {
                    "shaping": float(self.step_index),
                    "player_bias": float(int(player_id)),
                },
                "executed_decision": {
                    "protocol_version": 2,
                    "target_slot": 0,
                    "movement_mode": 0,
                    "fire_mode": 0,
                    "skill_mode": 0,
                },
                "diagnostics": {
                    "script_fallback": self.step_index >= 2 and player_id == "1",
                    "safety_override": self.step_index >= 3 and player_id == "0",
                    "fallback_counts": {"decision_collapse": self.step_index} if player_id == "1" else {},
                },
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
    def test_scripted_opponent_match_config_exposes_only_the_learned_hybrid_player(self) -> None:
        match = make_tactical_match_config(
            TacticalOnlineConfig(
                output_dir=Path("training/artifacts/runs/test"),
                agents=2,
                opponent_controller="scripted",
            ),
            seed=23,
        )

        self.assertEqual(match["agent_controller"], "scripted")
        self.assertEqual(match["agent_controller_overrides"], {"0": "hybrid"})
        self.assertEqual(match["agent_model_id_overrides"], {"0": "hybrid_tactical_v1"})

    def test_engagement_window_policy_is_sent_only_by_tactical_training_config(self) -> None:
        match = make_tactical_match_config(
            TacticalOnlineConfig(
                output_dir=Path("training/artifacts/runs/test"),
                agents=2,
                opponent_controller="scripted",
                training_spawn_policy="engagement_window",
            ),
            seed=31,
        )

        self.assertEqual(match["training_spawn_policy"], "engagement_window")

    def test_four_map_training_rotates_episode_maps_deterministically(self) -> None:
        captured: list[FakeTacticalEnv] = []

        def factory(**kwargs):
            env = FakeTacticalEnv(**kwargs)
            captured.append(env)
            return env

        with TemporaryDirectory() as temporary:
            result = train_tactical_ppo(
                TacticalOnlineConfig(
                    output_dir=Path(temporary),
                    map_ids=("dungeon", "sky_city", "jungle", "mist_world"),
                    agents=1,
                    seconds=4,
                    seed=41,
                    rollout_steps=2,
                    total_env_steps=16,
                    tick_skip=1,
                    hidden=32,
                    recurrent=False,
                    device="cpu",
                    ppo_update_epochs=0,
                    ppo_minibatch_size=2,
                ),
                env_factory=factory,
            )

            self.assertEqual(
                [config["map_id"] for config in captured[0].reset_configs],
                ["dungeon", "sky_city", "jungle", "mist_world"],
            )
            audit = json.loads(Path(result["rollout_audit"]).read_text(encoding="utf-8"))
            self.assertEqual(audit["map_episode_counts"], {
                "dungeon": 1,
                "sky_city": 1,
                "jungle": 1,
                "mist_world": 1,
            })

    def test_transition_audit_counts_realized_fire_and_profile_rewards(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        update_transition_audit(
            audit,
            "0",
            {
                "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
                "reward_components": {
                    "legal_window_damage": 0.3,
                    "actionable_window_entry": 0.02,
                    "authorized_projectile_cost": -0.01,
                },
                "diagnostics": {
                    "target_valid": True,
                    "fire_allowed": True,
                    "fire_block_reason": "",
                    "safety_override": True,
                    "override_reason": "wall_collision",
                },
            },
        )

        self.assertEqual(audit["reward_profile_id"], "legal_window_pressure")
        self.assertEqual(audit["fire_intent_count"], 1)
        self.assertEqual(audit["fire_allowed_count"], 1)
        self.assertEqual(audit["movement_mode_distribution"]["CHASE"], 1)
        self.assertEqual(audit["fire_mode_distribution"]["NORMAL"], 1)
        self.assertEqual(audit["safety_override_reasons"]["wall_collision"], 1)
        self.assertEqual(audit["profile_reward_components"]["legal_window_damage"], 0.3)
        self.assertEqual(audit["profile_reward_components"]["actionable_window_entry"], 0.02)
        self.assertEqual(audit["profile_reward_components"]["authorized_projectile_cost"], -0.01)

    def test_transition_audit_counts_cover_entry_and_reengagement_by_map(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        cover = {
            "executed_decision": {"fire_mode": 0, "movement_mode": 6, "target_slot": 1},
            "reward_components": {},
            "diagnostics": {},
        }
        chase = {
            "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
            "reward_components": {},
            "diagnostics": {"fire_allowed": True},
        }

        update_transition_audit(audit, "0", cover, map_id="dungeon")
        update_transition_audit(audit, "0", chase, map_id="dungeon")

        self.assertEqual(audit["cover_entry_count"], 1)
        self.assertEqual(audit["cover_reengage_count"], 1)
        self.assertEqual(
            audit["map_cover_event_counts"]["dungeon"],
            {"cover_entry": 1, "cover_reengage": 1},
        )

    def test_transition_audit_attributes_line_of_sight_blocks_to_movement_reason(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        update_transition_audit(
            audit,
            "0",
            {
                "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
                "reward_components": {},
                "diagnostics": {
                    "fire_allowed": False,
                    "fire_block_reason": "no_line_of_sight",
                    "movement_reason": "engagement_vantage",
                    "line_of_sight": False,
                },
            },
            map_id="sky_city",
        )

        self.assertEqual(audit["line_of_sight_block_by_movement"]["CHASE"], 1)
        self.assertEqual(audit["line_of_sight_block_by_reason"]["engagement_vantage"], 1)
        self.assertEqual(audit["map_line_of_sight_block_counts"]["sky_city"]["engagement_vantage"], 1)

    def test_transition_audit_groups_reserved_energy_by_basis_and_map(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        update_transition_audit(
            audit,
            "0",
            {
                "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
                "reward_components": {},
                "diagnostics": {
                    "fire_allowed": False,
                    "fire_block_reason": "reserved_energy",
                    "reserve_basis": "dash_ready",
                    "reserve_ratio": 0.26,
                },
            },
            map_id="jungle",
        )

        self.assertEqual(audit["reserved_energy_by_basis"], {"dash_ready": 1})
        self.assertEqual(audit["map_reserved_energy_by_basis"]["jungle"], {"dash_ready": 1})

    def test_transition_audit_uses_event_counts_when_snapshot_fire_state_is_stale(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        player_data = {
            "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
            "reward_components": {},
            "diagnostics": {"fire_allowed": False, "fire_block_reason": "no_line_of_sight"},
            "tactical_event_counts": {"authorized_projectile": 1, "authorized_hit": 1},
        }

        update_transition_audit(audit, "0", player_data)

        self.assertEqual(audit["fire_allowed_count"], 0)
        self.assertEqual(audit["tactical_event_counts"]["authorized_projectile"], 1)
        self.assertEqual(audit["tactical_event_counts"]["authorized_hit"], 1)
        self.assertTrue(audit["event_counter_consistent"])

    def test_transition_audit_uses_generation_ledger_for_realized_fire_damage(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        update_transition_audit(
            audit,
            "0",
            {
                "executed_decision": {"fire_mode": 2, "movement_mode": 1, "target_slot": 1},
                "reward_components": {},
                "diagnostics": {
                    "decision_generation_id": 9,
                    "fire_allowed": False,
                    "fire_block_reason": "no_line_of_sight",
                },
                "tactical_event_counts": {
                    "fire_authorized": 1,
                    "authorized_projectile": 1,
                    "authorized_hit": 1,
                    "authorized_damage": 14,
                    "fire_rejected_no_line_of_sight": 2,
                },
            },
        )

        self.assertEqual(audit["tactical_event_counts"]["fire_authorized"], 1)
        self.assertEqual(audit["tactical_event_counts"]["authorized_damage"], 14)
        self.assertEqual(audit["fire_rejection_reasons"]["no_line_of_sight"], 2)
        self.assertTrue(audit["decision_generation_consistent"])

    def test_transition_audit_accumulates_resource_value_events(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        player_data = {
            "executed_decision": {"fire_mode": 0, "movement_mode": 0, "target_slot": 0},
            "reward_components": {},
            "diagnostics": {},
            "resource_event_counts": {"health_restored": 12, "contested_pickup_capture": 1},
        }
        update_transition_audit(audit, "0", player_data)
        player_data["resource_event_counts"] = {"health_restored": 18, "contested_pickup_capture": 1}
        update_transition_audit(audit, "0", player_data)

        self.assertEqual(audit["resource_event_counts"]["health_restored"], 18)
        self.assertEqual(audit["resource_event_counts"]["contested_pickup_capture"], 1)

    def test_transition_audit_groups_environment_events_by_map(self) -> None:
        audit = initial_rollout_audit("legal_window_pressure")
        update_transition_audit(
            audit,
            "0",
            {
                "executed_decision": {"fire_mode": 0, "movement_mode": 0, "target_slot": 0},
                "reward_components": {},
                "diagnostics": {},
                "map_event_counts": {"sky_void_death": 1},
            },
            map_id="sky_city",
        )

        self.assertEqual(audit["map_event_counts"]["sky_void_death"], 1)
        self.assertEqual(audit["map_environment_event_counts"]["sky_city"]["sky_void_death"], 1)

    def test_cumulative_audit_keeps_totals_when_component_source_resets(self) -> None:
        audit: dict[str, object] = {"reward_component_totals": {}, "_reward_components_by_player": {}}
        _update_cumulative_audit(
            audit,
            "reward_component_totals",
            "_reward_components_by_player",
            "0",
            {"win": 5.0},
            value_type=float,
        )
        _update_cumulative_audit(
            audit,
            "reward_component_totals",
            "_reward_components_by_player",
            "0",
            {},
            value_type=float,
        )
        self.assertEqual(audit["reward_component_totals"]["win"], 5.0)

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
            audit = json.loads((output_dir / "rollout_audit.json").read_text(encoding="utf-8"))
            self.assertEqual(audit["raw_step_calls"], 0)
            self.assertGreater(audit["fallback_count"], 0)
            self.assertGreater(audit["safety_override_count"], 0)
            self.assertEqual(audit["fallback_reasons"]["decision_collapse"], 4)
            self.assertEqual(audit["reward_component_totals"]["shaping"], 8.0)
            self.assertEqual(audit["reward_component_totals"]["player_bias"], 1.0)

    def test_runner_loads_bc_warm_start_and_records_source(self) -> None:
        FakeTacticalEnv.tactical_steps = 0
        FakeTacticalEnv.raw_steps = 0
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            output_dir = root / "run"
            checkpoint_path = root / "bc.pt"
            source_model = TacticalActorCritic(input_dim=142, hidden=32, recurrent=False)
            torch.save(
                {
                    "input_dim": 142,
                    "model_state": {
                        "target_head.weight": torch.randn_like(source_model.target_head.weight),
                        "target_head.bias": torch.randn_like(source_model.target_head.bias),
                        "movement_head.weight": torch.randn_like(source_model.movement_head.weight),
                        "movement_head.bias": torch.randn_like(source_model.movement_head.bias),
                        "fire_head.weight": torch.full_like(source_model.fire_head.weight, 0.41),
                        "fire_head.bias": torch.full_like(source_model.fire_head.bias, -0.09),
                        "skill_head.weight": torch.randn_like(source_model.skill_head.weight),
                        "skill_head.bias": torch.randn_like(source_model.skill_head.bias),
                    },
                },
                checkpoint_path,
            )

            result = train_tactical_ppo(
                TacticalOnlineConfig(
                    output_dir=output_dir,
                    map_id="dungeon",
                    mode="ffa",
                    agents=1,
                    seconds=4,
                    seed=23,
                    rollout_steps=2,
                    total_env_steps=4,
                    tick_skip=1,
                    hidden=32,
                    recurrent=False,
                    device="cpu",
                    ppo_update_epochs=0,
                    ppo_minibatch_size=2,
                    bc_checkpoint=checkpoint_path,
                ),
                env_factory=FakeTacticalEnv,
            )

            self.assertEqual(result["bc_warm_start"], str(checkpoint_path))
            config = json.loads((output_dir / "config.json").read_text(encoding="utf-8"))
            self.assertEqual(config["bc_checkpoint"], str(checkpoint_path))
            saved = torch.load(output_dir / "last_tactical_ppo.pt", map_location="cpu", weights_only=False)
            self.assertEqual(saved["bc_warm_start"], str(checkpoint_path))
            self.assertTrue(torch.allclose(saved["model_state"]["fire_head.weight"], torch.full_like(source_model.fire_head.weight, 0.41)))

    def test_runner_resumes_ppo_checkpoint_before_bc_warm_start(self) -> None:
        FakeTacticalEnv.tactical_steps = 0
        FakeTacticalEnv.raw_steps = 0
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            output_dir = root / "run"
            bc_checkpoint_path = root / "bc.pt"
            resume_checkpoint_path = root / "ppo.pt"
            source_model = TacticalActorCritic(input_dim=142, hidden=32, recurrent=False)
            bc_state = {
                "target_head.weight": torch.randn_like(source_model.target_head.weight),
                "target_head.bias": torch.randn_like(source_model.target_head.bias),
                "movement_head.weight": torch.randn_like(source_model.movement_head.weight),
                "movement_head.bias": torch.randn_like(source_model.movement_head.bias),
                "fire_head.weight": torch.full_like(source_model.fire_head.weight, 0.12),
                "fire_head.bias": torch.full_like(source_model.fire_head.bias, -0.12),
                "skill_head.weight": torch.randn_like(source_model.skill_head.weight),
                "skill_head.bias": torch.randn_like(source_model.skill_head.bias),
            }
            resumed_state = {
                key: torch.zeros_like(value)
                for key, value in source_model.state_dict().items()
            }
            resumed_state["fire_head.weight"] = torch.full_like(source_model.fire_head.weight, 0.73)
            resumed_state["fire_head.bias"] = torch.full_like(source_model.fire_head.bias, -0.31)
            torch.save({"input_dim": 142, "model_state": bc_state}, bc_checkpoint_path)
            torch.save(
                {
                    "input_dim": 142,
                    "model_state": resumed_state,
                    "bc_warm_start": str(bc_checkpoint_path),
                },
                resume_checkpoint_path,
            )

            result = train_tactical_ppo(
                TacticalOnlineConfig(
                    output_dir=output_dir,
                    map_id="dungeon",
                    mode="ffa",
                    agents=1,
                    seconds=4,
                    seed=29,
                    rollout_steps=2,
                    total_env_steps=4,
                    tick_skip=1,
                    hidden=32,
                    recurrent=False,
                    device="cpu",
                    ppo_update_epochs=0,
                    ppo_minibatch_size=2,
                    bc_checkpoint=bc_checkpoint_path,
                    resume_checkpoint=resume_checkpoint_path,
                ),
                env_factory=FakeTacticalEnv,
            )

            self.assertEqual(result["bc_warm_start"], str(bc_checkpoint_path))
            self.assertEqual(result["resume_checkpoint"], str(resume_checkpoint_path))
            config = json.loads((output_dir / "config.json").read_text(encoding="utf-8"))
            self.assertEqual(config["resume_checkpoint"], str(resume_checkpoint_path))
            saved = torch.load(output_dir / "last_tactical_ppo.pt", map_location="cpu", weights_only=False)
            self.assertEqual(saved["resume_checkpoint"], str(resume_checkpoint_path))
            self.assertTrue(
                torch.allclose(
                    saved["model_state"]["fire_head.weight"],
                    torch.full_like(source_model.fire_head.weight, 0.73),
                )
            )


if __name__ == "__main__":
    unittest.main()
