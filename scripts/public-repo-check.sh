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

check_tracked_paths() {
  local header="$1"
  shift
  local -a matches=()

  while IFS= read -r match; do
    [[ -e "${match}" ]] || continue
    [[ "${match}" == "secrets/.gitkeep" ]] && continue
    matches+=("${match}")
  done < <(git ls-files -- "$@")

  if [[ "${#matches[@]}" -gt 0 ]]; then
    print_matches "${header}" "${matches[@]}"
    failures=1
  fi
}

check_tracked_content() {
  local header="$1"
  local pattern="$2"
  shift 2
  local -a matches=()

  while IFS= read -r match; do
    case "${match}" in
      scripts/public-repo-check.sh:*|scripts/public-history-check.sh:*|docs/public-github-checklist.md:*)
        continue
        ;;
    esac
    matches+=("${match}")
  done < <(git grep -nI -E "${pattern}" -- "$@" || true)

  if [[ "${#matches[@]}" -gt 0 ]]; then
    print_matches "${header}" "${matches[@]}"
    failures=1
  fi
}

check_tracked_paths \
  "Tracked local-only files detected:" \
  .env \
  .env.local \
  .env.production \
  .env.staging \
  logs \
  runtime \
  staging \
  rclone.conf \
  secrets/* \
  '*.pem' \
  '*.key' \
  '*.p12' \
  '*.pfx' \
  '*.kdbx'

check_tracked_content \
  "Tracked private key material detected:" \
  'BEGIN [A-Z ]*PRIVATE KEY' \
  .

check_tracked_content \
  "Tracked local absolute paths detected:" \
  'C:\\Users\\|/c/Users/|/Users/|/home/[^/]+/' \
  .

for expected_blank in TARGET_ENV_COMMAND TARGET_ENV_FILE RCLONE_CONFIG; do
  current_line="$(grep -E "^${expected_blank}=" .env.example || true)"
  if [[ "${current_line}" != "${expected_blank}=" ]]; then
    print_matches \
      "${expected_blank} in .env.example should stay blank for public publishing:" \
      "${current_line:-${expected_blank} line missing}"
    failures=1
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  echo "Public repo safety check failed." >&2
  exit 1
fi

echo "Public repo safety check passed."
