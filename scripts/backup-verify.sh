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

latest_local_archive() {
  find "${TARGET_BACKUPS_DIR}/daily" -maxdepth 1 -type f -name 'minecraft-*.tar.gz' | LC_ALL=C sort | tail -n1
}

verify_stage_config_assets() {
  local stage_dir="$1"
  local config_file="${stage_dir}/config/proxy/velocity.toml"
  local geyser_config="${stage_dir}/config/proxy/plugins/Geyser-Velocity/config.yml"
  local forwarding_secret="${stage_dir}/secrets/forwarding.secret"

  [[ -f "${config_file}" ]] || fail "Restored stage is missing Velocity config: ${config_file}"
  [[ -f "${geyser_config}" ]] || fail "Restored stage is missing Geyser config: ${geyser_config}"
  [[ -f "${forwarding_secret}" ]] || fail "Restored stage is missing forwarding secret: ${forwarding_secret}"
}

main() {
  local archive_path staged_restore config_stage offsite_config_stage=""

  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    exec 3>&1 1>&2
  fi

  init_logging backup-verify
  load_repo_env
  load_target_env

  archive_path="$(latest_local_archive)"
  [[ -n "${archive_path}" ]] || fail "No local daily archive backups found under ${TARGET_BACKUPS_DIR}/daily"

  log "Verifying latest local archive ${archive_path}"
  staged_restore="$("${SCRIPT_DIR}/restore-to-staging.sh" "${archive_path}" "${VERIFY_SCOPE:-survival}" | tail -n1)"
  [[ -d "${staged_restore}/data/${VERIFY_SCOPE:-survival}" ]] || fail "Staged restore is missing ${VERIFY_SCOPE:-survival} data"

  if [[ "${VERIFY_CONFIG_ASSETS:-1}" == "1" ]]; then
    log "Verifying full local archive restore for config assets"
    config_stage="$("${SCRIPT_DIR}/restore-to-staging.sh" "${archive_path}" full | tail -n1)"
    verify_stage_config_assets "${config_stage}"
  fi

  if [[ "${VERIFY_OFFSITE_SNAPSHOT:-0}" == "1" ]]; then
    log "Verifying latest offsite snapshot"
    staged_restore="$("${SCRIPT_DIR}/restore-to-staging.sh" latest "${VERIFY_SCOPE:-survival}" | tail -n1)"
    [[ -d "${staged_restore}/data/${VERIFY_SCOPE:-survival}" ]] || fail "Offsite restore is missing ${VERIFY_SCOPE:-survival} data"
    if [[ "${VERIFY_CONFIG_ASSETS:-1}" == "1" ]]; then
      log "Verifying full offsite restore for config assets"
      offsite_config_stage="$("${SCRIPT_DIR}/restore-to-staging.sh" latest full | tail -n1)"
      verify_stage_config_assets "${offsite_config_stage}"
    fi
  fi

  log "Backup verification completed"
  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    python3 - "${archive_path}" "${staged_restore}" "${VERIFY_OFFSITE_SNAPSHOT:-0}" "${VERIFY_CONFIG_ASSETS:-1}" "${offsite_config_stage}" <<'PY' >&3
import json, sys
print(json.dumps({
    "status": "success",
    "archive_path": sys.argv[1],
    "last_staged_restore": sys.argv[2],
    "verified_offsite_snapshot": sys.argv[3] == "1",
    "verified_config_assets": sys.argv[4] == "1",
    "last_offsite_config_stage": sys.argv[5],
}, sort_keys=True))
PY
  fi
}

main "$@"
