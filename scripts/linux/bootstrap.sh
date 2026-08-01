#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-${ROOT}/.venv}"
WITH_TRAINING=0

usage() {
  cat <<'EOF'
Usage: bash scripts/linux/bootstrap.sh [--with-training]

Creates a local virtual environment and installs the Python dependencies.
For CUDA PyTorch, set TORCH_INDEX_URL to the wheel index selected for the
installed NVIDIA driver before passing --with-training.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-training) WITH_TRAINING=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "Python 3.10+ is required. On Ubuntu: sudo apt install python3 python3-venv" >&2
  exit 127
fi

"${PYTHON_BIN}" - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10+ is required")
PY

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

PIP=("${VENV_DIR}/bin/python" -m pip)
"${PIP[@]}" install --upgrade pip
"${PIP[@]}" install -r "${ROOT}/requirements.txt"

if [[ "${WITH_TRAINING}" == "1" ]]; then
  if [[ -n "${TORCH_INDEX_URL:-}" ]]; then
    "${PIP[@]}" install --index-url "${TORCH_INDEX_URL}" 'torch>=2.4,<3'
  else
    "${PIP[@]}" install -r "${ROOT}/requirements-training.txt"
  fi
fi

echo "Python environment ready: ${VENV_DIR}"
echo "Set GODOT_BIN to a Godot 4 binary, or install godot4/godot on PATH."
