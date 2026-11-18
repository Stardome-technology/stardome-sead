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
# and task 3.2 (checkpoint + copy + integrity_check on the copy) are
# implemented. Tasks 3.3 (host destination directory, timestamped) and 3.4
# (explicit refusal guard if edge.db ever enters the list) are separate
# upcoming tasks; their steps are extension points below that REFUSE to run
# until implemented, so this script can never produce a half-baked backup.
#
# Task 3.2 mechanism (D5): unlike the migration, the backup runs against a
# LIVE stack, so a plain `cp` could tear mid-write. Each database is first
# checkpointed (`PRAGMA wal_checkpoint(TRUNCATE)`; a busy reply is TOLERATED
# and noted — the stack is running by design, unlike migrate_volumes.sh
# where busy is fatal), then snapshotted with the SQLite Online Backup API
# (`sqlite3 .backup`), which yields a consistent single-file snapshot even
# under concurrent writers (no -wal/-shm sidecars in the backup). The copy
# must then pass `PRAGMA integrity_check` == `ok` or the script aborts fail
# closed: non-zero exit, the unverified partial copy is removed, and the
# source is left untouched (the checkpoint only folds the WAL into the
# source db, which is a safe, intended maintenance op).
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
# Production services run as `user: "100:101"` (syslog:syslog) — same
# convention as migrate_volumes.sh task 2.4. Task 3.2 uses this ONLY to
# re-own -wal/-shm sidecars that a checkpoint may create as root (see
# backup_one_db); the backup copies themselves are plain snapshot files.
OWN_UID=100
OWN_GID=101

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
  echo "  per database (task 3.2, implemented):"
  echo "    PRAGMA wal_checkpoint(TRUNCATE) on the source db (busy tolerated — live stack)"
  echo "    consistent snapshot copy via the SQLite Online Backup API (sqlite3 .backup)"
  echo "    PRAGMA integrity_check on the copy; anything but 'ok' aborts fail closed"
  echo "  destination (task 3.3, not yet implemented):"
  echo "    timestamped subdirectory under ${BACKUP_ROOT} (configurable)"
  echo "  guard (task 3.4, not yet implemented):"
  echo "    refuse to run if edge.db ever appears in the database list"
}

# ---------------------------------------------------------------------------
# Task 3.2 (implemented): checkpoint + copy + integrity_check.
# Extension points for tasks 3.3/3.4 below still refuse to run.
# ---------------------------------------------------------------------------

guard_edge_exclusion() {
  # Task 3.4: refuse to run if edge.db (or any unexpected db) is in the
  # list. Not implemented yet — task 3.1 only guarantees edge.db is absent
  # from the list by construction.
  fail "backup step not implemented: guard_edge_exclusion arrives with task 3.4"
}

resolve_destination() {
  # Task 3.3: timestamped subdirectory under ${BACKUP_ROOT} (configurable).
  # Not implemented yet — until then the script refuses to write anything,
  # so a half-configured backup destination can never be produced.
  fail "backup step not implemented: timestamped host destination arrives with task 3.3"
}

