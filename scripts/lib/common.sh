#!/usr/bin/env bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/../.." && pwd)"
DEFAULT_ENV_FILE="${REPO_ROOT}/.env"
DEFAULT_LOG_DIR="${REPO_ROOT}/logs"
DEFAULT_RUNTIME_DIR="${REPO_ROOT}/runtime"
DEFAULT_STAGING_DIR="${REPO_ROOT}/staging"

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

timestamp_compact() {
  date -u +%Y%m%dT%H%M%SZ
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

ensure_dir() {
  mkdir -p "$1"
}

resolve_path() {
  local input_path="$1"
  local base_path="${2:-${REPO_ROOT}}"

  if [[ -z "${input_path}" ]]; then
    fail "resolve_path received an empty path"
  fi

  if [[ "${input_path}" = /* ]]; then
    printf '%s\n' "${input_path}"
  else
    printf '%s\n' "${base_path}/${input_path}"
  fi
}

load_repo_env() {
  local env_file="${1:-${DEFAULT_ENV_FILE}}"

  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
}

sanitize_name() {
  printf '%s' "$1" | tr ' /:\\' '____' | tr -cd 'A-Za-z0-9._-'
}

init_logging() {
  local prefix="$1"
  local log_dir

  load_repo_env
  log_dir="$(resolve_path "${LOG_DIR:-logs}" "${REPO_ROOT}")"
  ensure_dir "${log_dir}"
  ensure_dir "${log_dir}/manifests"

  RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(timestamp_compact)}"
  LOG_FILE="${log_dir}/${prefix}-${RUN_TIMESTAMP}.log"
  MANIFEST_DIR="${log_dir}/manifests"
  export RUN_TIMESTAMP LOG_FILE MANIFEST_DIR

  exec > >(tee -a "${LOG_FILE}") 2>&1
  log "Logging to ${LOG_FILE}"
}

make_run_dir() {
  local prefix="$1"
  local runtime_dir

  runtime_dir="$(resolve_path "${RUNTIME_DIR:-runtime}" "${REPO_ROOT}")"
  ensure_dir "${runtime_dir}"
  RUN_DIR="$(mktemp -d "${runtime_dir}/${prefix}-${RUN_TIMESTAMP:-$(timestamp_compact)}-XXXXXX")"
  export RUN_DIR
}

strip_cr() {
  sed 's/\r$//'
}

read_config_lines() {
  local file_path="$1"

  [[ -f "${file_path}" ]] || return 0

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    raw_line="${raw_line%$'\r'}"
    [[ -z "${raw_line}" ]] && continue
    [[ "${raw_line}" =~ ^[[:space:]]*# ]] && continue
    printf '%s\n' "${raw_line}"
  done < "${file_path}"
}

write_hash_manifest() {
  local source_root="$1"
  local output_file="$2"

  if [[ ! -d "${source_root}" ]]; then
    : > "${output_file}"
    return 0
  fi

  (
    cd "${source_root}"
    find . -type f | LC_ALL=C sort | while IFS= read -r rel_path; do
      rel_path="${rel_path#./}"
      printf '%s\t%s\n' "${rel_path}" "$(sha256sum "${rel_path}" | awk '{print $1}')"
    done
  ) > "${output_file}"
}

copy_tree_if_exists() {
  local source_path="$1"
  local target_path="$2"

  if [[ -d "${source_path}" ]]; then
    ensure_dir "${target_path}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${source_path}/" "${target_path}/"
    else
      (
        cd "${source_path}"
        tar -cf - .
      ) | (
        cd "${target_path}"
        tar -xf -
      )
    fi
  fi
}

replace_tree() {
  local source_path="$1"
  local target_path="$2"

  [[ -d "${source_path}" ]] || fail "Source directory not found: ${source_path}"
  ensure_dir "${target_path}"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${source_path}/" "${target_path}/"
  else
    find "${target_path}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    (
      cd "${source_path}"
      tar -cf - .
    ) | (
      cd "${target_path}"
      tar -xf -
    )
  fi
}

count_files() {
  local source_path="$1"

  if [[ -d "${source_path}" ]]; then
    find "${source_path}" -type f | wc -l | awk '{print $1}'
  else
    printf '0\n'
  fi
}
