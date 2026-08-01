#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from statistics import mean
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DEFAULT_MATRIX = ROOT / "training" / "configs" / "evaluation_matrix.json"


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
) -> dict[str, Any]:
    if match_runner is None:
        match_runner = _unimplemented_match_runner
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_data = json.loads(Path(manifest).read_text(encoding="utf-8"))
    jobs = _evaluation_jobs(manifest, manifest_data, matrix, selected_seeds(matrix, split), godot_bin)
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
                        "map_id": map_id,
                        "mode_id": mode.get("id"),
                        "mode": mode.get("mode"),
                        "agents": int(mode.get("agents", 2)),
                        "seconds": int(mode.get("seconds", 90)),
                        "seed": int(seed),
                        "baseline": "scripted_hard",
                        "godot": godot_bin,
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
    args = parser.parse_args()
    matrix = json.loads(Path(args.matrix).read_text(encoding="utf-8"))
    result = evaluate_candidate(
        Path(args.manifest),
        matrix,
        Path(args.output_dir),
        godot_bin=args.godot,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
