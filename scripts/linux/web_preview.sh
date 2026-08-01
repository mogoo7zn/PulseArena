#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREVIEW_DIRECTORY="${PREVIEW_DIRECTORY:-${ROOT}/build/web}"
PREVIEW_HOST="${PREVIEW_HOST:-127.0.0.1}"
PREVIEW_PORT="${PREVIEW_PORT:-8080}"
PREVIEW_STATE_DIR="${PREVIEW_STATE_DIR:-${ROOT}/test-results/web-preview}"
PID_FILE="${PREVIEW_STATE_DIR}/server.pid"
LOG_FILE="${PREVIEW_STATE_DIR}/server.log"

owns_preview_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/${pid}/cmdline" ]] \
    && tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq "web_preview_server.py"
}

is_loopback_host() {
  [[ "${PREVIEW_HOST}" == "127.0.0.1" || "${PREVIEW_HOST}" == "::1" ]]
}

preview_url() {
  if [[ "${PREVIEW_HOST}" == "::1" ]]; then
    printf 'http://[%s]:%s/\n' "${PREVIEW_HOST}" "${PREVIEW_PORT}"
  else
    printf 'http://%s:%s/\n' "${PREVIEW_HOST}" "${PREVIEW_PORT}"
  fi
}

health_check() {
  local timeout_seconds="${1:-1}"
  python3 -c '
import sys
from urllib.request import ProxyHandler, build_opener

host, port, timeout = sys.argv[1:]
address = f"[{host}]" if ":" in host else host
opener = build_opener(ProxyHandler({}))
with opener.open(f"http://{address}:{port}/", timeout=float(timeout)) as response:
    if response.status != 200:
        raise SystemExit(f"unexpected HTTP status: {response.status}")
' "${PREVIEW_HOST}" "${PREVIEW_PORT}" "${timeout_seconds}" >/dev/null
}

recorded_preview_pid() {
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "Preview server is not running (no PID file: ${PID_FILE})." >&2
    return 1
  fi

  local pid
  pid="$(<"${PID_FILE}")"
  if ! owns_preview_pid "${pid}"; then
    echo "Recorded PID ${pid:-<empty>} does not belong to the preview server." >&2
    return 1
  fi
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "Recorded preview server PID ${pid} is not running." >&2
    return 1
  fi
  printf '%s\n' "${pid}"
}

still_owns_recorded_pid() {
  local expected_pid="$1"
  [[ -f "${PID_FILE}" ]] && [[ "$(<"${PID_FILE}")" == "${expected_pid}" ]] \
    && owns_preview_pid "${expected_pid}" && kill -0 "${expected_pid}" 2>/dev/null
}

clear_state_for_pid() {
  local expected_pid="$1"
  # The PID record is the ownership token for both state files.  Never remove
  # replacement state installed after this invocation started.  A matching
  # token may be cleared only after its process has exited, or while it is
  # still confirmed to be this preview process during failure cleanup.
  if [[ -f "${PID_FILE}" ]] && [[ "$(<"${PID_FILE}")" == "${expected_pid}" ]]; then
    if ! kill -0 "${expected_pid}" 2>/dev/null \
      || { owns_preview_pid "${expected_pid}" && kill -0 "${expected_pid}" 2>/dev/null; }; then
      rm -f "${PID_FILE}" "${LOG_FILE}"
    fi
  fi
}

