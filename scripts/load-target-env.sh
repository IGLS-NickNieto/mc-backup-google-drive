#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

import_env_stream() {
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done
}

derive_target_defaults() {
  TARGET_STACK_ROOT="$(resolve_path "${TARGET_STACK_ROOT:-/opt/minecraft}" "${REPO_ROOT}")"
  TARGET_COMPOSE_PROJECT_DIR="${TARGET_COMPOSE_PROJECT_DIR:-${TARGET_STACK_ROOT}}"
  TARGET_COMPOSE_FILE="${TARGET_COMPOSE_FILE:-${TARGET_STACK_ROOT}/compose.yaml}"
  TARGET_DATA_DIR="${TARGET_DATA_DIR:-${TARGET_STACK_ROOT}/data}"
  TARGET_BACKUPS_DIR="${TARGET_BACKUPS_DIR:-${TARGET_STACK_ROOT}/backups}"
  TARGET_ACCESS_DIR="${TARGET_ACCESS_DIR:-${TARGET_STACK_ROOT}/ops/access}"
  TARGET_CONFIG_DIR="${TARGET_CONFIG_DIR:-${TARGET_STACK_ROOT}/config}"
  TARGET_SECRETS_DIR="${TARGET_SECRETS_DIR:-${TARGET_STACK_ROOT}/secrets}"
  TARGET_INVITE_PLAYERS_FILE="${TARGET_INVITE_PLAYERS_FILE:-${TARGET_ACCESS_DIR}/invite-players.txt}"
  TARGET_BACKUP_SCRIPT="${TARGET_BACKUP_SCRIPT:-${TARGET_STACK_ROOT}/scripts/backup-worlds.sh}"
  TARGET_PROXY_CONTAINER="${TARGET_PROXY_CONTAINER:-mc-proxy}"
  TARGET_LOBBY_CONTAINER="${TARGET_LOBBY_CONTAINER:-mc-lobby}"
  TARGET_SURVIVAL_CONTAINER="${TARGET_SURVIVAL_CONTAINER:-mc-survival}"
  TARGET_CREATIVE_CONTAINER="${TARGET_CREATIVE_CONTAINER:-mc-creative}"
}

