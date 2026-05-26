#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

JSON_OUTPUT=0

while [[ "${1:-}" == "--json" ]]; do
  JSON_OUTPUT=1
  shift
done

resolve_source_path() {
  local source_ref="$1"

  if [[ -f "${source_ref}" ]]; then
    printf '%s\n' "$(cd "$(dirname "${source_ref}")" && pwd)/$(basename "${source_ref}")"
  else
    printf '%s\n' "${source_ref}"
  fi
}

restore_local_archive() {
  local archive_path="$1"
  local scope="$2"

  [[ -f "${archive_path}" ]] || fail "Archive not found: ${archive_path}"

  if [[ "${scope}" == "full" ]]; then
    tar -C "${STAGE_DIR}" -xzf "${archive_path}"
  else
    tar -C "${STAGE_DIR}" -xzf "${archive_path}" "data/${scope}"
  fi
}

setup_restic_restore_env() {
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
  [[ -n "${RESTIC_REPOSITORY}" ]] || fail "RESTIC_REPOSITORY must be set to restore offsite snapshots"

  if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    RESTIC_PASSWORD_FILE="$(resolve_path "${RESTIC_PASSWORD_FILE}" "${REPO_ROOT}")"
    [[ -f "${RESTIC_PASSWORD_FILE}" ]] || fail "RESTIC_PASSWORD_FILE not found: ${RESTIC_PASSWORD_FILE}"
    export RESTIC_PASSWORD_FILE
  elif [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    fail "Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD before restoring offsite snapshots"
  fi

  RESTIC_CACHE_DIR="$(resolve_path "${RESTIC_CACHE_DIR:-runtime/restic-cache}" "${REPO_ROOT}")"
  export RESTIC_REPOSITORY RESTIC_CACHE_DIR
}

restore_restic_snapshot() {
  local snapshot_ref="$1"
  local scope="$2"
  local raw_restore_dir raw_data_root
  local include_path

  setup_restic_restore_env
  require_command "${RESTIC_BIN}"

  raw_restore_dir="${STAGE_DIR}/raw"
  ensure_dir "${raw_restore_dir}"

  if [[ "${scope}" == "full" ]]; then
    while IFS= read -r include_path; do
      "${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" restore "${snapshot_ref}" \
        --target "${raw_restore_dir}" \
        --include "${include_path}"
    done < <(full_restore_paths)
  else
    include_path="${TARGET_DATA_DIR}/${scope}"
    "${RESTIC_BIN}" --cache-dir "${RESTIC_CACHE_DIR}" restore "${snapshot_ref}" \
      --target "${raw_restore_dir}" \
      --include "${include_path}"
  fi

  ensure_dir "${STAGE_DIR}/data"
  if [[ "${scope}" == "full" ]]; then
    raw_data_root="${raw_restore_dir}/${TARGET_DATA_DIR#/}"
    [[ -d "${raw_data_root}" ]] || fail "Restored snapshot did not contain ${TARGET_DATA_DIR}"
    copy_tree_if_exists "${raw_data_root}" "${STAGE_DIR}/data"
    copy_tree_if_exists "${raw_restore_dir}/${TARGET_ACCESS_DIR#/}" "${STAGE_DIR}/ops/access"
    copy_tree_if_exists "${raw_restore_dir}/${TARGET_CONFIG_DIR#/}" "${STAGE_DIR}/config"
    copy_tree_if_exists "${raw_restore_dir}/${TARGET_SECRETS_DIR#/}" "${STAGE_DIR}/secrets"
  else
    raw_data_root="${raw_restore_dir}/${TARGET_DATA_DIR#/}"
    [[ -d "${raw_data_root}" ]] || fail "Restored snapshot did not contain ${include_path}"
    copy_tree_if_exists "${raw_data_root}/${scope}" "${STAGE_DIR}/data/${scope}"
  fi
}

write_restore_manifest() {
  local source_kind="$1"
  local source_ref="$2"
  local scope="$3"

  cat > "${STAGE_DIR}/restore-manifest.env" <<EOF
SOURCE_KIND=${source_kind}
SOURCE_REF=${source_ref}
SERVICE_SCOPE=${scope}
STAGED_AT=${RUN_TIMESTAMP}
STAGE_DIR=${STAGE_DIR}
RESTORED_DATA_ROOT=${STAGE_DIR}/data
EOF
}

main() {
  local source_ref scope stage_root stage_name source_kind

  [[ $# -ge 1 ]] || fail "Usage: $0 <snapshot-id|latest|backup-archive.tar.gz> [service|full]"

  source_ref="$(resolve_source_path "$1")"
  scope="${2:-full}"

  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    exec 3>&1 1>&2
  fi

  init_logging restore-to-staging
  load_repo_env
  load_target_env
  scope_services "${scope}" >/dev/null

  stage_root="$(resolve_path "${STAGING_DIR:-staging}" "${REPO_ROOT}")"
  ensure_dir "${stage_root}"
  stage_name="restore-${RUN_TIMESTAMP}-$(sanitize_name "${scope}")"
  STAGE_DIR="${stage_root}/${stage_name}"
  mkdir -p "${STAGE_DIR}"

  if [[ -f "${source_ref}" ]]; then
    source_kind="archive"
    restore_local_archive "${source_ref}" "${scope}"
  else
    source_kind="restic"
    restore_restic_snapshot "${source_ref}" "${scope}"
  fi

  write_restore_manifest "${source_kind}" "${source_ref}" "${scope}"
  log "Staged restore created at ${STAGE_DIR}"
  if [[ "${JSON_OUTPUT}" == "1" ]]; then
    python3 - "${STAGE_DIR}" "${source_kind}" "${source_ref}" "${scope}" <<'PY' >&3
import json, sys
print(json.dumps({
    "status": "success",
    "stage_dir": sys.argv[1],
    "source_kind": sys.argv[2],
    "source_ref": sys.argv[3],
    "scope": sys.argv[4],
}, sort_keys=True))
PY
  else
    printf '%s\n' "${STAGE_DIR}"
  fi
}

main "$@"