start() {
  if ! is_loopback_host; then
    echo "Preview host must be loopback-only (127.0.0.1 or ::1): ${PREVIEW_HOST}" >&2
    return 1
  fi
  if [[ ! -f "${PREVIEW_DIRECTORY}/index.html" ]]; then
    echo "Web export index.html does not exist: ${PREVIEW_DIRECTORY}/index.html" >&2
    return 1
  fi

  mkdir -p "${PREVIEW_STATE_DIR}"
  if [[ -e "${PID_FILE}" ]]; then
    local existing_pid
    existing_pid="$(<"${PID_FILE}")"
    if owns_preview_pid "${existing_pid}" && kill -0 "${existing_pid}" 2>/dev/null; then
      echo "Preview server is already running with PID ${existing_pid}." >&2
    else
      echo "Recorded PID ${existing_pid:-<empty>} does not belong to the preview server." >&2
    fi
    return 1
  fi

  nohup python3 "${ROOT}/scripts/linux/web_preview_server.py" \
    --directory "${PREVIEW_DIRECTORY}" --host "${PREVIEW_HOST}" --port "${PREVIEW_PORT}" \
    >"${LOG_FILE}" 2>&1 &
  local pid="$!"
  printf '%s\n' "${pid}" > "${PID_FILE}"

  local deadline_millis=$(( $(date +%s%3N) + 5000 ))
  while :; do
    local remaining_millis=$(( deadline_millis - $(date +%s%3N) ))
    (( remaining_millis > 0 )) || break
    local health_timeout
    health_timeout="$(printf '%d.%03d' $((remaining_millis / 1000)) $((remaining_millis % 1000)))"
    # Re-check the state ownership directly before probing: another process
    # could replace the PID record while the child is starting.
    if still_owns_recorded_pid "${pid}" && health_check "${health_timeout}" \
      && still_owns_recorded_pid "${pid}"; then
      printf 'Web preview running at %s (PID %s)\n' "$(preview_url)" "${pid}"
      return 0
    fi
    remaining_millis=$(( deadline_millis - $(date +%s%3N) ))
    (( remaining_millis > 0 )) || break
    if (( remaining_millis > 100 )); then
      sleep 0.1
    else
      sleep "$(printf '0.%03d' "${remaining_millis}")"
    fi
  done

  echo "Web preview failed its loopback health check; see ${LOG_FILE}." >&2
  # Renew ownership immediately before signalling or clearing state.
  if still_owns_recorded_pid "${pid}"; then
    kill -TERM "${pid}" 2>/dev/null || true
  fi
  clear_state_for_pid "${pid}"
  return 1
}

status() {
  local pid
  if ! pid="$(recorded_preview_pid)"; then
    return 1
  fi
  # Renew ownership immediately before the network probe.
  if ! still_owns_recorded_pid "${pid}" || ! health_check || ! still_owns_recorded_pid "${pid}"; then
    echo "Preview server PID ${pid} failed its loopback health check." >&2
    return 1
  fi
  printf 'Web preview running at %s (PID %s)\n' "$(preview_url)" "${pid}"
}

stop() {
  local pid
  if ! pid="$(recorded_preview_pid)"; then
    return 1
  fi

  # Renew ownership immediately before the signal and every liveness probe.
  if ! still_owns_recorded_pid "${pid}"; then
    echo "Recorded PID ${pid} no longer belongs to this preview invocation." >&2
    return 1
  fi
  kill -TERM "${pid}"
  local deadline_millis=$(( $(date +%s%3N) + 5000 ))
  while :; do
    (( $(date +%s%3N) < deadline_millis )) || break
    if ! kill -0 "${pid}" 2>/dev/null; then
      # The original process is gone.  A replacement PID record, if any, is
      # deliberately preserved.
      clear_state_for_pid "${pid}"
      printf 'Web preview stopped (PID %s).\n' "${pid}"
      return 0
    fi
    if ! still_owns_recorded_pid "${pid}"; then
      echo "Preview server PID ${pid} is still running, but its state was replaced; preserving replacement state." >&2
      return 1
    fi
    sleep 0.1
  done
  echo "Preview server PID ${pid} did not stop within five seconds." >&2
  return 1
}

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 {start|status|stop}" >&2
  exit 2
fi

case "$1" in
  start) start ;;
  status) status ;;
  stop) stop ;;
  *)
    echo "Usage: $0 {start|status|stop}" >&2
    exit 2
    ;;
esac
