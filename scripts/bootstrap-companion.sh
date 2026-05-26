#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/minecraft-backup-google-drive}"
TARGET_STACK_ROOT_DEFAULT="${TARGET_STACK_ROOT:-/opt/minecraft}"
APP_USER="${SUDO_USER:-$USER}"
ENABLE_GIT_SYNC_ON_BOOT_DEFAULT="${ENABLE_GIT_SYNC_ON_BOOT:-1}"

if ! command -v sudo >/dev/null 2>&1; then
  echo "This script expects sudo to be available." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_GROUP="$(id -gn "${APP_USER}")"

run_as_app_user() {
  sudo -u "${APP_USER}" "$@"
}

is_interactive() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

read_env_value() {
  local file="$1"
  local key="$2"
  local raw_value

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  raw_value="$(sed -n "s#^${key}=##p" "${file}" | tail -n1)"
  if [[ -z "${raw_value}" ]]; then
    return 0
  fi

  python3 -c 'import shlex, sys; value = sys.argv[1]; parsed = shlex.split(value, posix=True); print(parsed[0] if parsed else "")' "${raw_value}"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

detect_git_repo_url() {
  if [[ -d "${ROOT_DIR}/.git" ]]; then
    git -C "${ROOT_DIR}" config --get remote.origin.url 2>/dev/null || true
  fi
}

detect_git_ref() {
  local branch=""

  if [[ -d "${ROOT_DIR}/.git" ]]; then
    branch="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "${branch}" == "HEAD" ]]; then
      branch="$(git -C "${ROOT_DIR}" describe --tags --exact-match 2>/dev/null || true)"
    fi
  fi

  if [[ "${branch}" == "HEAD" ]]; then
    branch=""
  fi

  printf '%s\n' "${branch}"
}

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

  temp_dir="$(run_as_app_user mktemp -d)"

  if run_as_app_user git clone --depth 1 --branch "${ref}" "${repo_url}" "${temp_dir}/repo"; then
    :
  else
    default_ref="$(detect_remote_default_ref "${repo_url}")"
    if [[ -n "${default_ref}" && "${default_ref}" != "${ref}" ]]; then
      echo "Git ref ${ref} was not found; falling back to remote default branch ${default_ref}..."
      run_as_app_user git clone --depth 1 --branch "${default_ref}" "${repo_url}" "${temp_dir}/repo"
      ref="${default_ref}"
    else
      echo "Unable to clone ${repo_url} using ref ${ref}." >&2
      exit 1
    fi
  fi

  run_as_app_user rsync -a --delete \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude 'logs/' \
    --exclude 'runtime/' \
    --exclude 'staging/' \
    --exclude 'secrets/' \
    --exclude 'rclone.conf' \
    "${temp_dir}/repo/" "${APP_DIR}/"

  run_as_app_user rm -rf "${temp_dir}"
}

upsert_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local quoted_value

  printf -v quoted_value '%q' "${value}"
  quoted_value="$(escape_sed_replacement "${quoted_value}")"

  if grep -q "^${key}=" "${file}"; then
    run_as_app_user sed -i "s#^${key}=.*#${key}=${quoted_value}#" "${file}"
  else
    run_as_app_user sh -c 'printf "%s=%s\n" "$1" "$2" >> "$3"' _ "${key}" "${quoted_value}" "${file}"
  fi
}

resolve_setting_or_default() {
  local key="$1"
  local default_value="$2"
  local env_value file_value

  env_value="${!key:-}"
  if [[ -n "${env_value}" ]]; then
    printf '%s\n' "${env_value}"
    return 0
  fi

  file_value="$(read_env_value "${APP_DIR}/.env" "${key}")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi

  printf '%s\n' "${default_value}"
}

prompt_for_setting() {
  local key="$1"
  local prompt_text="$2"
  local default_value="$3"
  local hidden="${4:-0}"
  local env_value file_value prompt_suffix value

  env_value="${!key:-}"
  if [[ -n "${env_value}" ]]; then
    printf '%s\n' "${env_value}"
    return 0
  fi

  file_value="$(read_env_value "${APP_DIR}/.env" "${key}")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi

  if ! is_interactive; then
    if [[ -n "${default_value}" ]]; then
      printf '%s\n' "${default_value}"
      return 0
    fi

    echo "Missing required ${key}. Re-run scripts/bootstrap-companion.sh interactively or set ${key} in the environment or .env." >&2
    exit 1
  fi

  prompt_suffix=""
  if [[ -n "${default_value}" ]]; then
    prompt_suffix=" [${default_value}]"
  fi

  while true; do
    if [[ "${hidden}" == "1" ]]; then
      read -r -s -p "${prompt_text}${prompt_suffix}: " value </dev/tty >/dev/tty
      printf '\n' >/dev/tty
    else
      read -r -p "${prompt_text}${prompt_suffix}: " value </dev/tty >/dev/tty
    fi

    if [[ -z "${value}" && -n "${default_value}" ]]; then
      value="${default_value}"
    fi

    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi

    echo "${key} cannot be empty." >&2
  done
}

