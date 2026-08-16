#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from statistics import mean
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from training.core.encoding import TACTICAL_FIRE_MODES
from training.core.godot_env import GodotStepEnv

DEFAULT_MATRIX = ROOT / "training" / "configs" / "evaluation_matrix.json"


def validate_inference_device(value: str) -> str:
    device = str(value).strip()
    if device in {"auto", "cpu", "cuda"} or re.fullmatch(r"cuda:[0-9]+", device):
        return device
    raise argparse.ArgumentTypeError("device must be one of: auto, cpu, cuda, cuda:N")


def selected_seeds(matrix: dict[str, Any], split: str = "holdout") -> list[int]:
    seed_sets = matrix.get("fixed_seed_sets", {})
    seeds = seed_sets.get(split)
    if not isinstance(seeds, list) or not seeds:
        raise ValueError(f"evaluation matrix has no fixed seed set '{split}'")
    return [int(seed) for seed in seeds]


def evaluate_gate_summary(metrics: dict[str, float], gates: dict[str, float]) -> dict[str, Any]:
    gate_results: dict[str, dict[str, Any]] = {}
    for gate, threshold in gates.items():
        metric_name, direction = _metric_for_gate(gate)
        actual = float(metrics.get(metric_name, 0.0))
        threshold_value = float(threshold)
        passed = actual >= threshold_value if direction == "min" else actual <= threshold_value
        gate_results[gate] = {
            "metric": metric_name,
            "direction": direction,
            "threshold": threshold_value,
            "actual": actual,
            "result": "pass" if passed else "fail",
        }
    return {
        "result": "pass" if all(item["result"] == "pass" for item in gate_results.values()) else "fail",
        "gates": gate_results,
    }


def evaluate_candidate(
    manifest: Path,
    matrix: dict[str, Any],
    output_dir: Path,
    godot_bin: str | None = None,
    match_runner: Callable[[dict[str, Any]], dict[str, float]] | None = None,
    split: str = "holdout",
    max_jobs: int | None = None,
) -> dict[str, Any]:
    if match_runner is None:
        match_runner = _unimplemented_match_runner
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_data = json.loads(Path(manifest).read_text(encoding="utf-8"))
    jobs = _evaluation_jobs(manifest, manifest_data, matrix, selected_seeds(matrix, split), godot_bin)
    if max_jobs is not None:
        jobs = jobs[: max(0, int(max_jobs))]
    for index, job in enumerate(jobs):
        job["service_log_path"] = str(output_dir / "service_logs" / f"match_{index:03d}.log")
    match_results: list[dict[str, Any]] = []
    for job in jobs:
        metrics = match_runner(job)
        match_results.append({"job": job, "metrics": metrics})
    aggregate = _aggregate_metrics([item["metrics"] for item in match_results])
    gate_summary = evaluate_gate_summary(aggregate, matrix.get("promotion_gates", {}))
    result = {
        "result": gate_summary["result"],
        "manifest": str(manifest),
        "model_id": manifest_data.get("model_id"),
        "split": split,
        "seeds": selected_seeds(matrix, split),
        "aggregate_metrics": aggregate,
        "gate_summary": gate_summary,
        "matches": match_results,
        "catalog_promotion": "not_performed",
    }
    (output_dir / "evaluation.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "evaluation_report_zh.md").write_text(
        _render_chinese_report(result),
        encoding="utf-8",
    )
    return result


def _evaluation_jobs(
    manifest_path: Path,
    manifest: dict[str, Any],
    matrix: dict[str, Any],
    seeds: list[int],
    godot_bin: str | None,
) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    maps = [str(value) for value in matrix.get("maps", [])]
    modes = list(matrix.get("modes", []))
    if not maps or not modes:
        raise ValueError("evaluation matrix must define at least one map and one mode")
    for mode in modes:
        for map_id in maps:
            for seed in seeds:
                jobs.append(
                    {
                        "manifest": str(manifest_path),
                        "model_id": manifest.get("model_id"),
                        "reward_profile_id": str(manifest.get("reward_profile_id", "baseline")).strip() or "baseline",
                        "map_id": map_id,
                        "mode_id": mode.get("id"),
                        "mode": mode.get("mode"),
                        "agents": int(mode.get("agents", 2)),
                        "seconds": int(mode.get("seconds", 90)),
                        "seed": int(seed),
                        "baseline": "scripted_hard",
                        "godot": godot_bin,
                        "runner_kind": "paired_baseline_unimplemented",
                    }
                )
    return jobs


