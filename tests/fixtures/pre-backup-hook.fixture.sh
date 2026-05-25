#!/usr/bin/env bash
set -euo pipefail

cat > "${BACKUP_HOOK_OUTPUT_DIR}/luckperms-dump.sql" <<'EOF'
-- fixture dump
CREATE TABLE luckperms_players (id INTEGER PRIMARY KEY);
EOF

