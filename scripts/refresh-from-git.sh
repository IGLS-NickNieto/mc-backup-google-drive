#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export FORCE_GIT_REFRESH=1
exec bash "${ROOT_DIR}/scripts/startup-refresh.sh" "$@"
