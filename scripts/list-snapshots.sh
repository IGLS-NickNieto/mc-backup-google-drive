#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

main() {
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

  "${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" snapshots "$@"
}

main "$@"
