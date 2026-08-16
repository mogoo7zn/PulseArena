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
REPORT_DIR="training/artifacts/runs/${RUN_ID}/reports"

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "GODOT_BIN must point to a Godot 4 headless/console executable." >&2
  exit 2
fi

mkdir -p "${REPORT_DIR}"

python training.server.preflight \
  --godot "${GODOT_BIN}" \
  --output "${REPORT_DIR}/preflight.json" \
  --require-cuda
python tests/smoke/static_project_check.py
"${GODOT_BIN}" --headless --path . --script tests/run_tests.gd
"${GODOT_BIN}" --headless --path . --script tests/smoke/map_build_check.gd

python training.pipelines.train_pipeline --profile "${PROFILE}" --plan "${PLAN}" --phase validate
python training.pipelines.run_stage \
  --profile "${PROFILE}" \
  --stage "${COLLECT_STAGE}" \
  --matches "${COLLECT_MATCHES}" \
  --seconds "${COLLECT_SECONDS}" \
  --seed "${COLLECT_SEED}" \
  --agent-controller hybrid \
  --agent-model-id hybrid_tactical_v1 \
  --record-replay \
  --execute

python training.server.audit_hybrid_replays \
  --replay-dir training/data/replays \
  --output "${REPORT_DIR}/raw_replay_audit.json" \
  --min-rows 1000
python training.server.prepare_hybrid_replays \
  --input-dir training/data/replays \
  --output-dir training/data/replays_decision \
  --output "${REPORT_DIR}/decision_dataset.json"
python training.server.audit_hybrid_replays \
  --replay-dir training/data/replays_decision \
  --output "${REPORT_DIR}/decision_replay_audit.json" \
  --min-rows 1000

if [[ "${RUN_BC}" == "1" ]]; then
  python training.pipelines.train_pipeline --profile "${PROFILE}" --plan "${PLAN}" --phase bc --execute --swanlab-mode "${SWANLAB_MODE}"
else
  echo "Pilot collection and audit completed. Review ${REPORT_DIR}; rerun with RUN_BC=1 only after the agent prompt's gates pass."
fi

python training.pipelines.train_pipeline --profile "${PROFILE}" --plan "${PLAN}" --phase validate
python training.pipelines.train_pipeline --profile "${PROFILE}" --plan "${PLAN}" --phase collect --execute
python training.pipelines.train_pipeline --profile "${PROFILE}" --plan "${PLAN}" --phase bc --execute --swanlab-mode "${SWANLAB_MODE}"
