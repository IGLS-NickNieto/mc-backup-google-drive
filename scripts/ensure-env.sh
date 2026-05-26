#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
EXAMPLE_FILE="${ENV_EXAMPLE_FILE:-${ROOT_DIR}/.env.example}"

if [[ ! -f "${EXAMPLE_FILE}" ]]; then
  echo "Missing ${EXAMPLE_FILE}; cannot repair ${ENV_FILE}." >&2
  exit 1
fi

quote_env_value() {
  local value="$1"
  local quoted=""

  if [[ -z "${value}" ]]; then
    return 0
  fi

  printf -v quoted '%q' "${value}"
  printf '%s' "${quoted}"
}

write_env_line() {
  local line="${1%$'\r'}"
  local key value

  if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    key="${line%%=*}"
    value="${line#*=}"
    printf '%s=%s\n' "${key}" "$(quote_env_value "${value}")"
  else
    printf '%s\n' "${line}"
  fi
}

create_env_from_example() {
  umask 077
  : > "${ENV_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    write_env_line "${line}" >> "${ENV_FILE}"
  done < "${EXAMPLE_FILE}"
  echo "Created ${ENV_FILE} from ${EXAMPLE_FILE}."
}

key_exists() {
  local key="$1"
  grep -q "^${key}=" "${ENV_FILE}"
}

append_missing_keys() {
  local added_header=0
  local key line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"

    if ! key_exists "${key}"; then
      if [[ "${added_header}" -eq 0 ]]; then
        printf '\n# Added by scripts/ensure-env.sh from .env.example\n' >> "${ENV_FILE}"
        added_header=1
      fi
      write_env_line "${line}" >> "${ENV_FILE}"
      echo "Added missing ${key} to ${ENV_FILE}."
    fi
  done < "${EXAMPLE_FILE}"
}

read_env_value() {
  local key="$1"
  local raw_value=""

  raw_value="$(sed -n "s#^${key}=##p" "${ENV_FILE}" | tail -n1 || true)"
  raw_value="${raw_value%$'\r'}"
  printf '%s' "${raw_value}"
}

strip_wrapping_quotes() {
  local value="$1"

  if [[ "${#value}" -ge 2 ]]; then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi

  printf '%s' "${value}"
}

is_blank_or_placeholder() {
  local value="$1"
  local normalized

  value="$(strip_wrapping_quotes "${value}")"
  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"

  case "${normalized}" in
    ""|"''"|"\"\""|change-me*|changeme*|change_me*|replace-me*|replace_me*|todo|placeholder)
      return 0
      ;;
  esac

  return 1
}

is_enabled() {
  local value

  value="$(strip_wrapping_quotes "$(read_env_value "$1")")"
  [[ "${value}" == "1" || "${value,,}" == "true" || "${value,,}" == "yes" ]]
}

validate_required_keys() {
  local failures=0
  local key value

  for key in "$@"; do
    value="$(read_env_value "${key}")"
    if is_blank_or_placeholder "${value}"; then
      echo "Missing required ${key} in ${ENV_FILE}; set it or rerun scripts/bootstrap-companion.sh." >&2
      failures=1
    fi
  done

  return "${failures}"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  create_env_from_example
fi

append_missing_keys

if is_enabled ENABLE_GIT_SYNC_ON_BOOT || [[ "${FORCE_GIT_REFRESH:-0}" == "1" ]]; then
  required_keys=(
    GIT_REPO_URL
    TARGET_STACK_ROOT
    STACK_NAME
    GOOGLE_DRIVE_REMOTE
    RESTIC_REPOSITORY
    RESTIC_PASSWORD_FILE
  )

  validate_required_keys "${required_keys[@]}"
fi
