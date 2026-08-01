#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import io
import json
import tarfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / "training" / "packages"
DEFAULT_BUNDLE_ID = "pulsearena_hybrid_tactical_v2_agent_bundle"

INCLUDE_ROOT_FILES = [
    "project.godot",
    "export_presets.cfg",
    "Makefile",
    "README.md",
    "LICENSE",
    "requirements.txt",
    "requirements-training.txt",
]

INCLUDE_DIRS = [
    "assets",
    "docs",
    "resources",
    "scenes",
    "scripts",
    "tests",
    "training",
]

EXCLUDE_DIRS = {
    ".agents",
    ".git",
    ".godot",
    ".godot_user",
    "archive",
    "training/godot_user",
    "training/packages",
    "training/runs",
    "training/replays",
    "training/replays_decision",
}

EXCLUDE_NAMES = {
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
}

EXCLUDE_PATTERNS = [
    "*.pyc",
    "*.pyo",
    "*.tmp",
    "*.temp",
    "*.log",
    "*.pt",
    "*.pth",
    "*.onnx",
    "*.zip",
    "*.tar",
    "*.tar.gz",
    "*.jsonl",
]

KEEP_FILES_IN_EXCLUDED_DIRS = {
    "training/replays/.gitkeep",
    "training/incoming_models/README.md",
    "training/checkpoints/hybrid/README.md",
}


@dataclass(frozen=True)
class BundleFile:
    source: Path
    arcname: str
    size: int
    sha256: str


def rel_posix(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def display_path(path: Path) -> str:
    """Use a portable project-relative path when possible, otherwise absolute."""
    try:
        return rel_posix(path)
    except ValueError:
        return str(path.resolve())


def is_excluded(path: Path) -> bool:
    rel = rel_posix(path)
    if rel in KEEP_FILES_IN_EXCLUDED_DIRS:
        return False
    parts = rel.split("/")
    if any(part in EXCLUDE_NAMES for part in parts):
        return True
    for index in range(1, len(parts) + 1):
        if "/".join(parts[:index]) in EXCLUDE_DIRS:
            return True
    return any(fnmatch.fnmatch(path.name, pattern) for pattern in EXCLUDE_PATTERNS)


def iter_candidate_paths() -> Iterable[Path]:
    for filename in INCLUDE_ROOT_FILES:
        path = ROOT / filename
        if path.exists():
            yield path
    for dirname in INCLUDE_DIRS:
        root = ROOT / dirname
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file():
                yield path


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_files() -> list[BundleFile]:
    files: list[BundleFile] = []
    seen: set[str] = set()
    for path in iter_candidate_paths():
        rel = rel_posix(path)
        if rel in seen or is_excluded(path):
            continue
        seen.add(rel)
        files.append(BundleFile(source=path, arcname=rel, size=path.stat().st_size, sha256=hash_file(path)))
    files.sort(key=lambda item: item.arcname)
    return files


def build_manifest(bundle_name: str, files: list[BundleFile], created_at: str) -> dict:
    payload = {
        "schema_version": 2,
        "bundle_name": bundle_name,
        "created_at": created_at,
        "purpose": "Hybrid Tactical v2 agent-guided server training bundle",
        "server_agent_entrypoint": "training/server_agent/SERVER_AGENT_PROMPT_zh.md",
        "entrypoints": {
            "agent_prompt": "training/server_agent/SERVER_AGENT_PROMPT_zh.md",
            "safe_pilot": "bash training/server_train_hybrid_tactical_v2.sh",
            "validate": "python training/train_pipeline.py --profile full_distributed_league --plan hybrid_tactical_v2_server_pilot_bc --phase validate",
            "replay_audit": "python training/server_agent/audit_hybrid_replays.py --replay-dir training/replays",
            "decision_dataset": "python training/server_agent/prepare_hybrid_replays.py --input-dir training/replays --output-dir training/replays_decision",
            "web_preview": {
                "export": "make web-export",
                "start": "make web-start",
                "status": "make web-status",
                "stop": "make web-stop",
            },
        },
        "excludes": {
            "directories": sorted(EXCLUDE_DIRS),
            "patterns": sorted(EXCLUDE_PATTERNS),
            "kept_files_in_excluded_dirs": sorted(KEEP_FILES_IN_EXCLUDED_DIRS),
        },
        "file_count": len(files),
        "total_bytes": sum(item.size for item in files),
        "files": [
            {
                "path": item.arcname,
                "size": item.size,
                "sha256": item.sha256,
            }
            for item in files
        ],
    }
    return payload


def write_manifest(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def create_tarball(path: Path, files: list[BundleFile], package_root: str, manifest: dict) -> None:
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for item in files:
            archive.add(item.source, arcname=f"{package_root}/{item.arcname}", recursive=False)
        manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        manifest_info = tarfile.TarInfo(name=f"{package_root}/BUNDLE_MANIFEST.json")
        manifest_info.size = len(manifest_bytes)
        manifest_info.mode = 0o644
        archive.addfile(manifest_info, io.BytesIO(manifest_bytes))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a clean Ubuntu server training bundle for Hybrid Tactical v2.")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--stamp", default="", help="Optional fixed stamp for reproducible bundle names.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    stamp = args.stamp or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    package_root = f"{args.bundle_id}_{stamp}"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    files = collect_files()
    bundle_path = args.output_dir / f"{package_root}.tar.gz"
    manifest_path = args.output_dir / f"{package_root}.manifest.json"
    checksum_path = args.output_dir / f"{package_root}.tar.gz.sha256"
    manifest = build_manifest(bundle_path.name, files, datetime.now(timezone.utc).isoformat())
    write_manifest(manifest_path, manifest)
    create_tarball(bundle_path, files, package_root, manifest)
    checksum_path.write_text(f"{hash_file(bundle_path)}  {bundle_path.name}\n", encoding="utf-8")
    print(json.dumps({
        "bundle": display_path(bundle_path),
        "manifest": display_path(manifest_path),
        "sha256": display_path(checksum_path),
        "package_root": package_root,
        "file_count": manifest["file_count"],
        "total_bytes": manifest["total_bytes"],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
