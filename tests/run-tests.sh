#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
FIXTURE_DIR="${TESTS_DIR}/fixtures"

PASS_COUNT=0
FAIL_COUNT=0

restore_repo_files() {
  if [[ -n "${ORIGINAL_EXTRA_PATHS_FILE:-}" && -f "${ORIGINAL_EXTRA_PATHS_FILE}" ]]; then
    cp "${ORIGINAL_EXTRA_PATHS_FILE}" "${REPO_ROOT}/config/extra-paths.txt"
  fi

  rm -f "${REPO_ROOT}/hooks/pre-backup.d/test-fixture-hook.sh"
}

cleanup_test_root() {
  restore_repo_files

  if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT}" ]]; then
    rm -rf "${TEST_ROOT}"
  fi
}

trap cleanup_test_root EXIT

setup_test_root() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT

  ORIGINAL_EXTRA_PATHS_FILE="${TEST_ROOT}/original-extra-paths.txt"
  cp "${REPO_ROOT}/config/extra-paths.txt" "${ORIGINAL_EXTRA_PATHS_FILE}"

  mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/capture"
  export TEST_CAPTURE_DIR="${TEST_ROOT}/capture"

  cat > "${TEST_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${TEST_CAPTURE_DIR}"
printf '%s\n' "$*" >> "${TEST_CAPTURE_DIR}/docker.log"

case "${1:-}" in
  inspect)
    printf 'true\n'
    ;;
  exec|stop|start)
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${TEST_ROOT}/bin/docker"

  cat > "${TEST_ROOT}/bin/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${TEST_CAPTURE_DIR}"

subcommand=""
for arg in "$@"; do
  case "${arg}" in
    backup|forget|restore|snapshots)
      subcommand="${arg}"
      break
      ;;
  esac
done

case "${subcommand}" in
  backup)
    seen_backup=0
    expect_value=0
    : > "${TEST_CAPTURE_DIR}/restic-sources.txt"

    for arg in "$@"; do
      if [[ "${seen_backup}" == "0" ]]; then
        [[ "${arg}" == "backup" ]] && seen_backup=1
        continue
      fi

      if [[ "${expect_value}" == "1" ]]; then
        expect_value=0
        continue
      fi

      case "${arg}" in
        --tag)
          expect_value=1
          ;;
        --*)
          ;;
        *)
          printf '%s\n' "${arg}" >> "${TEST_CAPTURE_DIR}/restic-sources.txt"
          if [[ -d "${arg}" && "$(basename "${arg}")" == "metadata" ]]; then
            rm -rf "${TEST_CAPTURE_DIR}/metadata"
            cp -R "${arg}" "${TEST_CAPTURE_DIR}/metadata"
          fi
          if [[ -d "${arg}" && "$(basename "${arg}")" == "hook-output" ]]; then
            rm -rf "${TEST_CAPTURE_DIR}/hook-output"
            cp -R "${arg}" "${TEST_CAPTURE_DIR}/hook-output"
          fi
          ;;
      esac
    done

    printf 'snapshot TESTSNAP01 saved\n'
    ;;
  forget)
    ;;
  restore)
    target=""
    include_path=""
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        --target)
          target="${args[$((i + 1))]}"
          ;;
        --include)
          include_path="${args[$((i + 1))]}"
          ;;
      esac
    done

    [[ -n "${target}" ]] || exit 1
    [[ -n "${TEST_RESTIC_RESTORE_SOURCE:-}" ]] || exit 1

    mkdir -p "${target}"
    cp -R "${TEST_RESTIC_RESTORE_SOURCE}/." "${target}/"
    if [[ -n "${include_path}" ]]; then
      printf '%s\n' "${include_path}" > "${TEST_CAPTURE_DIR}/restic-restore-include.txt"
    fi
    ;;
  snapshots)
    printf 'ID        Time                 Host          Tags        Paths\n'
    printf 'TESTSNAP  2026-05-25 00:00:00  fake-host     minecraft   /fake\n'
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${TEST_ROOT}/bin/restic"

  export PATH="${TEST_ROOT}/bin:${PATH}"
  export DOCKER_BIN="docker"
  export RESTIC_BIN="restic"
  export RESTIC_REPOSITORY="${TEST_ROOT}/fake-restic-repo"
  export RESTIC_PASSWORD="test-password"
  export LOG_DIR="${TEST_ROOT}/logs"
  export RUNTIME_DIR="${TEST_ROOT}/runtime"
  export STAGING_DIR="${TEST_ROOT}/staging"
  export SNAPSHOT_SLEEP_SECONDS="0"
}