def _aggregate_metrics(rows: list[dict[str, float]]) -> dict[str, float]:
    if not rows:
        return {}
    keys = sorted({key for row in rows for key in row})
    aggregated = {key: float(mean(float(row.get(key, 0.0)) for row in rows)) for key in keys}
    if "win_rate" in aggregated:
        aggregated["scripted_hard_all_maps_win_rate_1v1"] = aggregated["win_rate"]
    if "top1_rate" in aggregated:
        aggregated["scripted_hard_all_maps_top1_rate_ffa"] = aggregated["top1_rate"]
    if "environment_death_rate" in aggregated:
        aggregated["holdout_environment_death_rate"] = aggregated["environment_death_rate"]
    if "empty_fire_rate" in aggregated:
        aggregated["holdout_empty_fire_rate"] = aggregated["empty_fire_rate"]
    return aggregated


def aggregate_tactical_snapshots(snapshots: list[dict[str, Any]]) -> dict[str, float]:
    samples = 0
    fallback_count = 0
    safety_override_count = 0
    fire_blocked_count = 0
    fire_block_reasons: dict[str, int] = {}
    fire_counts = {label: 0 for label in TACTICAL_FIRE_MODES}
    component_totals: dict[str, float] = {}
    fallback_totals: dict[str, float] = {}
    previous_components: dict[str, dict[str, float]] = {}
    previous_fallbacks: dict[str, dict[str, float]] = {}
    for snapshot in snapshots:
        players = snapshot.get("players", {})
        if not isinstance(players, dict):
            continue
        for raw_player_id, player in players.items():
            if not isinstance(player, dict) or not bool(player.get("supports_tactical_decisions", False)):
                continue
            player_id = str(raw_player_id)
            samples += 1
            decision = player.get("executed_decision", {})
            fire_label = _fire_label(decision)
            fire_counts[fire_label] = fire_counts.get(fire_label, 0) + 1
            diagnostics = player.get("diagnostics", {})
            if isinstance(diagnostics, dict):
                fallback_count += int(bool(diagnostics.get("script_fallback", False)))
                safety_override_count += int(bool(diagnostics.get("safety_override", False)))
                reason = str(diagnostics.get("fire_block_reason", "")).strip()
                if reason:
                    fire_blocked_count += 1
                    reason_key = _metric_key(reason)
                    fire_block_reasons[reason_key] = fire_block_reasons.get(reason_key, 0) + 1
                _update_cumulative_metric_totals(
                    fallback_totals,
                    previous_fallbacks,
                    player_id,
                    diagnostics.get("fallback_counts", {}),
                )
            _update_cumulative_metric_totals(
                component_totals,
                previous_components,
                player_id,
                player.get("reward_components", {}),
            )
    denominator = max(samples, 1)
    metrics: dict[str, float] = {
        "samples": float(samples),
        "fallback_rate": float(fallback_count / denominator),
        "safety_override_rate": float(safety_override_count / denominator),
        "fire_blocked_rate": float(fire_blocked_count / denominator),
    }
    for label in TACTICAL_FIRE_MODES:
        metrics[f"fire_mode_{label}_rate"] = float(fire_counts.get(label, 0) / denominator)
    for reason, count in sorted(fire_block_reasons.items()):
        metrics[f"fire_block_reason_{reason}_rate"] = float(count / denominator)
    for key, value in component_totals.items():
        metrics[key] = float(value)
    for key, value in fallback_totals.items():
        metrics[f"fallback_{key}"] = float(value)
    metrics["empty_fire_rate"] = float(fallback_totals.get("no_target_fire", 0.0) / denominator)
    environment_deaths = 0.0
    for key, value in component_totals.items():
        if key.endswith("_death") and key in {"environment_death", "void_death"}:
            environment_deaths += abs(value) / 0.75
    metrics["environment_death_rate"] = float(environment_deaths / denominator)
    metrics.update(_match_result_metrics(snapshots))
    return metrics


