#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

failures=0

print_matches() {
  local header="$1"
  shift

  if [[ "$#" -eq 0 ]]; then
    return 0
  fi

  echo "${header}"
  printf '  %s\n' "$@"
  echo
}

check_history_paths() {
  local header="$1"
  local pattern="$2"
  local -a matches=()

  while IFS= read -r match; do
    [[ -n "${match}" ]] || continue
    [[ "${match}" == ".env.example" ]] && continue
    [[ "${match}" == "secrets/.gitkeep" ]] && continue
    matches+=("${match}")
  done < <(git rev-list --objects --all | sed 's#^[^ ]* ##' | grep -E "${pattern}" | sort -u || true)

  if [[ "${#matches[@]}" -gt 0 ]]; then
    print_matches "${header}" "${matches[@]}"
    failures=1
  fi
}

check_history_content() {
  local header="$1"
  local pattern="$2"
  shift 2
  local -a matches=()

  while IFS= read -r match; do
    [[ -n "${match}" ]] || continue
    matches+=("${match}")
  done < <(git log -G "${pattern}" --pretty='format:%h %s' --all -- "$@" || true)

  if [[ "${#matches[@]}" -gt 0 ]]; then
    print_matches "${header}" "${matches[@]}"
    failures=1
  fi
}

check_history_paths \
  "Local-only paths found in reachable Git history:" \
  '^(\.env(\..*)?|\.envrc(\..*)?|logs(/|$)|runtime(/|$)|staging(/|$)|rclone\.conf$|secrets/)'

check_history_paths \
  "Credential-like files found in reachable Git history:" \
  '(^|/).*\.(pem|key|p12|pfx|kdbx)$'

check_history_content \
  "Private key material found in reachable Git history:" \
  'BEGIN [A-Z ]*PRIVATE KEY' \
  . \
  ':(exclude)scripts/public-history-check.sh' \
  ':(exclude)scripts/public-repo-check.sh' \
  ':(exclude)docs/public-github-checklist.md'

check_history_content \
  "Local absolute paths found in reachable Git history:" \
  'C:\\Users\\|/c/Users/|/Users/|/home/[^/]+' \
  . \
  ':(exclude)scripts/public-history-check.sh' \
  ':(exclude)scripts/public-repo-check.sh' \
  ':(exclude)docs/public-github-checklist.md'

check_history_content \
  "Populated local env values found in public env history:" \
  '^(TARGET_ENV_COMMAND|TARGET_ENV_FILE|RCLONE_CONFIG)=.+$' \
  .env \
  .env.* \
  ':(exclude).env.example'

if [[ "${failures}" -ne 0 ]]; then
  echo "Public history safety check failed." >&2
  exit 1
fi

echo "Public history safety check passed."
