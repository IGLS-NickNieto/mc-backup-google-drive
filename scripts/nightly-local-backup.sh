#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

main() {
  init_logging nightly-local-backup
  load_target_env

  [[ -x "${TARGET_BACKUP_SCRIPT}" ]] || fail "Target backup script is not executable: ${TARGET_BACKUP_SCRIPT}"

  log "Running local archive backup through ${TARGET_BACKUP_SCRIPT}"
  bash "${TARGET_BACKUP_SCRIPT}"
  log "Local archive backup completed"
}

main "$@"