backup_one_db() {
  # Task 3.2 (D5): for one database — checkpoint the source, take a
  # consistent snapshot into dest_dir, verify the copy with
  # PRAGMA integrity_check. Fail closed on any problem: non-zero exit,
  # partial copy removed, source untouched.
  #   $1 db        database file name (from the explicit DB_FILES list)
  #   $2 src_mp    mountpoint of the per-service volume holding the db
  #   $3 dest_dir  directory to write the snapshot into
  local db="$1" src_mp="$2" dest_dir="$3"
  local src="${src_mp}/${db}" dest="${dest_dir}/${db}"
  local out rc ext had_sidecar

  [ -f "$src" ] || fail "database '${db}' not found at ${src}"
  [ -s "$src" ] || fail "database '${db}' at ${src} is 0 bytes; refusing to back it up (design D8)"
  [ -d "$dest_dir" ] || fail "backup destination directory '${dest_dir}' does not exist"

  # 1. Checkpoint the WAL into the main file. The stack is LIVE by design
  #    (unlike the migration), so a busy reply is tolerated and noted — the
  #    snapshot in step 2 is consistent regardless. A hard sqlite3 error is
  #    NOT tolerated: it means the source db is broken -> fail closed.
  #    Note which sidecars exist first: if the checkpoint (run as root)
  #    creates -wal/-shm that were absent, they would be root-owned and the
  #    100:101 services could not use them afterwards.
  had_sidecar=("$([ -e "${src}-wal" ] && echo wal || true)" "$([ -e "${src}-shm" ] && echo shm || true)")
  rc=0
  out="$(sqlite3 "$src" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "wal_checkpoint(TRUNCATE) on '${db}' (${src}) failed: ${out}"
  elif [ "${out%%|*}" != "0" ]; then
    note "checkpoint: '${db}' WAL busy (${out}); tolerated — the snapshot below is consistent under concurrent writers"
  fi
  if [ "$(id -u)" -eq 0 ]; then
    # Re-own sidecars this checkpoint created (only possible as root, and
    # only a hazard when running as root against the production layout).
    # had_sidecar[0] tracks -wal, had_sidecar[1] tracks -shm — index by
    # position so a missing -wal cannot shift -shm into the wrong slot.
    local i
    for i in 0 1; do
      case "$i" in 0) ext="-wal" ;; 1) ext="-shm" ;; esac
      [ -e "${src}${ext}" ] || continue
      case "${had_sidecar[$i]}" in
        wal|shm) ;;  # existed before the checkpoint — ownership unchanged
        *) chown "${OWN_UID}:${OWN_GID}" "${src}${ext}" \
             || fail "chown ${OWN_UID}:${OWN_GID} on checkpoint-created ${src}${ext} failed"
           note "re-owned checkpoint-created '${db}${ext}' to ${OWN_UID}:${OWN_GID}" ;;
      esac
    done
  fi

  # 2. Consistent snapshot via the SQLite Online Backup API. Unlike `cp`,
  #    this is safe against concurrent writers (the whole point of running
  #    backups on a live stack) and produces a single self-contained file —
  #    no -wal/-shm sidecars to keep in sync in the backup set.
  #    Overwriting an existing snapshot is intentional: re-runs converge.
  rc=0
  out="$(sqlite3 "$src" ".backup ${dest}" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$dest"
    fail "snapshot copy of '${db}' to '${dest}' failed: ${out}"
  fi
  if [ ! -s "$dest" ]; then
    rm -f "$dest"
    fail "snapshot copy '${dest}' is missing or 0 bytes; aborting (no unverified backup left behind)"
  fi

  # 3. Verify the copy: integrity_check must print exactly 'ok'.
  #    (`|| true` so a non-zero sqlite3 exit lands in $out and the explicit
  #    check below reports it, instead of set -e aborting silently.)
  out="$(sqlite3 "$dest" "PRAGMA integrity_check;" 2>&1)" || true
  if [ "$out" != "ok" ]; then
    rm -f "$dest"
    fail "integrity_check on backup copy '${dest}' failed: ${out} (source untouched; unverified copy removed)"
  fi
  note "verified backup copy of '${db}': integrity_check ok (${dest})"
}

backup_databases() {
  # Task 3.2 loop over the explicit list. The destination itself is a task
  # 3.3 extension point and refuses until implemented.
  local dest db src_mp
  dest="$(resolve_destination)"   # task 3.3 — refuses until implemented
  for db in "${DB_FILES[@]}"; do
    src_mp="$(volume_mountpoint "${SRC_FOR[$db]}")"
    [ -n "$src_mp" ] || fail "cannot resolve mountpoint of '${SRC_FOR[$db]}'"
    note "backing up '${db}': ${SRC_FOR[$db]} -> ${dest}"
    backup_one_db "$db" "$src_mp" "$dest"
  done
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

# Run main only when executed, not when sourced — lets the test harness
# source the script and drive backup_one_db directly (task 3.2 verification).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