load_target_env() {
  local target_env_command

  load_repo_env

  TARGET_STACK_ROOT="${TARGET_STACK_ROOT:-/opt/minecraft}"
  TARGET_ENV_COMMAND="${TARGET_ENV_COMMAND:-}"
  TARGET_ENV_FILE="${TARGET_ENV_FILE:-}"

  if [[ -n "${TARGET_ENV_FILE}" ]]; then
    TARGET_ENV_FILE="$(resolve_path "${TARGET_ENV_FILE}" "${REPO_ROOT}")"
    [[ -f "${TARGET_ENV_FILE}" ]] || fail "Configured TARGET_ENV_FILE was not found: ${TARGET_ENV_FILE}"
    import_env_stream < "${TARGET_ENV_FILE}"
  else
    target_env_command="${TARGET_ENV_COMMAND:-${TARGET_STACK_ROOT}/scripts/export-admin-target-env.sh}"
    if [[ -x "${target_env_command}" ]]; then
      import_env_stream < <("${target_env_command}")
    fi
  fi

  derive_target_defaults

  TARGET_STACK_ROOT="$(resolve_path "${TARGET_STACK_ROOT}" "/")"
  TARGET_COMPOSE_PROJECT_DIR="$(resolve_path "${TARGET_COMPOSE_PROJECT_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_COMPOSE_FILE="$(resolve_path "${TARGET_COMPOSE_FILE}" "${TARGET_STACK_ROOT}")"
  TARGET_DATA_DIR="$(resolve_path "${TARGET_DATA_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_BACKUPS_DIR="$(resolve_path "${TARGET_BACKUPS_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_ACCESS_DIR="$(resolve_path "${TARGET_ACCESS_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_CONFIG_DIR="$(resolve_path "${TARGET_CONFIG_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_SECRETS_DIR="$(resolve_path "${TARGET_SECRETS_DIR}" "${TARGET_STACK_ROOT}")"
  TARGET_INVITE_PLAYERS_FILE="$(resolve_path "${TARGET_INVITE_PLAYERS_FILE}" "${TARGET_STACK_ROOT}")"
  TARGET_BACKUP_SCRIPT="$(resolve_path "${TARGET_BACKUP_SCRIPT}" "${TARGET_STACK_ROOT}")"

  STACK_NAME="${STACK_NAME:-$(basename "${TARGET_STACK_ROOT}")}"
  DOCKER_BIN="${DOCKER_BIN:-docker}"
  RESTIC_BIN="${RESTIC_BIN:-restic}"
  RCLONE_BIN="${RCLONE_BIN:-rclone}"

  TARGET_PROXY_DATA_DIR="${TARGET_DATA_DIR}/proxy"
  TARGET_LOBBY_DATA_DIR="${TARGET_DATA_DIR}/lobby"
  TARGET_SURVIVAL_DATA_DIR="${TARGET_DATA_DIR}/survival"
  TARGET_CREATIVE_DATA_DIR="${TARGET_DATA_DIR}/creative"

  export TARGET_STACK_ROOT TARGET_COMPOSE_PROJECT_DIR TARGET_COMPOSE_FILE
  export TARGET_DATA_DIR TARGET_BACKUPS_DIR TARGET_ACCESS_DIR TARGET_CONFIG_DIR TARGET_SECRETS_DIR TARGET_INVITE_PLAYERS_FILE TARGET_BACKUP_SCRIPT
  export TARGET_PROXY_CONTAINER TARGET_LOBBY_CONTAINER TARGET_SURVIVAL_CONTAINER TARGET_CREATIVE_CONTAINER
  export TARGET_PROXY_DATA_DIR TARGET_LOBBY_DATA_DIR TARGET_SURVIVAL_DATA_DIR TARGET_CREATIVE_DATA_DIR
  export STACK_NAME DOCKER_BIN RESTIC_BIN RCLONE_BIN
}

full_restore_paths() {
  printf '%s\n' \
    "${TARGET_DATA_DIR}" \
    "${TARGET_ACCESS_DIR}" \
    "${TARGET_CONFIG_DIR}" \
    "${TARGET_SECRETS_DIR}"
}

all_services() {
  printf '%s\n' proxy lobby survival creative
}

paper_services() {
  printf '%s\n' lobby survival creative
}

is_paper_service() {
  case "$1" in
    lobby|survival|creative) return 0 ;;
    *) return 1 ;;
  esac
}

container_for_service() {
  case "$1" in
    proxy) printf '%s\n' "${TARGET_PROXY_CONTAINER}" ;;
    lobby) printf '%s\n' "${TARGET_LOBBY_CONTAINER}" ;;
    survival) printf '%s\n' "${TARGET_SURVIVAL_CONTAINER}" ;;
    creative) printf '%s\n' "${TARGET_CREATIVE_CONTAINER}" ;;
    *) fail "Unknown service: $1" ;;
  esac
}

data_dir_for_service() {
  case "$1" in
    proxy) printf '%s\n' "${TARGET_PROXY_DATA_DIR}" ;;
    lobby) printf '%s\n' "${TARGET_LOBBY_DATA_DIR}" ;;
    survival) printf '%s\n' "${TARGET_SURVIVAL_DATA_DIR}" ;;
    creative) printf '%s\n' "${TARGET_CREATIVE_DATA_DIR}" ;;
    *) fail "Unknown service: $1" ;;
  esac
}

scope_services() {
  local scope="${1:-full}"

  case "${scope}" in
    full)
      all_services
      ;;
    proxy|lobby|survival|creative)
      printf '%s\n' "${scope}"
      ;;
    *)
      fail "Unsupported scope: ${scope}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  load_target_env
  cat <<EOF
TARGET_STACK_ROOT=${TARGET_STACK_ROOT}
TARGET_COMPOSE_PROJECT_DIR=${TARGET_COMPOSE_PROJECT_DIR}
TARGET_COMPOSE_FILE=${TARGET_COMPOSE_FILE}
TARGET_DATA_DIR=${TARGET_DATA_DIR}
TARGET_BACKUPS_DIR=${TARGET_BACKUPS_DIR}
TARGET_ACCESS_DIR=${TARGET_ACCESS_DIR}
TARGET_CONFIG_DIR=${TARGET_CONFIG_DIR}
TARGET_SECRETS_DIR=${TARGET_SECRETS_DIR}
TARGET_INVITE_PLAYERS_FILE=${TARGET_INVITE_PLAYERS_FILE}
TARGET_BACKUP_SCRIPT=${TARGET_BACKUP_SCRIPT}
TARGET_PROXY_CONTAINER=${TARGET_PROXY_CONTAINER}
TARGET_LOBBY_CONTAINER=${TARGET_LOBBY_CONTAINER}
TARGET_SURVIVAL_CONTAINER=${TARGET_SURVIVAL_CONTAINER}
TARGET_CREATIVE_CONTAINER=${TARGET_CREATIVE_CONTAINER}
STACK_NAME=${STACK_NAME}
EOF
fi
