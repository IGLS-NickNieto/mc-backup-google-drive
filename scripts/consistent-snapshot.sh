#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-target-env.sh"

declare -a SNAPSHOT_CONTAINERS=()

container_running() {
  local container_name="$1"
  "${DOCKER_BIN}" inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null | grep -qi '^true$'
}

send_console() {
  local container_name="$1"
  shift
  "${DOCKER_BIN}" exec --user 1000 "${container_name}" mc-send-to-console "$@"
}

begin_consistent_snapshot() {
  local service_name container_name

  load_target_env
  require_command "${DOCKER_BIN}"

  SNAPSHOT_CONTAINERS=()

  while IFS= read -r service_name; do
    container_name="$(container_for_service "${service_name}")"

    if container_running "${container_name}"; then
      log "Pausing world saves for ${service_name} (${container_name})"
      send_console "${container_name}" save-off >/dev/null
      send_console "${container_name}" save-all flush >/dev/null
      SNAPSHOT_CONTAINERS+=("${container_name}")
    else
      log "Container is not running; skipping save pause for ${service_name} (${container_name})"
    fi
  done < <(paper_services)

  sleep "${SNAPSHOT_SLEEP_SECONDS:-5}"
}

end_consistent_snapshot() {
  local container_name

  for container_name in "${SNAPSHOT_CONTAINERS[@]}"; do
    log "Resuming world saves for ${container_name}"
    send_console "${container_name}" save-on >/dev/null 2>&1 || true
  done
}

run_with_consistent_snapshot() {
  local exit_code=0

  begin_consistent_snapshot
  "$@" || exit_code=$?
  end_consistent_snapshot

  return "${exit_code}"
}

main() {
  if [[ $# -eq 0 ]]; then
    run_with_consistent_snapshot true
    return 0
  fi

  if [[ "$1" == "--" ]]; then
    shift
  fi

  run_with_consistent_snapshot "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
