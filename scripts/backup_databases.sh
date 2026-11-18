#!/usr/bin/env bash
# Backs up the three non-edge databases (sead.db, sourcedata.db,
# pin-service.db) to a host directory.
#
# Usage: scripts/backup_databases.sh [--dry-run]
#
#   --dry-run   run all pre-flight checks and print the backup plan,
#               without writing anything.
#   -h, --help  show usage and exit.
#
# Design (openspec/changes/split-volume-per-service/design.md):
#   D5  the backup EXCLUDES edge.db by construction: the script enumerates
#       the databases it backs up from an explicit list and NEVER globs
#       *.db, so edge.db cannot be swept in by accident and a future new
#       database is not silently included either. Restoring a stale edge.db
#       means silent XMSS leaf reuse (forgery), so inclusion is the failure
#       mode this layout is designed against.
#   D6  destination is a host directory (/var/backups/sead by default,
#       configurable), outside the repo and outside Docker's volume tree.
#
# Source of truth for each database is its per-service volume (the layout
# this change establishes):
#   sead.db         -> stardome-sead_sead_core_data
#   sourcedata.db   -> stardome-sead_sourcedata_data
#   pin-service.db  -> stardome-sead_pin_data
# A database missing from its per-service volume means the migration has
# not run on this node — the script fails closed instead of falling back to
# the old shared volume (a stale sead_data copy is not a valid backup
# source once services write to the per-service volumes). A 0-byte
# pin-service.db in pin_data is the documented orphan (D8) and is also
# refused.
#
# Status: task 3.1 (skeleton: explicit db list, CLI, pre-flight, --dry-run)
# is implemented. Tasks 3.2 (checkpoint + integrity_check on the copy),
# 3.3 (host destination directory, timestamped) and 3.4 (explicit refusal
# guard if edge.db ever enters the list) are separate upcoming tasks; their
# steps are extension points below that REFUSE to run until implemented, so
# this skeleton can never produce a half-baked backup.
set -euo pipefail

PROJECT="stardome-sead"
# D5: EXPLICIT database list — never a glob, never `ls *.db`. edge.db is
# absent from this list by construction; task 3.4 adds a guard that also
# refuses to run if a future edit ever adds it.
DB_FILES=(sead.db sourcedata.db pin-service.db)
# Which per-service volume each database lives in (compose.yaml layout).
declare -A SRC_FOR=(
  [sead.db]="${PROJECT}_sead_core_data"
  [sourcedata.db]="${PROJECT}_sourcedata_data"
  [pin-service.db]="${PROJECT}_pin_data"
)
# D6: default destination root (host directory, outside the repo and
# outside Docker's volume tree). Made configurable + timestamped in task 3.3.
BACKUP_ROOT="/var/backups/sead"

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/backup_databases.sh [--dry-run]

Back up sead.db, sourcedata.db and pin-service.db to a host directory.
edge.db is NEVER backed up (design D5: explicit list, never a glob —
restoring a stale edge key index would cause silent XMSS leaf reuse).

  --dry-run   run all pre-flight checks and print the plan; write nothing.
  -h, --help  show this help and exit.

Databases are read from their per-service volumes (sead_core_data,
sourcedata_data, pin_data). Destination: /var/backups/sead (host dir).
See the header of this file and
openspec/changes/split-volume-per-service/design.md for the safety rules.
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }
volume_mountpoint() { docker volume inspect -f '{{ .Mountpoint }}' "$1" 2>/dev/null || true; }

preflight() {
  # Tool availability (fail closed — the checkpoint/verify phase needs both).
  command -v docker >/dev/null 2>&1 || fail "docker CLI not found; this script requires Docker"
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 CLI not found; the checkpoint/verify phase requires it"

  # Every source volume must exist and every listed database must be present
  # and non-empty in its declared volume. Unlike the migration, the stack is
  # NOT required to be stopped: the backup checkpoints live databases (3.2).
  local db vol mp
  for db in "${DB_FILES[@]}"; do
    vol="${SRC_FOR[$db]}"
    volume_exists "$vol" \
      || fail "source volume '${vol}' for '${db}' not found; has the migration run on this node (scripts/migrate_volumes.sh)?"
    mp="$(volume_mountpoint "$vol")"
    [ -n "$mp" ] || fail "cannot resolve mountpoint of '${vol}'"
    if [ ! -f "${mp}/${db}" ]; then
      fail "database '${db}' not found in '${vol}' (${mp}); the migration has not populated this volume — refusing to back up an incomplete layout"
    fi
    if [ ! -s "${mp}/${db}" ]; then
      fail "database '${db}' in '${vol}' is 0 bytes; this is the documented orphan/stale state (design D8), not a valid backup source — run the migration first"
    fi
    note "pre-flight: '${db}' present and non-empty in '${vol}' (${mp})"
  done
}

print_plan() {
  note "backup plan (per-service volumes -> host directory ${BACKUP_ROOT}):"
  echo "  databases (explicit list, never a glob — D5): ${DB_FILES[*]}"
  echo "  edge.db is NOT in the list and is never backed up (D5)"
  echo "  per database (task 3.2, not yet implemented):"
  echo "    PRAGMA wal_checkpoint(TRUNCATE) on the source db"
  echo "    copy <db> (+ sidecars) to the destination"
  echo "    PRAGMA integrity_check on the copy"
  echo "  destination (task 3.3, not yet implemented):"
  echo "    timestamped subdirectory under ${BACKUP_ROOT} (configurable)"
  echo "  guard (task 3.4, not yet implemented):"
  echo "    refuse to run if edge.db ever appears in the database list"
}

# ---------------------------------------------------------------------------
# Extension points (tasks 3.2-3.4). Each refuses to run until implemented so
# the skeleton can never half-back-up.
# ---------------------------------------------------------------------------

guard_edge_exclusion() {
  # Task 3.4: refuse to run if edge.db (or any unexpected db) is in the
  # list. Not implemented yet — task 3.1 only guarantees edge.db is absent
  # from the list by construction.
  fail "backup step not implemented: guard_edge_exclusion arrives with task 3.4"
}

backup_databases() {
  # Task 3.2 (checkpoint + copy + integrity_check) and task 3.3 (host
  # directory, timestamped) land here. Until then this refuses so the
  # script can never write an unverified backup.
  fail "backup step not implemented: checkpoint + copy + integrity_check arrive with task 3.2, timestamped host destination with task 3.3"
}

main() {
  preflight

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    note "dry run: pre-flight passed; nothing was written"
    exit 0
  fi

  guard_edge_exclusion   # task 3.4
  backup_databases       # tasks 3.2 + 3.3
  note "backup complete"
}

main "$@"