setup_fake_stack() {
  local stack_root="$1"

  mkdir -p \
    "${stack_root}/scripts" \
    "${stack_root}/ops/access" \
    "${stack_root}/backups/daily" \
    "${stack_root}/data/proxy" \
    "${stack_root}/data/lobby/world/playerdata" \
    "${stack_root}/data/lobby/world/stats" \
    "${stack_root}/data/lobby/world/advancements" \
    "${stack_root}/data/survival/world/playerdata" \
    "${stack_root}/data/survival/world/stats" \
    "${stack_root}/data/survival/world/advancements" \
    "${stack_root}/data/survival/world/region" \
    "${stack_root}/data/creative/world/playerdata" \
    "${stack_root}/data/creative/world/stats" \
    "${stack_root}/data/creative/world/advancements" \
    "${stack_root}/plugin-persistence"

  printf 'proxy-config\n' > "${stack_root}/data/proxy/velocity.toml"
  printf 'lobby-data\n' > "${stack_root}/data/lobby/world/playerdata/lobby-player.dat"
  printf '{"stat":1}\n' > "${stack_root}/data/lobby/world/stats/lobby-player.json"
  printf '{"advancement":1}\n' > "${stack_root}/data/lobby/world/advancements/lobby-player.json"
  printf 'live-inventory\n' > "${stack_root}/data/survival/world/playerdata/player1.dat"
  printf '{"stat":2}\n' > "${stack_root}/data/survival/world/stats/player1.json"
  printf '{"advancement":2}\n' > "${stack_root}/data/survival/world/advancements/player1.json"
  printf 'live-world\n' > "${stack_root}/data/survival/world/region/r.0.0.mca"
  printf 'creative-data\n' > "${stack_root}/data/creative/world/playerdata/creative-player.dat"
  printf '{"stat":3}\n' > "${stack_root}/data/creative/world/stats/creative-player.json"
  printf '{"advancement":3}\n' > "${stack_root}/data/creative/world/advancements/creative-player.json"
  printf 'sql-dump\n' > "${stack_root}/plugin-persistence/luckperms.sql"
  printf 'Alex\n' > "${stack_root}/ops/access/invite-players.txt"

  cat > "${stack_root}/scripts/export-admin-target-env.sh" <<EOF
#!/usr/bin/env bash
cat <<'INNER'
TARGET_STACK_ROOT=${stack_root}
TARGET_COMPOSE_PROJECT_DIR=${stack_root}
TARGET_COMPOSE_FILE=${stack_root}/compose.yaml
TARGET_DATA_DIR=${stack_root}/data
TARGET_BACKUPS_DIR=${stack_root}/backups
TARGET_ACCESS_DIR=${stack_root}/ops/access
TARGET_INVITE_PLAYERS_FILE=${stack_root}/ops/access/invite-players.txt
TARGET_BACKUP_SCRIPT=${stack_root}/scripts/backup-worlds.sh
TARGET_PROXY_CONTAINER=mc-proxy
TARGET_LOBBY_CONTAINER=mc-lobby
TARGET_SURVIVAL_CONTAINER=mc-survival
TARGET_CREATIVE_CONTAINER=mc-creative
INNER
EOF
  chmod +x "${stack_root}/scripts/export-admin-target-env.sh"

  cat > "${stack_root}/scripts/backup-worlds.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="testbackup"
ARCHIVE_PATH="${ROOT_DIR}/backups/daily/minecraft-${TIMESTAMP}.tar.gz"

mkdir -p "${ROOT_DIR}/backups/daily"
tar -czf "${ARCHIVE_PATH}" -C "${ROOT_DIR}" data
printf '%s\n' "${ARCHIVE_PATH}" >> "${ROOT_DIR}/backup-invocations.log"
EOF
  chmod +x "${stack_root}/scripts/backup-worlds.sh"

  export TARGET_STACK_ROOT="${stack_root}"
  export TARGET_ENV_COMMAND="${stack_root}/scripts/export-admin-target-env.sh"
}

assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"

  grep -F "${expected_text}" "${file_path}" >/dev/null
}

run_test() {
  local test_name="$1"
  shift

  if "$@"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS %s\n' "${test_name}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "${test_name}"
  fi
}

test_offsite_backup_includes_extra_paths_fixture() {
  local stack_root

  setup_test_root
  stack_root="${TEST_ROOT}/stack"
  setup_fake_stack "${stack_root}"

  cp "${FIXTURE_DIR}/extra-paths.fixture" "${REPO_ROOT}/config/extra-paths.txt"

  bash "${REPO_ROOT}/scripts/offsite-backup.sh"

  assert_file_contains "${TEST_CAPTURE_DIR}/restic-sources.txt" "${stack_root}/plugin-persistence"
}

