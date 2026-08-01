from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


BASELINE_MODEL_ID = "hybrid_tactical_v1"
BASELINE_MODEL_KIND = "hybrid_tactical_prior"
PROTOCOL_VERSION = 2
FEATURE_SCHEMA_VERSION = 2
FEATURE_DIM = 142


def read_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return data


def read_int_constant(path: Path, name: str) -> int:
    match = re.search(rf"{re.escape(name)}\s*(?::\s*int)?\s*(?::=|=)\s*(\d+)", path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"{path}: missing integer constant {name}")
    return int(match.group(1))


def build_report(root: Path) -> dict[str, Any]:
    root = Path(root).resolve()
    checks: dict[str, Any] = {
        "python_protocol": None,
        "python_feature_schema": None,
        "python_feature_dim": None,
        "godot_protocol": None,
        "godot_feature_dim": None,
        "manifest_model_id": None,
        "manifest_kind": None,
        "manifest_protocol": None,
        "manifest_input_dim": None,
        "catalog_default_model_id": None,
        "catalog_protocol": None,
        "tactical_bc_enabled": None,
    }
    failures: list[str] = []

    def read_check(key: str, path: Path, name: str) -> None:
        try:
            checks[key] = read_int_constant(path, name)
        except (OSError, ValueError) as error:
            failures.append(f"{key} invariant failed: {error}")

    encoding_path = root / "training/rl/encoding.py"
    read_check("python_protocol", encoding_path, "HYBRID_PROTOCOL_VERSION")
    read_check("python_feature_schema", encoding_path, "TACTICAL_FEATURE_SCHEMA_VERSION")
    read_check("python_feature_dim", encoding_path, "TACTICAL_FEATURE_DIM")
    read_check("godot_protocol", root / "scripts/agents/hybrid/tactical_decision.gd", "PROTOCOL_VERSION")
    read_check("godot_feature_dim", root / "scripts/agents/hybrid/tactical_feature_builder.gd", "FEATURE_DIM")

    manifest: dict[str, Any] = {}
    catalog: dict[str, Any] = {}
    plan: dict[str, Any] = {}
    try:
        manifest = read_json(root / "training/models/hybrid_tactical_v1_agent.json")
        for key, field in (
            ("manifest_model_id", "model_id"),
            ("manifest_kind", "kind"),
            ("manifest_protocol", "protocol"),
            ("manifest_input_dim", "input_dim"),
        ):
            checks[key] = manifest.get(field)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        failures.append(f"manifest invariant failed: {error}")

    try:
        catalog = read_json(root / "training/models/model_catalog.json")
        checks["catalog_default_model_id"] = catalog.get("default_model_id")
        models = catalog.get("models")
        if not isinstance(models, list):
            raise ValueError("model catalog models must be a list")
        entry = next(
            (item for item in models if isinstance(item, dict) and item.get("model_id") == BASELINE_MODEL_ID),
            None,
        )
        if entry is None:
            raise ValueError(f"model catalog is missing v2 entry {BASELINE_MODEL_ID}")
        checks["catalog_protocol"] = entry.get("protocol")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        failures.append(f"catalog invariant failed: {error}")

    try:
        plan = read_json(root / "training/configs/training_plans/hybrid_tactical_local.json")
        tactical_bc = plan.get("tactical_behavior_clone")
        checks["tactical_bc_enabled"] = tactical_bc.get("enabled") if isinstance(tactical_bc, dict) else None
    except (OSError, ValueError, json.JSONDecodeError) as error:
        failures.append(f"tactical behavior cloning invariant failed: {error}")

    _check_equals(failures, "Python protocol", checks["python_protocol"], PROTOCOL_VERSION)
    _check_equals(failures, "Python feature schema", checks["python_feature_schema"], FEATURE_SCHEMA_VERSION)
    _check_equals(failures, "Python feature dimension", checks["python_feature_dim"], FEATURE_DIM)
    _check_equals(failures, "Godot protocol", checks["godot_protocol"], checks["python_protocol"])
    _check_equals(failures, "Godot feature dimension", checks["godot_feature_dim"], checks["python_feature_dim"])
    _check_equals(failures, "manifest model_id", checks["manifest_model_id"], BASELINE_MODEL_ID)
    _check_equals(failures, "manifest kind", checks["manifest_kind"], BASELINE_MODEL_KIND)
    _check_equals(failures, "manifest protocol", checks["manifest_protocol"], PROTOCOL_VERSION)
    if checks["manifest_input_dim"] != checks["python_feature_dim"]:
        failures.append(
            "manifest input_dim "
            f"{checks['manifest_input_dim']} does not equal Python feature dimension "
            f"{checks['python_feature_dim']}"
        )
    _check_equals(failures, "catalog default model_id", checks["catalog_default_model_id"], BASELINE_MODEL_ID)
    _check_equals(failures, "catalog v2 protocol", checks["catalog_protocol"], PROTOCOL_VERSION)
    if checks["catalog_default_model_id"] != BASELINE_MODEL_ID:
        failures.append("catalog default model and v2 entry invariant failed")
    _check_equals(failures, "tactical behavior cloning enabled", checks["tactical_bc_enabled"], True)

    return {
        "schema_version": 1,
        "root": str(root),
        "checks": checks,
        "failures": failures,
        "result": "pass" if not failures else "fail",
    }


def _check_equals(failures: list[str], name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        failures.append(f"{name} invariant failed: expected {expected!r}, got {actual!r}")


def main() -> int:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Audit the Hybrid Tactical v2 baseline contract.")
    parser.add_argument("--root", type=Path, default=project_root)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    report = build_report(args.root)
    output = json.dumps(report, indent=2)
    print(output)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    return 0 if report["result"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
