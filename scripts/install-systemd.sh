#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_repo_env

install_unit_from_template() {
  local source_file="$1"
  local target_file="$2"

  sed "s#/opt/minecraft-backup-google-drive#${REPO_ROOT}#g" "${source_file}" | sudo tee "${target_file}" >/dev/null
}

install_timer_pair() {
  local service_name="$1"
  local service_src="${REPO_ROOT}/ops/systemd/${service_name}.service"
  local timer_src="${REPO_ROOT}/ops/systemd/${service_name}.timer"
  local service_dst="/etc/systemd/system/${service_name}.service"
  local timer_dst="/etc/systemd/system/${service_name}.timer"

  install_unit_from_template "${service_src}" "${service_dst}"
  sudo cp "${timer_src}" "${timer_dst}"
}

main() {
  install_timer_pair minecraft-local-backup
  install_timer_pair minecraft-offsite-backup
  install_timer_pair minecraft-backup-verify

  sudo systemctl daemon-reload

  if [[ "${ENABLE_GIT_SYNC_ON_BOOT:-1}" == "1" ]]; then
    install_unit_from_template \
      "${REPO_ROOT}/ops/systemd/minecraft-backup-startup-refresh.service" \
      "/etc/systemd/system/minecraft-backup-startup-refresh.service"
    sudo systemctl daemon-reload
    sudo systemctl enable minecraft-backup-startup-refresh.service
  else
    sudo systemctl disable minecraft-backup-startup-refresh.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/minecraft-backup-startup-refresh.service
    sudo systemctl daemon-reload
  fi

  sudo systemctl enable --now \
    minecraft-local-backup.timer \
    minecraft-offsite-backup.timer \
    minecraft-backup-verify.timer
}

main "$@"
