#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = ROOT / "training" / "models" / "model_catalog.json"
DEFAULT_CHECKPOINT_DIR = ROOT / "training" / "checkpoints" / "hybrid"
DEFAULT_MANIFEST_DIR = ROOT / "training" / "models"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def safe_model_id(value: str) -> str:
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    cleaned = "".join(ch if ch in allowed else "_" for ch in value.strip())
    if not cleaned:
        raise SystemExit("model-id cannot be empty")
    if cleaned[0].isdigit():
        cleaned = "m_" + cleaned
    return cleaned


def copy_checkpoint(source: Path, model_id: str) -> Path:
    if not source.exists():
        raise SystemExit(f"Checkpoint not found: {source}")
    DEFAULT_CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    suffix = source.suffix or ".pt"
    target = DEFAULT_CHECKPOINT_DIR / f"{model_id}{suffix}"
    shutil.copy2(source, target)
    return target


def build_manifest(args: argparse.Namespace, checkpoint_path: Path) -> dict[str, Any]:
    metrics = load_json(args.metrics_json) if args.metrics_json else {}
    kind = str(getattr(args, "kind", "tactical_policy"))
    reward_profile_id = str(getattr(args, "reward_profile_id", "baseline")).strip()
    if not reward_profile_id:
        raise SystemExit("reward-profile-id cannot be empty")
    return {
        "schema_version": 2,
        "model_id": args.model_id,
        "label": args.label or args.model_id.replace("_", " ").title(),
        "kind": kind,
        "checkpoint": str(checkpoint_path.relative_to(ROOT)).replace("\\", "/"),
        "input_dim": int(args.input_dim),
        "hidden": int(args.hidden),
        "protocol": 2,
        "observation_schema_version": 2,
        "tactical_action_schema_version": 2,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "training_run_id": args.run_id,
        "reward_profile_id": reward_profile_id,
        "description": args.description,
        "metrics": metrics,
    }


def update_catalog(manifest_path: Path, model_id: str, label: str, kind: str, promote_default: bool) -> None:
    catalog = load_json(DEFAULT_CATALOG) if DEFAULT_CATALOG.exists() else {"schema_version": 3, "default_model_id": model_id, "models": []}
    models = [entry for entry in catalog.get("models", []) if entry.get("model_id") != model_id]
    models.append({
        "model_id": model_id,
        "label": label,
        "manifest": str(manifest_path.relative_to(ROOT)).replace("\\", "/"),
        "kind": kind,
        "protocol": 2,
        "description": "Imported Hybrid Tactical v2 trained policy.",
    })
    catalog["models"] = models
    if promote_default:
        catalog["default_model_id"] = model_id
    elif not catalog.get("default_model_id"):
        catalog["default_model_id"] = model_id
    write_json(DEFAULT_CATALOG, catalog)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Import a trained Hybrid Tactical checkpoint into the local model registry.")
    parser.add_argument("--checkpoint", type=Path, required=True, help="Path to server-trained .pt checkpoint.")
    parser.add_argument("--model-id", required=True, help="Stable model id, e.g. hybrid_tactical_v2_bc_s01.")
    parser.add_argument("--label", default="", help="Human-readable label for menus and reports.")
    parser.add_argument("--kind", choices=["tactical_policy", "tactical_actor_critic"], default="tactical_policy")
    parser.add_argument("--run-id", default="", help="Server run id or experiment id.")
    parser.add_argument("--hidden", type=int, default=256)
    parser.add_argument("--input-dim", type=int, default=142)
    parser.add_argument("--metrics-json", type=Path, default=None, help="Optional metrics JSON exported by the server run.")
    parser.add_argument("--reward-profile-id", default="baseline", help="Immutable reward/feature profile used for this trained candidate.")
    parser.add_argument("--description", default="Imported trained Hybrid Tactical v2 policy.")
    parser.add_argument("--update-catalog", action="store_true")
    parser.add_argument("--promote-default", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.model_id = safe_model_id(args.model_id)
    checkpoint_path = copy_checkpoint(args.checkpoint.resolve(), args.model_id)
    manifest = build_manifest(args, checkpoint_path)
    manifest_path = DEFAULT_MANIFEST_DIR / f"{args.model_id}_agent.json"
    write_json(manifest_path, manifest)
    if args.update_catalog or args.promote_default:
        update_catalog(manifest_path, args.model_id, str(manifest["label"]), str(manifest["kind"]), args.promote_default)
    print(json.dumps({
        "imported": True,
        "model_id": args.model_id,
        "checkpoint": str(checkpoint_path.relative_to(ROOT)).replace("\\", "/"),
        "manifest": str(manifest_path.relative_to(ROOT)).replace("\\", "/"),
        "catalog_updated": bool(args.update_catalog or args.promote_default),
        "promoted_default": bool(args.promote_default),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