def _match_result_metrics(snapshots: list[dict[str, Any]]) -> dict[str, float]:
    final_snapshot = None
    for snapshot in snapshots:
        if bool(snapshot.get("terminated", False)):
            final_snapshot = snapshot
    if not isinstance(final_snapshot, dict):
        return {}
    info = final_snapshot.get("info", {})
    if not isinstance(info, dict):
        return {}
    result = info.get("match_result", {})
    if not isinstance(result, dict):
        return {}
    standings = result.get("standings", [])
    if not isinstance(standings, list) or not standings:
        return {}
    candidate_ids = _candidate_player_ids(final_snapshot)
    if not candidate_ids:
        return {}
    ranked_entries: list[tuple[int, dict[str, Any]]] = []
    for index, entry in enumerate(standings, start=1):
        if isinstance(entry, dict) and int(entry.get("player_id", -1)) in candidate_ids:
            ranked_entries.append((index, entry))
    if not ranked_entries:
        return {}
    _, candidate_entry = min(ranked_entries, key=lambda item: item[0])
    candidate_score = float(candidate_entry.get("score", 0.0))
    opponent_scores = [
        float(entry.get("score", 0.0))
        for entry in standings
        if isinstance(entry, dict) and int(entry.get("player_id", -1)) not in candidate_ids
    ]
    best_opponent_score = max(opponent_scores, default=candidate_score)
    score_margin = candidate_score - best_opponent_score
    rank = 1 + sum(score > candidate_score for score in opponent_scores)
    metrics = {
        "matches_completed": 1.0,
        "win_rate": 1.0 if score_margin > 0.0 else 0.0,
        "top1_rate": 1.0 if score_margin > 0.0 else 0.0,
        "top2_rate": 1.0 if rank <= 2 else 0.0,
        "candidate_rank": float(rank),
        "candidate_score": candidate_score,
        "candidate_score_margin": score_margin,
    }
    if bool(result.get("team_mode", False)):
        team_id = int(candidate_entry.get("team_id", -1))
        team_scores = result.get("team_scores", {})
        if isinstance(team_scores, dict) and team_scores:
            candidate_team_score = float(team_scores.get(str(team_id), team_scores.get(team_id, 0.0)))
            opponent_team_scores = [
                float(value)
                for raw_team_id, value in team_scores.items()
                if str(raw_team_id) != str(team_id) and isinstance(value, (int, float))
            ]
            best_opponent_team_score = max(opponent_team_scores, default=candidate_team_score)
            team_score_margin = candidate_team_score - best_opponent_team_score
            metrics["candidate_team_score"] = candidate_team_score
            metrics["candidate_team_score_margin"] = team_score_margin
            metrics["team_win_rate"] = 1.0 if team_score_margin > 0.0 else 0.0
    return metrics


def _candidate_player_ids(snapshot: dict[str, Any]) -> set[int]:
    info = snapshot.get("info", {})
    if isinstance(info, dict):
        raw_ids = info.get("tactical_player_ids", [])
        if isinstance(raw_ids, list):
            ids = {int(value) for value in raw_ids if isinstance(value, (int, str)) and str(value).lstrip("-").isdigit()}
            if ids:
                return ids
    players = snapshot.get("players", {})
    if not isinstance(players, dict):
        return set()
    return {
        int(player_id)
        for player_id, player in players.items()
        if str(player_id).lstrip("-").isdigit()
        and isinstance(player, dict)
        and bool(player.get("supports_tactical_decisions", False))
    }


def build_godot_service_runner(
    *,
    port_start: int = 18780,
    model_port_start: int = 18880,
    ticks: int = 8,
    device: str = "cpu",
    startup_timeout: float = 60.0,
) -> Callable[[dict[str, Any]], dict[str, float]]:
    counter = {"index": 0}

    def runner(job: dict[str, Any]) -> dict[str, float]:
        index = counter["index"]
        counter["index"] += 1
        enriched = dict(job)
        enriched["port"] = int(port_start) + index
        enriched["model_port"] = int(model_port_start) + index
        enriched["ticks"] = int(ticks)
        enriched["device"] = device
        enriched["startup_timeout"] = float(startup_timeout)
        return run_godot_service_match(enriched)

    return runner


