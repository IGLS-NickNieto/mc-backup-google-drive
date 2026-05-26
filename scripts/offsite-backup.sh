#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/consistent-snapshot.sh"

declare -a BACKUP_SOURCES=()
declare -a EXTRA_BACKUP_PATHS=()
JSON_OUTPUT=0

if [[ "${1:-}" == "--json" ]]; then
  JSON_OUTPUT=1
  shift
fi

setup_restic_env() {
  load_repo_env
  load_target_env

  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
  [[ -n "${RESTIC_REPOSITORY}" ]] || fail "RESTIC_REPOSITORY must be set in .env"

  if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    RESTIC_PASSWORD_FILE="$(resolve_path "${RESTIC_PASSWORD_FILE}" "${REPO_ROOT}")"
    [[ -f "${RESTIC_PASSWORD_FILE}" ]] || fail "RESTIC_PASSWORD_FILE not found: ${RESTIC_PASSWORD_FILE}"
    export RESTIC_PASSWORD_FILE
  elif [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    fail "Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD before running offsite backups"
  fi

  RESTIC_CACHE_DIR="$(resolve_path "${RESTIC_CACHE_DIR:-runtime/restic-cache}" "${REPO_ROOT}")"
  export RESTIC_REPOSITORY RESTIC_CACHE_DIR

  ensure_dir "${RESTIC_CACHE_DIR}"

  require_command "${RESTIC_BIN}"
  if [[ "${RESTIC_REPOSITORY}" == rclone:* ]]; then
    require_command "${RCLONE_BIN}"
  fi

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    RCLONE_CONFIG="$(resolve_path "${RCLONE_CONFIG}" "${REPO_ROOT}")"
    export RCLONE_CONFIG
  fi
}

lock_or_fail() {
  local lock_dir

  lock_dir="$(resolve_path "runtime/locks/offsite-backup.lock" "${REPO_ROOT}")"
  ensure_dir "$(dirname "${lock_dir}")"
  if ! mkdir "${lock_dir}" 2>/dev/null; then
    fail "Another offsite backup appears to be running: ${lock_dir}"
  fi

  LOCK_DIR_PATH="${lock_dir}"
}

unlock() {
  if [[ -n "${LOCK_DIR_PATH:-}" && -d "${LOCK_DIR_PATH}" ]]; then
    rmdir "${LOCK_DIR_PATH}" 2>/dev/null || true
  fi
}

build_metadata() {
  local service_name service_dir playerdata_dir stats_dir advancements_dir
  local inventory_root inventory_summary included_paths_file
  local playerdata_count stats_count advancements_count

  METADATA_DIR="${RUN_DIR}/metadata"
  HOOK_OUTPUT_DIR="${RUN_DIR}/hook-output"
  inventory_root="${METADATA_DIR}/inventory"
  included_paths_file="${METADATA_DIR}/included-paths.txt"
  inventory_summary="${METADATA_DIR}/inventory-summary.env"

  ensure_dir "${METADATA_DIR}"
  ensure_dir "${inventory_root}"
  ensure_dir "${HOOK_OUTPUT_DIR}"

  cat > "${METADATA_DIR}/backup-target.env" <<EOF
BACKUP_CREATED_AT=${RUN_TIMESTAMP}
STACK_NAME=${STACK_NAME}
TARGET_STACK_ROOT=${TARGET_STACK_ROOT}
TARGET_DATA_DIR=${TARGET_DATA_DIR}
TARGET_BACKUPS_DIR=${TARGET_BACKUPS_DIR}
TARGET_ACCESS_DIR=${TARGET_ACCESS_DIR}
TARGET_INVITE_PLAYERS_FILE=${TARGET_INVITE_PLAYERS_FILE}
TARGET_PROXY_CONTAINER=${TARGET_PROXY_CONTAINER}
TARGET_LOBBY_CONTAINER=${TARGET_LOBBY_CONTAINER}
TARGET_SURVIVAL_CONTAINER=${TARGET_SURVIVAL_CONTAINER}
TARGET_CREATIVE_CONTAINER=${TARGET_CREATIVE_CONTAINER}
EOF

  : > "${inventory_summary}"
  : > "${included_paths_file}"

  while IFS= read -r service_name; do
    service_dir="$(data_dir_for_service "${service_name}")"
    playerdata_dir="${service_dir}/world/playerdata"
    stats_dir="${service_dir}/world/stats"
    advancements_dir="${service_dir}/world/advancements"

    write_hash_manifest "${playerdata_dir}" "${inventory_root}/${service_name}-playerdata.tsv"
    write_hash_manifest "${stats_dir}" "${inventory_root}/${service_name}-stats.tsv"
    write_hash_manifest "${advancements_dir}" "${inventory_root}/${service_name}-advancements.tsv"

    playerdata_count="$(count_files "${playerdata_dir}")"
    stats_count="$(count_files "${stats_dir}")"
    advancements_count="$(count_files "${advancements_dir}")"

    {
      printf '%s_PLAYERDATA_COUNT=%s\n' "$(printf '%s' "${service_name}" | tr '[:lower:]' '[:upper:]')" "${playerdata_count}"
      printf '%s_STATS_COUNT=%s\n' "$(printf '%s' "${service_name}" | tr '[:lower:]' '[:upper:]')" "${stats_count}"
      printf '%s_ADVANCEMENTS_COUNT=%s\n' "$(printf '%s' "${service_name}" | tr '[:lower:]' '[:upper:]')" "${advancements_count}"
    } >> "${inventory_summary}"
  done < <(paper_services)

  if [[ -f "${TARGET_INVITE_PLAYERS_FILE}" ]]; then
    ensure_dir "${METADATA_DIR}/ops/access"
    cp "${TARGET_INVITE_PLAYERS_FILE}" "${METADATA_DIR}/ops/access/invite-players.txt"
  fi

  python - "${TARGET_STACK_ROOT}" "${TARGET_CONFIG_DIR}" "${TARGET_SECRETS_DIR}" "${METADATA_DIR}" <<'PY'
import json
import sys
from pathlib import Path

stack_root = Path(sys.argv[1])
config_dir = Path(sys.argv[2])
secrets_dir = Path(sys.argv[3])
metadata_dir = Path(sys.argv[4])

config_assets = {
    "velocity_config": str(config_dir / "proxy/velocity.toml"),
    "geyser_config": str(config_dir / "proxy/plugins/Geyser-Velocity/config.yml"),
    "floodgate_key_primary": str(config_dir / "proxy/plugins/Geyser-Velocity/key.pem"),
    "floodgate_key_runtime": str(stack_root / "data/proxy/plugins/floodgate/key.pem"),
    "forwarding_secret": str(secrets_dir / "forwarding.secret"),
    "proxy_plugin_manifest": str(stack_root / "plugins/proxy-plugins.txt"),
}

payload = {
    "config_assets": {name: {"path": value, "exists": Path(value).exists()} for name, value in config_assets.items()}
}
(metadata_dir / "config-assets.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

load_extra_paths() {
  local config_file resolved_path line

  config_file="${REPO_ROOT}/config/extra-paths.txt"
  EXTRA_BACKUP_PATHS=()

  while IFS= read -r line; do
    resolved_path="$(resolve_path "${line}" "${TARGET_STACK_ROOT}")"
    if [[ -e "${resolved_path}" ]]; then
      EXTRA_BACKUP_PATHS+=("${resolved_path}")
    else
      log "Skipping missing extra backup path: ${resolved_path}"
    fi
  done < <(read_config_lines "${config_file}")

  if ((${#EXTRA_BACKUP_PATHS[@]} > 0)); then
    printf '%s\n' "${EXTRA_BACKUP_PATHS[@]}" > "${METADATA_DIR}/extra-paths.txt"
  else
    : > "${METADATA_DIR}/extra-paths.txt"
  fi
}

run_pre_backup_hooks() {
  local hook_file hook_name ran_hook=0

  export BACKUP_HOOK_OUTPUT_DIR="${HOOK_OUTPUT_DIR}"
  export BACKUP_METADATA_DIR="${METADATA_DIR}"
  export TARGET_STACK_ROOT TARGET_DATA_DIR TARGET_BACKUPS_DIR TARGET_ACCESS_DIR

  : > "${METADATA_DIR}/hook-runs.txt"

  for hook_file in "${REPO_ROOT}"/hooks/pre-backup.d/*.sh; do
    [[ -f "${hook_file}" ]] || continue
    hook_name="$(basename "${hook_file}")"
    log "Running pre-backup hook ${hook_name}"
    bash "${hook_file}"
    printf '%s\n' "${hook_name}" >> "${METADATA_DIR}/hook-runs.txt"
    ran_hook=1
  done

  if [[ "${ran_hook}" == "0" ]]; then
    : > "${METADATA_DIR}/hook-runs.txt"
  fi
}

build_backup_sources() {
  BACKUP_SOURCES=(
    "${TARGET_PROXY_DATA_DIR}"
    "${TARGET_LOBBY_DATA_DIR}"
    "${TARGET_SURVIVAL_DATA_DIR}"
    "${TARGET_CREATIVE_DATA_DIR}"
    "${TARGET_ACCESS_DIR}"
    "${TARGET_CONFIG_DIR}"
    "${TARGET_SECRETS_DIR}"
    "${METADATA_DIR}"
  )

  if find "${HOOK_OUTPUT_DIR}" -mindepth 1 -print -quit | grep -q .; then
    BACKUP_SOURCES+=("${HOOK_OUTPUT_DIR}")
  fi

  if ((${#EXTRA_BACKUP_PATHS[@]} > 0)); then
    BACKUP_SOURCES+=("${EXTRA_BACKUP_PATHS[@]}")
  fi

  printf '%s\n' "${BACKUP_SOURCES[@]}" > "${METADATA_DIR}/included-paths.txt"
}

run_restic_backup() {
  local restic_output_file snapshot_id tags_raw
  local -a restic_cmd
  local -a restic_tags=()

  restic_output_file="${RUN_DIR}/restic-backup-output.log"
  tags_raw="${OFFSITE_BACKUP_TAGS:-minecraft offsite}"

  for tag_value in ${tags_raw}; do
    restic_tags+=("--tag" "${tag_value}")
  done
  restic_tags+=("--tag" "stack:${STACK_NAME}")

  restic_cmd=(
    "${RESTIC_BIN}"
    --cache-dir "${RESTIC_CACHE_DIR}"
    backup
    "${restic_tags[@]}"
    "${BACKUP_SOURCES[@]}"
  )

  log "Starting restic backup to ${RESTIC_REPOSITORY}"
  "${restic_cmd[@]}" | tee "${restic_output_file}"

  snapshot_id="$(sed -n 's/.*snapshot \([A-Za-z0-9]\{8,\}\) saved.*/\1/p' "${restic_output_file}" | tail -n1)"
  [[ -n "${snapshot_id}" ]] || fail "Unable to determine restic snapshot ID from backup output"

  SNAPSHOT_ID="${snapshot_id}"
  export SNAPSHOT_ID

  log "Applying restic retention policy"
  "${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" forget \
    --keep-hourly "${OFFSITE_KEEP_HOURLY:-48}" \
    --keep-daily "${OFFSITE_KEEP_DAILY:-14}" \
    --keep-weekly "${OFFSITE_KEEP_WEEKLY:-8}" \
    --keep-monthly "${OFFSITE_KEEP_MONTHLY:-6}" \
    --prune
}

write_run_manifest() {
  local manifest_file total_inventory_files

  total_inventory_files="$(
    awk -F= '/_COUNT=/{sum += $2} END {print sum+0}' "${METADATA_DIR}/inventory-summary.env"
  )"
  manifest_file="${MANIFEST_DIR}/offsite-${RUN_TIMESTAMP}.env"

  cat > "${manifest_file}" <<EOF
STATUS=success
SNAPSHOT_ID=${SNAPSHOT_ID}
CREATED_AT=${RUN_TIMESTAMP}
STACK_NAME=${STACK_NAME}
RESTIC_REPOSITORY=${RESTIC_REPOSITORY}
INCLUDED_PATHS_FILE=${METADATA_DIR}/included-paths.txt
TOTAL_INVENTORY_FILES=${total_inventory_files}
LOG_FILE=${LOG_FILE}
EOF

  cat "${METADATA_DIR}/inventory-summary.env" >> "${manifest_file}"
  printf 'RETENTION_CLASS=offsite\n' >> "${manifest_file}"
  printf 'CONFIG_ASSETS_FILE=%s\n' "${METADATA_DIR}/config-assets.json" >> "${manifest_file}"

  log "Wrote run manifest to ${manifest_file}"
}

perform_backup() {
  build_metadata
  load_extra_paths
  run_pre_backup_hooks
  build_backup_sources
  run_restic_backup
}

main() {
  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    exec 3>&1 1>&2
  fi

  init_logging offsite-backup
  setup_restic_env
  lock_or_fail
  make_run_dir offsite

  trap 'unlock; rm -rf "${RUN_DIR:-}"' EXIT

  run_with_consistent_snapshot perform_backup
  write_run_manifest

  log "Offsite backup completed with snapshot ${SNAPSHOT_ID}"
  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    python - "${SNAPSHOT_ID}" "${RUN_TIMESTAMP}" "${LOG_FILE}" "${RUN_DIR}" <<'PY' >&3
import json, sys
print(json.dumps({
    "status": "success",
    "snapshot_id": sys.argv[1],
    "created_at": sys.argv[2],
    "log_file": sys.argv[3],
    "run_dir": sys.argv[4],
}, sort_keys=True))
PY
  fi
}

main "$@"
