#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GODOT = ROOT / ".tools" / "godot-4.7.1" / "Godot_v4.7.1-stable_linux.x86_64"
MASK_SIZES = {
    "target_slot": 7,
    "movement_mode": 12,
    "fire_mode": 6,
    "skill_mode": 6,
}
PRIVATE_DIAGNOSTIC_TOKENS = (
    "ammo",
    "reserve",
    "energy",
    "magazine",
    "reload",
    "cooldown",
)


def resolve_godot(explicit: str | None) -> str:
    candidates = [
        explicit,
        os.environ.get("GODOT_BIN"),
        str(DEFAULT_GODOT) if DEFAULT_GODOT.is_file() else None,
        shutil.which("godot4"),
        shutil.which("godot"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    raise RuntimeError("Godot 4 was not found; pass --godot or set GODOT_BIN")


class TcpJsonlClient:
    def __init__(self, host: str, port: int, timeout: float) -> None:
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.stream = self.sock.makefile("rwb")

    def request(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.stream.write(
            json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        )
        self.stream.flush()
        line = self.stream.readline()
        if not line:
            raise AssertionError("training server closed the TCP stream")
        return json.loads(line.decode("utf-8"))

    def read(self) -> dict[str, Any]:
        line = self.stream.readline()
        if not line:
            raise AssertionError("training server closed before hello")
        return json.loads(line.decode("utf-8"))

    def close(self) -> None:
        try:
            self.request({"cmd": "close"})
        except (OSError, AssertionError):
            pass
        finally:
            self.stream.close()
            self.sock.close()


def connect_when_ready(
    process: subprocess.Popen[bytes], host: str, port: int, timeout: float, log_path: Path
) -> TcpJsonlClient:
    deadline = time.monotonic() + timeout
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            return TcpJsonlClient(host, port, 2.0)
        except OSError as exc:
            last_error = exc
            if process.poll() is not None:
                raise AssertionError(
                    f"training server exited {process.returncode}: {read_log_tail(log_path)}"
                ) from exc
            time.sleep(0.1)
    raise AssertionError(
        f"training server did not listen on {host}:{port}: {last_error}; "
        f"log={read_log_tail(log_path)}"
    )


def read_log_tail(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")[-4000:]


def reset(
    client: TcpJsonlClient,
    human_count: int,
    agent_count: int,
    seed: int,
    extra_config: dict[str, Any] | None = None,
) -> None:
    config = {
        "mode": "ffa",
        "human_player_count": human_count,
        "agent_count": agent_count,
        "team_mode": False,
        "friendly_fire": True,
        "time_limit": 5.0,
        "map_id": "dungeon",
        "agent_difficulty": "hard",
        "agent_controller": "hybrid",
        "agent_model_id": "hybrid_tactical_v1",
        "random_seed": seed,
        "headless": True,
    }
    if extra_config:
        config.update(extra_config)
    response = client.request(
        {
            "cmd": "reset",
            "config": config,
        }
    )
    assert response["type"] == "reset_ok", response


def first_legal(mask: list[bool]) -> int:
    return next(index for index, allowed in enumerate(mask) if allowed)


def decisions_from_snapshot(snapshot: dict[str, Any], id_base: int) -> dict[str, Any]:
    decisions: dict[str, Any] = {}
    for player_id in snapshot["info"]["tactical_player_ids"]:
        player = snapshot["players"][str(player_id)]
        masks = player["action_masks"]
        decisions[str(player_id)] = {
            "protocol": 2,
            "target_slot": first_legal(masks["target_slot"]),
            "movement_mode": first_legal(masks["movement_mode"]),
            "fire_mode": first_legal(masks["fire_mode"]),
            "skill_mode": first_legal(masks["skill_mode"]),
            "confidence": 1.0,
            "decision_id": id_base + int(player_id),
        }
    return decisions


def private_diagnostic_paths(value: Any, path: str = "diagnostics") -> list[str]:
    findings: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            normalized = str(key).lower().replace("-", "_")
            child_path = f"{path}.{key}"
            if any(token in normalized for token in PRIVATE_DIAGNOSTIC_TOKENS):
                findings.append(child_path)
            findings.extend(private_diagnostic_paths(nested, child_path))
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            findings.extend(private_diagnostic_paths(nested, f"{path}[{index}]"))
    return findings


def assert_tactical_snapshot(
    snapshot: dict[str, Any], expected_tactical_ids: list[int]
) -> None:
    assert snapshot["protocol"] == 2, snapshot
    assert isinstance(snapshot["terminated"], bool), snapshot
    assert isinstance(snapshot["truncated"], bool), snapshot
    assert snapshot["info"]["tactical_player_ids"] == expected_tactical_ids, snapshot
    if snapshot["terminated"]:
        result = snapshot["info"].get("match_result")
        assert isinstance(result, dict), snapshot
        assert isinstance(result.get("standings"), list), snapshot
        assert "winner_player_id" in result, snapshot
    for player_id, player in snapshot["players"].items():
        controllable = int(player_id) in expected_tactical_ids
        assert player["supports_tactical_decisions"] is controllable, player
        if not controllable:
            assert "tactical_features" not in player, player
            assert "action_masks" not in player, player
            continue
        assert len(player["tactical_features"]) == 142, player
        assert set(player["action_masks"]) == set(MASK_SIZES), player
        for head, size in MASK_SIZES.items():
            assert len(player["action_masks"][head]) == size, player
        assert isinstance(player["reward_delta"], (int, float)), player
        assert not private_diagnostic_paths(player["diagnostics"]), player["diagnostics"]


def run_smoke(godot: str, host: str, port: int, timeout: float) -> dict[str, Any]:
    result_dir = ROOT / "test-results"
    result_dir.mkdir(parents=True, exist_ok=True)
    log_path = result_dir / "tactical-training-protocol.log"
    command = [
        godot,
        "--headless",
        "--disable-crash-handler",
        "--log-file",
        str(log_path),
        "--path",
        str(ROOT),
        "--",
        "--training-server",
        f"--port={port}",
    ]
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    client: TcpJsonlClient | None = None
    try:
        client = connect_when_ready(process, host, port, timeout, log_path)
        hello = client.read()
        assert hello["type"] == "hello", hello

        reset(client, human_count=0, agent_count=2, seed=74102)
        observed = client.request({"cmd": "observe_tactical"})
        assert observed["type"] == "observe_tactical", observed
        assert_tactical_snapshot(observed, [0, 1])
        assert observed["info"]["reward_profile_id"] == "baseline", observed
        decisions = decisions_from_snapshot(observed, 9100)

        raw_error = client.request(
            {
                "cmd": "step_tactical",
                "decisions": {"0": {"move_x": 1.0}, "1": decisions["1"]},
                "ticks": 1,
            }
        )
        assert raw_error["type"] == "error", raw_error
        assert "move_x" in raw_error["message"], raw_error

        stepped = client.request(
            {"cmd": "step_tactical", "decisions": decisions, "ticks": 190}
        )
        assert stepped["type"] == "step_tactical", stepped
        assert_tactical_snapshot(stepped, [0, 1])
        for player_id, player in stepped["players"].items():
            executed = player["executed_decision"]
            for head in MASK_SIZES:
                assert player["action_masks"][head][executed[head]], player
            assert executed["decision_id"] == decisions[player_id]["decision_id"], player

        partial_error = client.request(
            {
                "cmd": "step_tactical",
                "decisions": {"0": {**decisions["0"], "decision_id": 9999}},
                "ticks": 1,
            }
        )
        assert partial_error["type"] == "error", partial_error
        assert "exactly" in partial_error["message"].lower(), partial_error

        reset(client, human_count=1, agent_count=1, seed=74103)
        mixed = client.request({"cmd": "observe_tactical"})
        assert_tactical_snapshot(mixed, [1])
        mixed_decisions = decisions_from_snapshot(mixed, 9200)
        mixed_step = client.request(
            {"cmd": "step_tactical", "decisions": mixed_decisions, "ticks": 190}
        )
        assert mixed_step["type"] == "step_tactical", mixed_step
        assert_tactical_snapshot(mixed_step, [1])

        reset(
            client,
            human_count=0,
            agent_count=2,
            seed=74104,
            extra_config={
                "agent_controller": "scripted",
                "agent_controller_overrides": {"0": "hybrid"},
                "agent_model_id_overrides": {"0": "hybrid_tactical_v1"},
                "time_limit": 0.05,
                "reward_profile_id": "score_margin_discipline",
            },
        )
        paired = client.request({"cmd": "observe_tactical"})
        assert_tactical_snapshot(paired, [0])
        assert paired["info"]["reward_profile_id"] == "score_margin_discipline", paired
        paired_decisions = decisions_from_snapshot(paired, 9300)
        paired_result = client.request(
            {"cmd": "step_tactical", "decisions": paired_decisions, "ticks": 220}
        )
        assert paired_result["type"] == "step_tactical", paired_result
        assert paired_result["terminated"] is True, paired_result
        assert_tactical_snapshot(paired_result, [0])
        paired_match_result = paired_result["info"]["match_result"]
        paired_standings = paired_match_result["standings"]
        if len(paired_standings) >= 2 and paired_standings[0]["score"] == paired_standings[1]["score"]:
            assert paired_match_result["winner_player_id"] == -1, paired_match_result
            assert "win" not in paired_result["players"]["0"]["reward_components"], paired_result

        extra_error = client.request(
            {
                "cmd": "step_tactical",
                "decisions": {
                    "0": {
                        "protocol": 2,
                        "target_slot": 0,
                        "movement_mode": 0,
                        "fire_mode": 0,
                        "skill_mode": 0,
                    },
                    **mixed_decisions,
                },
                "ticks": 1,
            }
        )
        assert extra_error["type"] == "error", extra_error

        legacy = client.request(
            {
                "cmd": "step",
                "actions": {
                    "0": {
                        "move": {"x": 0.0, "y": 0.0},
                        "aim": {"x": 1.0, "y": 0.0},
                    },
                    "1": {
                        "move": {"x": 0.0, "y": 0.0},
                        "aim": {"x": -1.0, "y": 0.0},
                    },
                },
                "ticks": 1,
            }
        )
        assert legacy["type"] == "step", legacy
        return {
            "protocol": stepped["protocol"],
            "feature_lengths": [
                len(stepped["players"][player_id]["tactical_features"])
                for player_id in ("0", "1")
            ],
            "mask_lengths": {
                head: len(stepped["players"]["0"]["action_masks"][head])
                for head in MASK_SIZES
            },
            "executed_decision_ids": [
                stepped["players"][player_id]["executed_decision"]["decision_id"]
                for player_id in ("0", "1")
            ],
            "mixed_tactical_player_ids": mixed["info"]["tactical_player_ids"],
            "paired_tactical_player_ids": paired["info"]["tactical_player_ids"],
            "paired_winner_player_id": paired_result["info"]["match_result"]["winner_player_id"],
            "raw_rejection": raw_error["message"],
            "partial_rejection": partial_error["message"],
            "legacy_type": legacy["type"],
        }
    finally:
        if client is not None:
            client.close()
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5.0)
        if process.returncode not in (0, None):
            raise AssertionError(
                f"training server exited {process.returncode}: {read_log_tail(log_path)}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18766)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    result = run_smoke(resolve_godot(args.godot), args.host, args.port, args.timeout)
    print(json.dumps(result, sort_keys=True))
    print("PASS: tactical training protocol TCP smoke")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
