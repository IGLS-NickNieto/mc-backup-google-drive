#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

APP_OWNER="$(stat -c '%U' "${ROOT_DIR}")"

run_as_app_owner() {
  if [[ "$(id -un)" == "${APP_OWNER}" ]]; then
    "$@"
  else
    sudo -u "${APP_OWNER}" "$@"
  fi
}

run_as_app_owner bash "${ROOT_DIR}/scripts/ensure-env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}; run scripts/bootstrap-companion.sh interactively once before enabling boot refresh." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

ENABLE_GIT_SYNC_ON_BOOT="${ENABLE_GIT_SYNC_ON_BOOT:-0}"
FORCE_GIT_REFRESH="${FORCE_GIT_REFRESH:-0}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_REF="${GIT_REF:-}"

if [[ "${ENABLE_GIT_SYNC_ON_BOOT}" != "1" && "${FORCE_GIT_REFRESH}" != "1" ]]; then
  echo "ENABLE_GIT_SYNC_ON_BOOT is not enabled; skipping backup startup refresh."
  exit 0
fi

require_persisted_value() {
  local key="$1"
  local value="${!key:-}"

  if [[ -z "${value}" ]]; then
    echo "Missing ${key} in ${ENV_FILE}; re-run scripts/bootstrap-companion.sh interactively to repair the install." >&2
    exit 1
  fi
}

require_persisted_value "GIT_REPO_URL"
require_persisted_value "RESTIC_REPOSITORY"
require_persisted_value "RESTIC_PASSWORD_FILE"

detect_remote_default_ref() {
  local repo_url="$1"
  local remote_head=""

  remote_head="$(git ls-remote --symref "${repo_url}" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/##p' | awk 'NR==1 {print $1}')"
  printf '%s\n' "${remote_head}"
}

sync_repo_snapshot_from_git() {
  local repo_url="$1"
  local ref="$2"
  local temp_dir
  local default_ref

  temp_dir="$(run_as_app_owner mktemp -d)"
  if run_as_app_owner git clone --depth 1 --branch "${ref}" "${repo_url}" "${temp_dir}/repo"; then
    :
  else
    default_ref="$(detect_remote_default_ref "${repo_url}")"
    if [[ -n "${default_ref}" && "${default_ref}" != "${ref}" ]]; then
      echo "Git ref ${ref} was not found; falling back to remote default branch ${default_ref}..."
      run_as_app_owner git clone --depth 1 --branch "${default_ref}" "${repo_url}" "${temp_dir}/repo"
    else
      echo "Unable to clone ${repo_url} using ref ${ref}." >&2
      exit 1
    fi
  fi

  run_as_app_owner rsync -a --delete \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude 'logs/' \
    --exclude 'runtime/' \
    --exclude 'staging/' \
    --exclude 'secrets/' \
    --exclude 'rclone.conf' \
    "${temp_dir}/repo/" "${ROOT_DIR}/"

  run_as_app_owner rm -rf "${temp_dir}"
}

if [[ -z "${GIT_REF}" ]]; then
  GIT_REF="$(detect_remote_default_ref "${GIT_REPO_URL}")"
fi
GIT_REF="${GIT_REF:-master}"

echo "Refreshing backup tracked files from ${GIT_REPO_URL} (${GIT_REF})..."
sync_repo_snapshot_from_git "${GIT_REPO_URL}" "${GIT_REF}"

cd "${ROOT_DIR}"
run_as_app_owner chmod +x scripts/*.sh scripts/lib/*.sh
run_as_app_owner bash "${ROOT_DIR}/scripts/ensure-env.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

./scripts/install-systemd.sh
