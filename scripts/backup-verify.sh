#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

latest_local_archive() {
  find "${TARGET_BACKUPS_DIR}/daily" -maxdepth 1 -type f -name 'minecraft-*.tar.gz' | LC_ALL=C sort | tail -n1
}

main() {
  local archive_path staged_restore

  init_logging backup-verify
  load_repo_env
  load_target_env

  archive_path="$(latest_local_archive)"
  [[ -n "${archive_path}" ]] || fail "No local daily archive backups found under ${TARGET_BACKUPS_DIR}/daily"

  log "Verifying latest local archive ${archive_path}"
  staged_restore="$("${SCRIPT_DIR}/restore-to-staging.sh" "${archive_path}" "${VERIFY_SCOPE:-survival}" | tail -n1)"
  [[ -d "${staged_restore}/data/${VERIFY_SCOPE:-survival}" ]] || fail "Staged restore is missing ${VERIFY_SCOPE:-survival} data"

  if [[ "${VERIFY_OFFSITE_SNAPSHOT:-0}" == "1" ]]; then
    log "Verifying latest offsite snapshot"
    staged_restore="$("${SCRIPT_DIR}/restore-to-staging.sh" latest "${VERIFY_SCOPE:-survival}" | tail -n1)"
    [[ -d "${staged_restore}/data/${VERIFY_SCOPE:-survival}" ]] || fail "Offsite restore is missing ${VERIFY_SCOPE:-survival} data"
  fi

  log "Backup verification completed"
}

main "$@"

