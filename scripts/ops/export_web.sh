#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_PATH="${OUTPUT_PATH:-${ROOT}/build/web/index.html}"

resolve_godot() {
  if [[ -n "${GODOT_BIN:-}" ]]; then
    printf '%s\n' "${GODOT_BIN}"
    return 0
  fi
  command -v godot4 || command -v godot
}

if ! GODOT="$(resolve_godot)"; then
  echo "Godot 4 was not found. Set GODOT_BIN or add godot4/godot to PATH." >&2
  exit 127
fi
if [[ ! -x "${GODOT}" ]]; then
  echo "Godot binary is not executable: ${GODOT}" >&2
  exit 126
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"
"${GODOT}" --headless --path "${ROOT}" --editor --quit
"${GODOT}" --headless --path "${ROOT}" --export-release "Web" "${OUTPUT_PATH}"
if [[ ! -f "${OUTPUT_PATH}" ]]; then
  echo "Web export did not produce HTML: ${OUTPUT_PATH}" >&2
  exit 1
fi
printf 'Web release written to %s\n' "${OUTPUT_PATH}"