def run_godot_service_match(job: dict[str, Any]) -> dict[str, float]:
    model_port = int(job.get("model_port", 18880))
    training_port = int(job.get("port", 18780))
    service = _start_agent_service(
        manifest=Path(str(job["manifest"])),
        port=model_port,
        device=str(job.get("device", "cpu")),
        log_path=Path(str(job.get("service_log_path", ROOT / "test-results" / "service.log"))),
    )
    try:
        _wait_for_tcp("127.0.0.1", model_port, float(job.get("startup_timeout", 60.0)))
        snapshots: list[dict[str, Any]] = []
        with GodotStepEnv(
            port=training_port,
            godot=job.get("godot"),
            startup_timeout=float(job.get("startup_timeout", 60.0)),
        ) as env:
            env.reset(_service_match_config(job, model_port))
            snapshots.append(env.observe_tactical())
            ticks = max(1, int(job.get("ticks", 8)))
            step_count = _service_step_count(seconds=float(job.get("seconds", 90)), ticks=ticks)
            for _ in range(step_count):
                response = env.step({}, ticks=ticks)
                tactical = env.observe_tactical()
                snapshots.append(tactical)
                if bool(response.get("terminated", False)) or bool(tactical.get("terminated", False)):
                    break
        metrics = aggregate_tactical_snapshots(snapshots)
        metrics["service_backed_match"] = 1.0
        metrics["paired_baseline_match"] = 1.0
        return metrics
    finally:
        _terminate_process(service)


def _service_step_count(*, seconds: float, ticks: int) -> int:
    countdown_seconds = 3.0
    settle_seconds = 1.0
    simulated_seconds = max(0.0, float(seconds)) + countdown_seconds + settle_seconds
    return max(1, int(math.ceil(simulated_seconds * 60.0 / max(1, int(ticks)))))


def _fire_label(decision: Any) -> str:
    if isinstance(decision, dict):
        name = str(decision.get("fire_name", "")).strip()
        if name:
            return name
        index = int(decision.get("fire_mode", 0))
        if 0 <= index < len(TACTICAL_FIRE_MODES):
            return TACTICAL_FIRE_MODES[index]
    return "UNKNOWN"


def _metric_key(value: str) -> str:
    out = []
    for character in value.strip().lower():
        if character.isalnum():
            out.append(character)
        else:
            out.append("_")
    return "_".join(part for part in "".join(out).split("_") if part)


def _update_cumulative_metric_totals(
    totals: dict[str, float],
    previous_by_player: dict[str, dict[str, float]],
    player_id: str,
    values: Any,
) -> None:
    if not isinstance(values, dict):
        return
    current = {
        str(key): float(value)
        for key, value in values.items()
        if isinstance(value, (int, float))
    }
    previous = previous_by_player.get(player_id, {})
    for key, value in current.items():
        previous_value = previous.get(key, 0.0)
        delta = value - previous_value if value >= previous_value else value
        if delta:
            totals[key] = totals.get(key, 0.0) + float(delta)
    previous_by_player[player_id] = current


def _service_match_config(job: dict[str, Any], model_port: int) -> dict[str, Any]:
    mode = str(job.get("mode", "ffa"))
    return {
        "mode": mode,
        "human_player_count": 0,
        "agent_count": int(job.get("agents", 2)),
        "team_mode": mode == "team_2v2",
        "friendly_fire": mode != "team_2v2",
        "time_limit": float(job.get("seconds", 90)),
        "score_limit": 0,
        "map_id": str(job.get("map_id", "dungeon")),
        "agent_difficulty": "hard",
        "agent_controller": "scripted",
        "agent_controller_overrides": {"0": "hybrid"},
        "agent_model_id": "",
        "agent_model_id_overrides": {"0": str(job.get("model_id", ""))},
        "agent_model_host": "127.0.0.1",
        "agent_model_port": int(model_port),
        "agent_model_timeout_ms": int(job.get("agent_model_timeout_ms", 64)),
        "reward_profile_id": str(job.get("reward_profile_id", "baseline")),
        "random_seed": int(job.get("seed", 1234)),
        "headless": True,
        "record_replay": False,
        "training_fast_mode": True,
    }


