#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PROFILE="${PROFILE:-full_distributed_league}"
PLAN="${PLAN:-hybrid_tactical_v2_server_pilot_bc}"
SWANLAB_MODE="${SWANLAB_MODE:-offline}"
COLLECT_STAGE="${COLLECT_STAGE:-01_foundation_combat}"
COLLECT_MATCHES="${COLLECT_MATCHES:-8}"
COLLECT_SECONDS="${COLLECT_SECONDS:-30}"
COLLECT_SEED="${COLLECT_SEED:-51000}"
RUN_BC="${RUN_BC:-0}"
RUN_ID="${RUN_ID:-server_pilot_$(date -u +%Y%m%dT%H%M%SZ)}"
REPORT_DIR="training/runs/${RUN_ID}/reports"

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "GODOT_BIN must point to a Godot 4 headless/console executable." >&2
  exit 2
fi

mkdir -p "${REPORT_DIR}"

python training/server_agent/preflight.py \
  --godot "${GODOT_BIN}" \
  --output "${REPORT_DIR}/preflight.json" \
  --require-cuda
python tests/smoke/static_project_check.py
"${GODOT_BIN}" --headless --path . --script tests/run_tests.gd
"${GODOT_BIN}" --headless --path . --script tests/smoke/map_build_check.gd

python training/train_pipeline.py --profile "${PROFILE}" --plan "${PLAN}" --phase validate
python training/run_stage.py \
  --profile "${PROFILE}" \
  --stage "${COLLECT_STAGE}" \
  --matches "${COLLECT_MATCHES}" \
  --seconds "${COLLECT_SECONDS}" \
  --seed "${COLLECT_SEED}" \
  --agent-controller hybrid \
  --agent-model-id hybrid_tactical_v1 \
  --record-replay \
  --execute

python training/server_agent/audit_hybrid_replays.py \
  --replay-dir training/replays \
  --output "${REPORT_DIR}/raw_replay_audit.json" \
  --min-rows 1000
python training/server_agent/prepare_hybrid_replays.py \
  --input-dir training/replays \
  --output-dir training/replays_decision \
  --output "${REPORT_DIR}/decision_dataset.json"
python training/server_agent/audit_hybrid_replays.py \
  --replay-dir training/replays_decision \
  --output "${REPORT_DIR}/decision_replay_audit.json" \
  --min-rows 1000

if [[ "${RUN_BC}" == "1" ]]; then
  python training/train_pipeline.py --profile "${PROFILE}" --plan "${PLAN}" --phase bc --execute --swanlab-mode "${SWANLAB_MODE}"
else
  echo "Pilot collection and audit completed. Review ${REPORT_DIR}; rerun with RUN_BC=1 only after the agent prompt's gates pass."
fi

python training/train_pipeline.py --profile "${PROFILE}" --plan "${PLAN}" --phase validate
python training/train_pipeline.py --profile "${PROFILE}" --plan "${PLAN}" --phase collect --execute
python training/train_pipeline.py --profile "${PROFILE}" --plan "${PLAN}" --phase bc --execute --swanlab-mode "${SWANLAB_MODE}"
