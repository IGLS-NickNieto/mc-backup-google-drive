#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

JSON_OUTPUT=0

if [[ "${1:-}" == "--json" ]]; then
  JSON_OUTPUT=1
  shift
fi

main() {
  local snapshots_output

  load_repo_env
  load_target_env

  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
  [[ -n "${RESTIC_REPOSITORY}" ]] || fail "RESTIC_REPOSITORY must be set in .env"

  if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    RESTIC_PASSWORD_FILE="$(resolve_path "${RESTIC_PASSWORD_FILE}" "${REPO_ROOT}")"
    export RESTIC_PASSWORD_FILE
  fi

  RESTIC_CACHE_DIR="$(resolve_path "${RESTIC_CACHE_DIR:-runtime/restic-cache}" "${REPO_ROOT}")"
  export RESTIC_REPOSITORY RESTIC_CACHE_DIR

  require_command "${RESTIC_BIN}"
  if [[ "${RESTIC_REPOSITORY}" == rclone:* ]]; then
    require_command "${RCLONE_BIN}"
  fi

  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    snapshots_output="$("${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" snapshots --json "$@")"
    python - "${snapshots_output}" <<'PY'
import json, sys
snapshots = json.loads(sys.argv[1])
print(json.dumps({"status": "success", "snapshot_count": len(snapshots), "snapshots": snapshots}, sort_keys=True))
PY
  else
    "${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" snapshots "$@"
  fi
}

main "$@"
