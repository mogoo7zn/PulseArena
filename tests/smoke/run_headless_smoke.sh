#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

resolve_godot() {
  if [[ -n "${GODOT_BIN:-}" ]]; then
    printf '%s\n' "${GODOT_BIN}"
    return 0
  fi
  command -v godot4 || command -v godot
}

python3 tests/smoke/static_project_check.py

if ! GODOT="$(resolve_godot)"; then
  echo "Godot 4 was not found. Set GODOT_BIN or add godot4/godot to PATH." >&2
  exit 127
fi
if [[ ! -x "${GODOT}" ]]; then
  echo "Godot binary is not executable: ${GODOT}" >&2
  exit 126
fi

mkdir -p test-results
"${GODOT}" --headless --path "${ROOT}" --script tests/smoke/debug_overlay_check.gd
"${GODOT}" --headless --path "${ROOT}" --script tests/run_tests.gd
"${GODOT}" --headless --path "${ROOT}" --script tests/smoke/map_build_check.gd
"${GODOT}" --headless --log-file "${ROOT}/test-results/headless-smoke.log" --path "${ROOT}" -- \
  --training --matches=1 --agents=4 --seed=1234 --seconds=5
