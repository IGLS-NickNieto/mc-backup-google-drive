# Pre-backup Hooks

Drop executable `.sh` files in this directory to generate extra backup artifacts before an offsite snapshot.

Each hook runs with these environment variables:

- `BACKUP_HOOK_OUTPUT_DIR`
- `BACKUP_METADATA_DIR`
- `TARGET_STACK_ROOT`
- `TARGET_DATA_DIR`
- `TARGET_BACKUPS_DIR`
- `TARGET_ACCESS_DIR`

Write any generated files under `BACKUP_HOOK_OUTPUT_DIR`. The offsite backup script will include that directory in the snapshot if it is not empty.

