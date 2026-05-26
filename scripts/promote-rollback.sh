#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

ALLOW_PLAYERDATA_ROLLBACK=0
JSON_OUTPUT=0

capture_player_critical_tree() {
  local live_service_dir="$1"
  local output_dir="$2"

  ensure_dir "${output_dir}"
  copy_tree_if_exists "${live_service_dir}/world/playerdata" "${output_dir}/world/playerdata"
  copy_tree_if_exists "${live_service_dir}/world/stats" "${output_dir}/world/stats"
  copy_tree_if_exists "${live_service_dir}/world/advancements" "${output_dir}/world/advancements"
}

restore_preserved_player_critical_tree() {
  local preserved_dir="$1"
  local live_service_dir="$2"

  if [[ -d "${preserved_dir}/world/playerdata" ]]; then
    replace_tree "${preserved_dir}/world/playerdata" "${live_service_dir}/world/playerdata"
  fi

  if [[ -d "${preserved_dir}/world/stats" ]]; then
    replace_tree "${preserved_dir}/world/stats" "${live_service_dir}/world/stats"
  fi

  if [[ -d "${preserved_dir}/world/advancements" ]]; then
    replace_tree "${preserved_dir}/world/advancements" "${live_service_dir}/world/advancements"
  fi
}

stage_data_root() {
  local stage_path="$1"

  if [[ -f "${stage_path}/restore-manifest.env" ]]; then
    # shellcheck disable=SC1090
    source "${stage_path}/restore-manifest.env"
    printf '%s\n' "${RESTORED_DATA_ROOT}"
  elif [[ -d "${stage_path}/data" ]]; then
    printf '%s\n' "${stage_path}/data"
  else
    fail "Unable to locate restored data under ${stage_path}"
  fi
}

stop_scope_containers() {
  local scope="$1"
  local service_name container_name

  while IFS= read -r service_name; do
    container_name="$(container_for_service "${service_name}")"
    log "Stopping ${service_name} (${container_name})"
    "${DOCKER_BIN}" stop "${container_name}" >/dev/null
  done < <(scope_services "${scope}")
}

start_scope_containers() {
  local scope="$1"
  local service_name container_name

  while IFS= read -r service_name; do
    container_name="$(container_for_service "${service_name}")"
    log "Starting ${service_name} (${container_name})"
    "${DOCKER_BIN}" start "${container_name}" >/dev/null
  done < <(scope_services "${scope}")
}

replace_live_data_from_stage() {
  local stage_data_root="$1"
  local scope="$2"
  local service_name source_dir target_dir

  while IFS= read -r service_name; do
    source_dir="${stage_data_root}/${service_name}"
    target_dir="$(data_dir_for_service "${service_name}")"
    [[ -d "${source_dir}" ]] || fail "Stage is missing restored data for ${service_name}: ${source_dir}"
    log "Replacing live data for ${service_name}"
    replace_tree "${source_dir}" "${target_dir}"
  done < <(scope_services "${scope}")
}

verify_preserved_playerdata() {
  local verify_root="$1"
  local scope="$2"
  local service_name live_dir

  while IFS= read -r service_name; do
    is_paper_service "${service_name}" || continue
    live_dir="$(data_dir_for_service "${service_name}")"

    write_hash_manifest "${verify_root}/${service_name}" "${RUN_DIR}/expected-${service_name}.tsv"
    capture_player_critical_tree "${live_dir}" "${RUN_DIR}/verify-${service_name}"
    write_hash_manifest "${RUN_DIR}/verify-${service_name}" "${RUN_DIR}/actual-${service_name}.tsv"

    if ! diff -u "${RUN_DIR}/expected-${service_name}.tsv" "${RUN_DIR}/actual-${service_name}.tsv" >/dev/null; then
      fail "Player-critical files changed during rollback for ${service_name}"
    fi
  done < <(scope_services "${scope}")
}

main() {
  local staged_restore scope preserve_root service_name live_dir data_root

  [[ $# -ge 1 ]] || fail "Usage: $0 <staged-restore> [service|full] [--allow-playerdata-rollback]"

  if [[ "${1:-}" == "--json" ]]; then
    JSON_OUTPUT=1
    shift
  fi

  staged_restore="$1"
  shift
  scope="full"

  if [[ $# -gt 0 && "$1" != "--allow-playerdata-rollback" ]]; then
    scope="$1"
    shift
  fi

  if [[ $# -gt 0 && "$1" == "--allow-playerdata-rollback" ]]; then
    ALLOW_PLAYERDATA_ROLLBACK=1
    shift
  fi

  [[ $# -eq 0 ]] || fail "Unexpected extra arguments: $*"

  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    exec 3>&1 1>&2
  fi

  init_logging promote-rollback
  load_target_env
  require_command "${DOCKER_BIN}"
  scope_services "${scope}" >/dev/null

  staged_restore="$(resolve_path "${staged_restore}" "${REPO_ROOT}")"
  [[ -d "${staged_restore}" ]] || fail "Staged restore not found: ${staged_restore}"

  data_root="$(stage_data_root "${staged_restore}")"
  [[ -d "${data_root}" ]] || fail "Restored data root not found: ${data_root}"

  make_run_dir promote-rollback
  preserve_root="${RUN_DIR}/preserved-live"

  log "Taking emergency local backup before rollback"
  bash "${TARGET_BACKUP_SCRIPT}"

  if [[ "${ALLOW_PLAYERDATA_ROLLBACK}" != "1" ]]; then
    while IFS= read -r service_name; do
      is_paper_service "${service_name}" || continue
      live_dir="$(data_dir_for_service "${service_name}")"
      log "Capturing live player-critical files for ${service_name}"
      capture_player_critical_tree "${live_dir}" "${preserve_root}/${service_name}"
    done < <(scope_services "${scope}")
  fi

  stop_scope_containers "${scope}"
  trap "start_scope_containers '${scope}' >/dev/null 2>&1 || true" EXIT

  replace_live_data_from_stage "${data_root}" "${scope}"

  if [[ "${ALLOW_PLAYERDATA_ROLLBACK}" != "1" ]]; then
    while IFS= read -r service_name; do
      is_paper_service "${service_name}" || continue
      live_dir="$(data_dir_for_service "${service_name}")"
      log "Restoring preserved player-critical files for ${service_name}"
      restore_preserved_player_critical_tree "${preserve_root}/${service_name}" "${live_dir}"
    done < <(scope_services "${scope}")
  fi

  start_scope_containers "${scope}"
  trap - EXIT

  if [[ "${ALLOW_PLAYERDATA_ROLLBACK}" != "1" ]]; then
    verify_preserved_playerdata "${preserve_root}" "${scope}"
  fi

  log "Rollback promotion completed"
  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    python3 - "${staged_restore}" "${scope}" "${ALLOW_PLAYERDATA_ROLLBACK}" <<'PY' >&3
import json, sys
print(json.dumps({
    "status": "success",
    "stage_path": sys.argv[1],
    "scope": sys.argv[2],
    "allow_playerdata_rollback": sys.argv[3] == "1",
}, sort_keys=True))
PY
  fi
}

main "$@"