test_offsite_backup_runs_hook_fixture() {
  local stack_root

  setup_test_root
  stack_root="${TEST_ROOT}/stack"
  setup_fake_stack "${stack_root}"

  cp "${ORIGINAL_EXTRA_PATHS_FILE}" "${REPO_ROOT}/config/extra-paths.txt"
  cp "${FIXTURE_DIR}/pre-backup-hook.fixture.sh" "${REPO_ROOT}/hooks/pre-backup.d/test-fixture-hook.sh"
  chmod +x "${REPO_ROOT}/hooks/pre-backup.d/test-fixture-hook.sh"

  bash "${REPO_ROOT}/scripts/offsite-backup.sh"

  [[ -f "${TEST_CAPTURE_DIR}/hook-output/luckperms-dump.sql" ]]
}

test_restore_to_staging_from_local_archive() {
  local stack_root archive_path staged_restore

  setup_test_root
  stack_root="${TEST_ROOT}/stack"
  setup_fake_stack "${stack_root}"

  bash "${stack_root}/scripts/backup-worlds.sh"
  archive_path="${stack_root}/backups/daily/minecraft-testbackup.tar.gz"

  staged_restore="$(bash "${REPO_ROOT}/scripts/restore-to-staging.sh" "${archive_path}" survival | tail -n1)"
  [[ -f "${staged_restore}/data/survival/world/playerdata/player1.dat" ]]
}

test_promote_rollback_preserves_playerdata_by_default() {
  local stack_root stage_dir

  setup_test_root
  stack_root="${TEST_ROOT}/stack"
  setup_fake_stack "${stack_root}"

  stage_dir="${TEST_ROOT}/manual-stage"
  mkdir -p "${stage_dir}/data/survival/world/playerdata" "${stage_dir}/data/survival/world/stats" "${stage_dir}/data/survival/world/advancements" "${stage_dir}/data/survival/world/region"
  printf 'old-inventory\n' > "${stage_dir}/data/survival/world/playerdata/player1.dat"
  printf '{"stat":999}\n' > "${stage_dir}/data/survival/world/stats/player1.json"
  printf '{"advancement":999}\n' > "${stage_dir}/data/survival/world/advancements/player1.json"
  printf 'rolled-back-world\n' > "${stage_dir}/data/survival/world/region/r.0.0.mca"

  bash "${REPO_ROOT}/scripts/promote-rollback.sh" "${stage_dir}" survival

  assert_file_contains "${stack_root}/data/survival/world/playerdata/player1.dat" "live-inventory"
  assert_file_contains "${stack_root}/data/survival/world/region/r.0.0.mca" "rolled-back-world"
}

test_promote_rollback_allows_playerdata_rollback_when_requested() {
  local stack_root stage_dir

  setup_test_root
  stack_root="${TEST_ROOT}/stack"
  setup_fake_stack "${stack_root}"

  stage_dir="${TEST_ROOT}/manual-stage"
  mkdir -p "${stage_dir}/data/survival/world/playerdata" "${stage_dir}/data/survival/world/stats" "${stage_dir}/data/survival/world/advancements" "${stage_dir}/data/survival/world/region"
  printf 'old-inventory\n' > "${stage_dir}/data/survival/world/playerdata/player1.dat"
  printf '{"stat":999}\n' > "${stage_dir}/data/survival/world/stats/player1.json"
  printf '{"advancement":999}\n' > "${stage_dir}/data/survival/world/advancements/player1.json"
  printf 'rolled-back-world\n' > "${stage_dir}/data/survival/world/region/r.0.0.mca"

  bash "${REPO_ROOT}/scripts/promote-rollback.sh" "${stage_dir}" survival --allow-playerdata-rollback

  assert_file_contains "${stack_root}/data/survival/world/playerdata/player1.dat" "old-inventory"
}

run_test "offsite backup includes extra paths fixture" test_offsite_backup_includes_extra_paths_fixture
run_test "offsite backup runs hook fixture" test_offsite_backup_runs_hook_fixture
run_test "restore to staging from local archive" test_restore_to_staging_from_local_archive
run_test "promote rollback preserves playerdata by default" test_promote_rollback_preserves_playerdata_by_default
run_test "promote rollback allows playerdata rollback" test_promote_rollback_allows_playerdata_rollback_when_requested

printf '\nPassed: %s\nFailed: %s\n' "${PASS_COUNT}" "${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  exit 1
fi
