from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from statistics import mean, pstdev
from typing import Any

from training.inference.serve_agent import AgentPolicyRegistry
from training.rl.encoding import (
    TACTICAL_FIRE_MODES,
    TACTICAL_MOVEMENTS,
    TACTICAL_SKILL_MODES,
    TACTICAL_TARGETS,
    tactical_action_masks_from_observation,
    tactical_features_from_observation,
)
from training.rl.godot_env import GodotStepEnv


def make_config(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "mode": args.mode,
        "human_player_count": 0,
        "agent_count": args.agents,
        "team_mode": args.mode == "team_2v2",
        "friendly_fire": args.mode != "team_2v2",
        "time_limit": float(args.seconds),
        "score_limit": 0,
        "map_id": args.map,
        "agent_difficulty": "hard",
        "random_seed": int(args.seed),
        "headless": True,
        "record_replay": False,
        "training_fast_mode": False,
    }


def vec_angle(x: float, y: float) -> float:
    return math.atan2(y, x)


def circular_resultant(angles: list[float]) -> float:
    if not angles:
        return 1.0
    sx = mean(math.cos(angle) for angle in angles)
    sy = mean(math.sin(angle) for angle in angles)
    return math.hypot(sx, sy)


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if rows and "target_slot" in rows[0]:
        return summarize_tactical(rows)
    move_angles = [vec_angle(row["move_x"], row["move_y"]) for row in rows]
    aim_angles = [vec_angle(row["aim_x"], row["aim_y"]) for row in rows]
    move_x = [row["move_x"] for row in rows]
    move_y = [row["move_y"] for row in rows]
    return {
        "samples": len(rows),
        "mean_move": [mean(move_x), mean(move_y)] if rows else [0.0, 0.0],
        "std_move": [pstdev(move_x), pstdev(move_y)] if len(rows) > 1 else [0.0, 0.0],
        "move_direction_resultant": circular_resultant(move_angles),
        "aim_direction_resultant": circular_resultant(aim_angles),
        "shoot_rate": mean(1.0 if row["shoot"] else 0.0 for row in rows) if rows else 0.0,
        "dash_rate": mean(1.0 if row["dash"] else 0.0 for row in rows) if rows else 0.0,
        "shield_rate": mean(1.0 if row["shield"] else 0.0 for row in rows) if rows else 0.0,
    }


def summarize_tactical(rows: list[dict[str, Any]]) -> dict[str, Any]:
    def counts(key: str, labels: list[str]) -> dict[str, int]:
        out = {label: 0 for label in labels}
        for row in rows:
            index = int(row[key])
            label = labels[index] if 0 <= index < len(labels) else "UNKNOWN"
            out[label] = out.get(label, 0) + 1
        return out

    return {
        "samples": len(rows),
        "target_counts": counts("target_slot", TACTICAL_TARGETS),
        "movement_counts": counts("movement_mode", TACTICAL_MOVEMENTS),
        "fire_counts": counts("fire_mode", TACTICAL_FIRE_MODES),
        "skill_counts": counts("skill_mode", TACTICAL_SKILL_MODES),
        "mean_confidence": mean(float(row.get("confidence", 0.0)) for row in rows) if rows else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Diagnose a Pulse Arena policy on real Godot observations.")
    parser.add_argument("--catalog", type=Path, default=Path("training/models/model_catalog.json"))
    parser.add_argument("--model-id", default="")
    parser.add_argument("--device", default="cpu", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--map", default="dungeon", choices=["dungeon", "sky_city", "jungle", "mist_world"])
    parser.add_argument("--mode", default="ffa", choices=["ffa", "team_2v2"])
    parser.add_argument("--agents", type=int, default=4)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--port", type=int, default=8780)
    parser.add_argument("--steps", type=int, default=48)
    parser.add_argument("--ticks", type=int, default=8)
    parser.add_argument("--fail-on-collapse", action="store_true")
    args = parser.parse_args()

    registry = AgentPolicyRegistry.from_catalog(args.catalog, device=args.device)
    model_id = args.model_id or registry.default_model_id
    policy = registry.get(model_id)
    rows: list[dict[str, Any]] = []
    with GodotStepEnv(port=args.port, startup_timeout=60.0) as env:
        response = env.reset(make_config(args))
        for _step in range(max(args.steps, 1)):
            actions: dict[str, Any] = {}
            for player_id, observation in response["observations"].items():
                if policy.info.kind in {"hybrid_tactical_prior", "tactical_policy"}:
                    decision = policy.act_tactical(
                        tactical_features=tactical_features_from_observation(observation),
                        action_masks=tactical_action_masks_from_observation(observation),
                    )
                    actions[player_id] = {"move_x": 0.0, "move_y": 0.0, "aim_x": 1.0, "aim_y": 0.0, "shoot": False, "dash": False, "shield": False}
                    rows.append({
                        "target_slot": int(decision["target_slot"]),
                        "movement_mode": int(decision["movement_mode"]),
                        "fire_mode": int(decision["fire_mode"]),
                        "skill_mode": int(decision["skill_mode"]),
                        "confidence": float(decision.get("confidence", 0.0)),
                    })
                else:
                    action = policy.act(observation=observation)
                    actions[player_id] = action
                    rows.append({
                        "move_x": float(action["move_x"]),
                        "move_y": float(action["move_y"]),
                        "aim_x": float(action["aim_x"]),
                        "aim_y": float(action["aim_y"]),
                        "shoot": bool(action["shoot"]),
                        "dash": bool(action["dash"]),
                        "shield": bool(action["shield"]),
                    })
            response = env.step(actions, ticks=args.ticks)
            if response.get("terminated", False):
                break

    summary = summarize(rows)
    collapsed = (
        rows
        and "move_x" in rows[0]
        and summary["samples"] >= max(args.agents * 8, 8)
        and summary["move_direction_resultant"] > 0.92
        and max(summary["std_move"]) < 0.08
    )
    payload = {
        "model_id": model_id,
        "checkpoint": str(policy.info.checkpoint),
        "map": args.map,
        "mode": args.mode,
        "summary": summary,
        "collapsed": collapsed,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 2 if args.fail_on_collapse and collapsed else 0


if __name__ == "__main__":
    raise SystemExit(main())