generate_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

ensure_rclone_remote() {
  if rclone listremotes 2>/dev/null | grep -Fxq "${GOOGLE_DRIVE_REMOTE_VALUE}:"; then
    return 0
  fi

  if ! is_interactive; then
    echo "Rclone remote ${GOOGLE_DRIVE_REMOTE_VALUE}: was not found. Run rclone config or re-run interactively." >&2
    exit 1
  fi

  echo "Launching rclone config so you can create ${GOOGLE_DRIVE_REMOTE_VALUE}: ..."
  rclone config

  if ! rclone listremotes 2>/dev/null | grep -Fxq "${GOOGLE_DRIVE_REMOTE_VALUE}:"; then
    echo "Rclone remote ${GOOGLE_DRIVE_REMOTE_VALUE}: is still missing after configuration." >&2
    exit 1
  fi
}

ensure_restic_repository() {
  local repo_url="$1"
  local password_file="$2"
  local cache_dir="$3"

  RESTIC_REPOSITORY="${repo_url}" RESTIC_PASSWORD_FILE="${password_file}" RESTIC_CACHE_DIR="${cache_dir}" \
    restic snapshots >/dev/null 2>&1 && return 0

  echo "Initializing restic repository ${repo_url}..."
  RESTIC_REPOSITORY="${repo_url}" RESTIC_PASSWORD_FILE="${password_file}" RESTIC_CACHE_DIR="${cache_dir}" \
    restic init >/dev/null
}

resolve_runtime_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "${APP_DIR}" "${path}"
  fi
}

echo "Installing backup companion packages..."
sudo apt update
sudo apt install -y restic rclone rsync tar git

echo "Preparing backup companion directory..."
sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 0775 "${APP_DIR}"

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_REF="${GIT_REF:-}"

if [[ -z "${GIT_REPO_URL}" ]]; then
  GIT_REPO_URL="$(read_env_value "${APP_DIR}/.env" "GIT_REPO_URL")"
fi
if [[ -z "${GIT_REPO_URL}" ]]; then
  GIT_REPO_URL="$(detect_git_repo_url)"
fi

if [[ -z "${GIT_REF}" ]]; then
  GIT_REF="$(read_env_value "${APP_DIR}/.env" "GIT_REF")"
fi
if [[ -z "${GIT_REF}" ]]; then
  GIT_REF="$(detect_git_ref)"
fi
if [[ -z "${GIT_REF}" && -n "${GIT_REPO_URL}" ]]; then
  GIT_REF="$(detect_remote_default_ref "${GIT_REPO_URL}")"
fi
GIT_REF="${GIT_REF:-master}"

if [[ -n "${GIT_REPO_URL}" ]]; then
  echo "Syncing backup repo into ${APP_DIR} from ${GIT_REPO_URL} (${GIT_REF})..."
  sync_repo_snapshot_from_git "${GIT_REPO_URL}" "${GIT_REF}"
elif [[ "${ROOT_DIR}" != "${APP_DIR}" ]]; then
  echo "Syncing backup repo into ${APP_DIR}..."
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude 'logs/' \
    --exclude 'runtime/' \
    --exclude 'staging/' \
    --exclude 'secrets/' \
    --exclude 'rclone.conf' \
    "${ROOT_DIR}/" "${APP_DIR}/"
fi

echo "Normalizing backup companion ownership and permissions..."
sudo chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
sudo find "${APP_DIR}" -type d -exec chmod u+rwx {} +
sudo find "${APP_DIR}" -type f -exec chmod u+rw {} +

cd "${APP_DIR}"

if [[ ! -f .env ]]; then
  run_as_app_user cp .env.example .env
fi

TARGET_STACK_ROOT_VALUE="$(prompt_for_setting "TARGET_STACK_ROOT" "Core stack root" "${TARGET_STACK_ROOT_DEFAULT}")"
GOOGLE_DRIVE_REMOTE_VALUE="$(prompt_for_setting "GOOGLE_DRIVE_REMOTE" "Rclone remote name for Google Drive" "homelab-gdrive")"
RESTIC_REPOSITORY_VALUE="$(prompt_for_setting "RESTIC_REPOSITORY" "Restic repository" "rclone:${GOOGLE_DRIVE_REMOTE_VALUE}:minecraft/mc-paper-velocity-geyser-stack")"
RESTIC_PASSWORD_FILE_VALUE="$(resolve_setting_or_default "RESTIC_PASSWORD_FILE" "${APP_DIR}/secrets/restic-password")"
ENABLE_GIT_SYNC_ON_BOOT_VALUE="$(resolve_setting_or_default "ENABLE_GIT_SYNC_ON_BOOT" "${ENABLE_GIT_SYNC_ON_BOOT_DEFAULT}")"