def _start_agent_service(manifest: Path, port: int, device: str, log_path: Path) -> subprocess.Popen:
    command = [
        sys.executable,
        "-m",
        "training.inference.serve_agent",
        "--manifest",
        str(manifest),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--device",
        device,
    ]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as stream:
        return subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=stream,
            stderr=subprocess.STDOUT,
            text=True,
        )


def _wait_for_tcp(host: str, port: int, timeout: float) -> None:
    deadline = time.time() + timeout
    last_error: OSError | None = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return
        except OSError as exc:
            last_error = exc
            time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for TCP service on {host}:{port}: {last_error}")


def _terminate_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _metric_for_gate(gate: str) -> tuple[str, str]:
    if gate.startswith("holdout_max_"):
        return "holdout_" + gate.removeprefix("holdout_max_"), "max"
    if "_min_" in gate:
        prefix, suffix = gate.split("_min_", 1)
        return f"{prefix}_{suffix}", "min"
    if gate.endswith("_max"):
        return gate[:-4], "max"
    if gate.endswith("_min"):
        return gate[:-4], "min"
    return gate, "min"


def _render_chinese_report(result: dict[str, Any]) -> str:
    lines = [
        "# 固定 seed 评测报告",
        "",
        f"- 模型：`{result.get('model_id')}`",
        f"- 结果：`{result.get('result')}`",
        f"- seed 集合：`{result.get('split')}` = {result.get('seeds')}",
        "- 安全约束：本工具不执行 catalog 晋级；通过 gate 后仍需人工确认和单独 promotion 命令。",
        "",
        "## 聚合指标",
        "",
    ]
    for key, value in sorted(result.get("aggregate_metrics", {}).items()):
        lines.append(f"- `{key}`：{float(value):.6f}")
    lines.extend(["", "## Gate", ""])
    for gate, item in result.get("gate_summary", {}).get("gates", {}).items():
        lines.append(
            f"- `{gate}`：{item['result']}，actual={item['actual']:.6f}，threshold={item['threshold']:.6f}"
        )
    lines.extend(
        [
            "",
            "## 输入",
            "",
            f"- manifest：`{result.get('manifest')}`",
            f"- match 数：{len(result.get('matches', []))}",
            "",
            "## 晋级",
            "",
            "不执行 catalog 晋级。本报告只给出 gate 结果和人工审核材料。",
            "",
        ]
    )
    return "\n".join(lines)


def _unimplemented_match_runner(_job: dict[str, Any]) -> dict[str, float]:
    raise RuntimeError(
        "No match_runner supplied. Wire a Godot paired-evaluation runner before executing the full matrix."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate a Hybrid Tactical candidate on fixed seeds.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--matrix", default=str(DEFAULT_MATRIX))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--godot")
    parser.add_argument("--split", default="holdout")
    parser.add_argument("--runner", choices=["none", "godot-service"], default="none")
    parser.add_argument("--max-jobs", type=int, default=None)
    parser.add_argument("--seconds", type=float, default=None, help="Override matrix mode seconds for smoke runs.")
    parser.add_argument("--port-start", type=int, default=18780)
    parser.add_argument("--model-port-start", type=int, default=18880)
    parser.add_argument("--ticks", type=int, default=8)
    parser.add_argument("--device", default="cpu", type=validate_inference_device)
    parser.add_argument("--startup-timeout", type=float, default=60.0)
    args = parser.parse_args()
    matrix = json.loads(Path(args.matrix).read_text(encoding="utf-8"))
    if args.seconds is not None:
        matrix = dict(matrix)
        matrix["modes"] = [
            {**mode, "seconds": float(args.seconds)}
            for mode in matrix.get("modes", [])
        ]
    match_runner = None
    if args.runner == "godot-service":
        match_runner = build_godot_service_runner(
            port_start=args.port_start,
            model_port_start=args.model_port_start,
            ticks=args.ticks,
            device=args.device,
            startup_timeout=args.startup_timeout,
        )
    result = evaluate_candidate(
        Path(args.manifest),
        matrix,
        Path(args.output_dir),
        godot_bin=args.godot,
        match_runner=match_runner,
        split=args.split,
        max_jobs=args.max_jobs,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
