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

# Prime the project cache on a fresh clone. Without this, headless scripts
# that reference `class_name` declarations fail to parse because
# `.godot/global_script_class_cache.cfg` and the UID cache do not yet exist.
# `--import` scans the project, builds the class index, and exits. The follow-up
# `--quit-after 1` (Godot 4.4+) is a no-op on older versions and protects us if
# the editor would otherwise keep running.
"${GODOT}" --headless --path "${ROOT}" --import || true

"${GODOT}" --headless --path "${ROOT}" --script tests/smoke/debug_overlay_check.gd
"${GODOT}" --headless --path "${ROOT}" --script tests/run_tests.gd
"${GODOT}" --headless --path "${ROOT}" --script tests/smoke/map_build_check.gd
"${GODOT}" --headless --log-file "${ROOT}/test-results/headless-smoke.log" --path "${ROOT}" -- \
  --training --matches=1 --agents=4 --seed=1234 --seconds=5