upsert_env_var .env "TARGET_STACK_ROOT" "${TARGET_STACK_ROOT_VALUE}"
upsert_env_var .env "GIT_REPO_URL" "${GIT_REPO_URL}"
upsert_env_var .env "GIT_REF" "${GIT_REF}"
upsert_env_var .env "ENABLE_GIT_SYNC_ON_BOOT" "${ENABLE_GIT_SYNC_ON_BOOT_VALUE}"
upsert_env_var .env "GOOGLE_DRIVE_REMOTE" "${GOOGLE_DRIVE_REMOTE_VALUE}"
upsert_env_var .env "RESTIC_REPOSITORY" "${RESTIC_REPOSITORY_VALUE}"
upsert_env_var .env "RESTIC_PASSWORD_FILE" "${RESTIC_PASSWORD_FILE_VALUE}"

for key in \
  TARGET_ENV_COMMAND \
  TARGET_ENV_FILE \
  RESTIC_CACHE_DIR \
  RCLONE_CONFIG \
  LOG_DIR \
  RUNTIME_DIR \
  STAGING_DIR \
  OFFSITE_KEEP_HOURLY \
  OFFSITE_KEEP_DAILY \
  OFFSITE_KEEP_WEEKLY \
  OFFSITE_KEEP_MONTHLY \
  OFFSITE_BACKUP_TAGS \
  OFFSITE_TIMER_ON_CALENDAR \
  LOCAL_TIMER_ON_CALENDAR \
  VERIFY_TIMER_ON_CALENDAR \
  VERIFY_OFFSITE_SNAPSHOT \
  VERIFY_SCOPE \
  VERIFY_CONFIG_ASSETS \
  DOCKER_BIN \
  RESTIC_BIN \
  RCLONE_BIN \
  SNAPSHOT_SLEEP_SECONDS; do
  upsert_env_var .env "${key}" "$(resolve_setting_or_default "${key}" "$(read_env_value .env.example "${key}")")"
done

set -a
# shellcheck disable=SC1091
source .env
set +a

chmod +x scripts/*.sh scripts/lib/*.sh

run_as_app_user mkdir -p secrets
if [[ ! -f "${RESTIC_PASSWORD_FILE_VALUE}" ]]; then
  echo "Generating restic password file at ${RESTIC_PASSWORD_FILE_VALUE}..."
  run_as_app_user mkdir -p "$(dirname "${RESTIC_PASSWORD_FILE_VALUE}")"
  run_as_app_user sh -c 'printf "%s\n" "$1" > "$2"' _ "$(generate_secret)" "${RESTIC_PASSWORD_FILE_VALUE}"
  run_as_app_user chmod 600 "${RESTIC_PASSWORD_FILE_VALUE}"
fi

ensure_rclone_remote
run_as_app_user mkdir -p \
  "$(resolve_runtime_path "${RESTIC_CACHE_DIR:-runtime/restic-cache}")" \
  "$(resolve_runtime_path "${LOG_DIR:-logs}")" \
  "$(resolve_runtime_path "${RUNTIME_DIR:-runtime}")" \
  "$(resolve_runtime_path "${STAGING_DIR:-staging}")"
ensure_restic_repository "${RESTIC_REPOSITORY_VALUE}" "${RESTIC_PASSWORD_FILE_VALUE}" "$(resolve_runtime_path "${RESTIC_CACHE_DIR:-runtime/restic-cache}")"

echo "Installing backup timers and startup refresh service..."
sudo chmod +x scripts/*.sh scripts/lib/*.sh
./scripts/install-systemd.sh

cat <<EOF

Backup companion bootstrap complete.

Project dir:         ${APP_DIR}
Core stack:          ${TARGET_STACK_ROOT_VALUE}
Google Drive remote: ${GOOGLE_DRIVE_REMOTE_VALUE}
Restic repository:   ${RESTIC_REPOSITORY_VALUE}

Useful checks:
  ./scripts/list-snapshots.sh
  systemctl status minecraft-local-backup.timer
  systemctl status minecraft-offsite-backup.timer
  systemctl status minecraft-backup-verify.timer
EOF
