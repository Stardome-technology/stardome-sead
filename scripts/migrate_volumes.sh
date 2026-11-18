#!/usr/bin/env bash
# Migrates the shared `stardome-sead_sead_data` volume to the per-service
# volumes declared in compose.yaml (sead_core_data, edge_data, pin_data,
# sourcedata_data).
#
# Usage: scripts/migrate_volumes.sh [--dry-run]
#
#   --dry-run   print the migration plan and run all pre-flight checks,
#               without modifying anything.
#   -h, --help  show usage and exit.
#
# Design (openspec/changes/split-volume-per-service/design.md):
#   D2  the migration RENAMES the old edge.db, never deletes it;
#   D3  checkpoint each WAL before copying, copy db + -wal + -shm together;
#   D4  idempotent, verifies before declaring success, `--dry-run` first;
#   D8  NEVER runs `docker volume rm` or any destructive volume operation.
#       The orphan `stardome-sead_pin_data` is documented as unused and is
#       NOT removed by this script (its name is also the new pin destination
#       volume's name — see design.md D8).
#
# Safety properties:
#   - Fails closed: every pre-flight problem is a hard error with a clear
#     message; any failure during the copy phase aborts BEFORE the rename,
#     leaving the source volume intact (task 2.5).
#   - This script never creates and never removes volumes. Destination
#     volumes must already exist (`docker volume create`, see the runbook).
#
# Status: tasks 2.2 (checkpoint + copy + verify) and 2.3 (rename marker) are
# implemented. The ownership-preservation step remains a marked extension
# point for task 2.4 and refuses to run rather than doing nothing silently.
set -euo pipefail

PROJECT="stardome-sead"
SRC_VOL="${PROJECT}_sead_data"
DEST_VOLS=(
  "${PROJECT}_sead_core_data"
  "${PROJECT}_edge_data"
  "${PROJECT}_pin_data"
  "${PROJECT}_sourcedata_data"
)
# Databases living in the source volume (explicit list, never a glob — D5).
DB_FILES=(sead.db edge.db pin-service.db sourcedata.db)
# Which destination volume each database migrates to (design.md D3/D4).
declare -A DEST_FOR=(
  [sead.db]="${PROJECT}_sead_core_data"
  [edge.db]="${PROJECT}_edge_data"
  [pin-service.db]="${PROJECT}_pin_data"
  [sourcedata.db]="${PROJECT}_sourcedata_data"
)
# Free-space heuristic: require at least this many times the source data size
# free on every destination filesystem (live state is ~10 MB today).
FREE_SPACE_MULTIPLIER=2

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/migrate_volumes.sh [--dry-run]

Migrate the shared stardome-sead_sead_data volume to the per-service volumes
(sead_core_data, edge_data, pin_data, sourcedata_data).

  --dry-run   run all pre-flight checks and print the plan; modify nothing.
  -h, --help  show this help and exit.

The script never creates and never removes volumes; destination volumes must
already exist (docker volume create). See the header of this file and
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
  # Tool availability (fail closed — the copy/verify phase needs both).
  command -v docker >/dev/null 2>&1 || fail "docker CLI not found; this script requires Docker"
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 CLI not found; the checkpoint/verify phase requires it"

  # (a) Stack stopped: no running containers of the compose project.
  local running
  running="$(docker ps -q --filter "label=com.docker.compose.project=${PROJECT}" || true)"
  if [ -n "$running" ]; then
    fail "stack not stopped: running ${PROJECT} containers: $(echo "$running" | tr '\n' ' ')— run 'docker compose down' first (without -v!)"
  fi
  note "pre-flight: stack is stopped"

  # (b) Source volume present.
  volume_exists "$SRC_VOL" \
    || fail "source volume '${SRC_VOL}' not found; nothing to migrate (fresh node? then no migration is needed — see the update runbook)"
  local src_mp
  src_mp="$(volume_mountpoint "$SRC_VOL")"
  [ -n "$src_mp" ] || fail "cannot resolve mountpoint of '${SRC_VOL}'"
  note "pre-flight: source volume '${SRC_VOL}' present at ${src_mp}"

  # (c) Destination volumes present. They must be created beforehand
  #     (`docker volume create ...`); this script never creates or removes
  #     volumes (D8).
  local v mp
  for v in "${DEST_VOLS[@]}"; do
    volume_exists "$v" \
      || fail "destination volume '${v}' not found; create it first: docker volume create ${v}"
  done
  note "pre-flight: all destination volumes present (${DEST_VOLS[*]})"

  # (d) Free space: every destination filesystem must have at least
  #     FREE_SPACE_MULTIPLIER x the source data size available.
  local src_kb
  src_kb="$(du -sk "$src_mp" 2>/dev/null | awk '{print $1}')"
  [ -n "$src_kb" ] || fail "cannot measure size of '${SRC_VOL}' at ${src_mp} (need root to read the Docker volume tree?)"
  local need_kb=$(( src_kb * FREE_SPACE_MULTIPLIER ))
  for v in "${DEST_VOLS[@]}"; do
    mp="$(volume_mountpoint "$v")"
    [ -n "$mp" ] || fail "cannot resolve mountpoint of '${v}'"
    local avail_kb
    avail_kb="$(df -Pk "$mp" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$avail_kb" ] || fail "cannot read free space of filesystem at ${mp}"
    if [ "$avail_kb" -lt "$need_kb" ]; then
      fail "insufficient free space on filesystem at ${mp}: ${avail_kb} KB available, need >= ${need_kb} KB (${FREE_SPACE_MULTIPLIER}x source size ${src_kb} KB)"
    fi
    note "pre-flight: free space ok on ${mp} (${avail_kb} KB >= ${need_kb} KB)"
  done
}

idempotency_check() {
  # D4: a second run must be a no-op. The rename marker (task 2.3) is the
  # primary signal; as a secondary signal, a source with no edge.db whose
  # edge destination already holds an edge.db also counts as migrated.
  local src_mp dest_edge
  src_mp="$(volume_mountpoint "$SRC_VOL")"
  dest_edge="$(volume_mountpoint "${PROJECT}_edge_data")"
  if [ -f "${src_mp}/edge.db.migrated" ]; then
    note "already migrated (found ${SRC_VOL}/edge.db.migrated); nothing to do"
    exit 0
  fi
  if [ ! -f "${src_mp}/edge.db" ] && [ -f "${dest_edge}/edge.db" ]; then
    note "already migrated (no edge.db in ${SRC_VOL}, edge destination populated); nothing to do"
    exit 0
  fi
}

print_plan() {
  note "migration plan (source ${SRC_VOL} -> per-service volumes):"
  echo "  checkpoint WAL + copy + verify (D3, implemented):"
  echo "    for each of ${DB_FILES[*]}:"
  echo "      PRAGMA wal_checkpoint(TRUNCATE) on the source db"
  echo "      copy <db>, <db>-wal, <db>-shm to its destination volume"
  echo "      PRAGMA integrity_check + per-table row counts on the copy"
  echo "  preserve ownership 100:101 on the copies (task 2.4)"
  echo "  rename ${SRC_VOL}/edge.db -> edge.db.migrated (implemented; D2: rename, never delete)"
  echo "  abort before the rename on any verification failure (task 2.5, D4)"
  echo "  never remove any volume (D8); orphan ${PROJECT}_pin_data is documented, not touched"
}

# ---------------------------------------------------------------------------
# Extension points (tasks 2.2-2.5). Each refuses to run until implemented so
# the skeleton can never half-migrate.
# ---------------------------------------------------------------------------

db_table_row_counts() {
  # Prints "table|count" lines for every user table in a database.
  local db="$1" t
  sqlite3 "$db" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" \
  | while IFS= read -r t; do
      printf '%s|%s\n' "$t" "$(sqlite3 "$db" "SELECT COUNT(*) FROM \"${t}\";")"
    done
}

checkpoint_copy_verify() {
  # Task 2.2 (D3/D4): for each database — checkpoint the WAL into the source,
  # copy db + -wal + -shm together into its destination volume, then verify
  # the copy (integrity_check + per-table row counts vs the source). Any
  # failure aborts here, BEFORE rename_migrated_marker() (task 2.5), leaving
  # the source volume intact.
  local src_mp dest_mp db ext out n src_counts dest_counts
  src_mp="$(volume_mountpoint "$SRC_VOL")"
  for db in "${DB_FILES[@]}"; do
    [ -f "${src_mp}/${db}" ] \
      || fail "database '${db}' not found in ${SRC_VOL} (${src_mp}); refusing to migrate a source that does not match the expected layout"
    dest_mp="$(volume_mountpoint "${DEST_FOR[$db]}")"
    [ -n "$dest_mp" ] || fail "cannot resolve mountpoint of '${DEST_FOR[$db]}'"
    note "migrating ${db}: ${SRC_VOL} -> ${DEST_FOR[$db]}"

    # 1. Checkpoint the WAL into the main file (D3). The stack is stopped
    #    (pre-flight), so busy must be 0; a busy reply means someone still
    #    holds the db open — do not copy under it.
    out="$(sqlite3 "${src_mp}/${db}" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1)" \
      || fail "wal_checkpoint(TRUNCATE) on ${SRC_VOL}/${db} failed: ${out}"
    if [ "${out%%|*}" != "0" ]; then
      fail "wal_checkpoint(TRUNCATE) on ${SRC_VOL}/${db} reported busy (${out}); is the stack really stopped?"
    fi

    # 2. Copy db + -wal + -shm together (D3 belt-and-braces). The checkpoint
    #    truncates -wal but it is copied anyway; -wal/-shm may be absent.
    #    Overwriting destination files is intentional: a re-run before the
    #    rename must converge, and the orphan pin_data volume holds a 0-byte
    #    pin-service.db that is meant to be replaced (D8).
    cp -f "${src_mp}/${db}" "${dest_mp}/${db}" \
      || fail "copying ${db} to ${DEST_FOR[$db]} failed"
    for ext in -wal -shm; do
      if [ -f "${src_mp}/${db}${ext}" ]; then
        cp -f "${src_mp}/${db}${ext}" "${dest_mp}/${db}${ext}" \
          || fail "copying ${db}${ext} to ${DEST_FOR[$db]} failed"
      fi
    done

    # 3. Verify the copy: integrity_check must print exactly 'ok'...
    #    (`|| true` so a non-zero sqlite3 exit lands in $out and the explicit
    #    check below reports it, instead of set -e aborting silently.)
    out="$(sqlite3 "${dest_mp}/${db}" "PRAGMA integrity_check;" 2>&1)" || true
    if [ "$out" != "ok" ]; then
      fail "integrity_check on copy ${DEST_FOR[$db]}/${db} failed: ${out}"
    fi

    # 4. ...and per-table row counts must match the source exactly.
    src_counts="$(db_table_row_counts "${src_mp}/${db}")"
    dest_counts="$(db_table_row_counts "${dest_mp}/${db}")"
    if [ "$src_counts" != "$dest_counts" ]; then
      fail "row counts differ between ${SRC_VOL}/${db} and ${DEST_FOR[$db]}/${db}:
--- source ---
${src_counts}
--- copy ---
${dest_counts}"
    fi
    n="$(printf '%s\n' "$src_counts" | grep -c . || true)"
    note "verified ${DEST_FOR[$db]}/${db}: integrity ok, ${n} table(s) row counts match"
  done
}

preserve_ownership() {
  # TASK 2.4 extension point: chown 100:101 (syslog:syslog) on all copied
  # files, matching the production `user: "100:101"`.
  fail "ownership preservation (task 2.4) is not implemented yet"
}

rename_migrated_marker() {
  # Task 2.3 (D2): rename ${SRC_VOL}/edge.db -> edge.db.migrated. Reaching
  # this function means checkpoint_copy_verify (and preserve_ownership)
  # already succeeded for ALL databases — checkpoint_copy_verify fails closed
  # on the first bad copy, so a rename can never follow an unverified copy.
  # Rename, never delete (D2).
  local src_mp ext
  src_mp="$(volume_mountpoint "$SRC_VOL")"
  if [ ! -f "${src_mp}/edge.db" ] && [ -f "${src_mp}/edge.db.migrated" ]; then
    note "rename: edge.db already renamed (edge.db.migrated present); no-op"
    return 0
  fi
  [ -f "${src_mp}/edge.db" ] \
    || fail "cannot rename ${SRC_VOL}/edge.db: source file not found (unexpected source layout)"
  mv "${src_mp}/edge.db" "${src_mp}/edge.db.migrated" \
    || fail "renaming ${SRC_VOL}/edge.db -> edge.db.migrated failed"
  note "renamed ${SRC_VOL}/edge.db -> edge.db.migrated (D2: rename, never delete)"
  # Sidecars: the WAL was checkpointed with TRUNCATE before the copy, so
  # edge.db-wal holds no committed data and -shm is transient shared-memory
  # state. The spec names only edge.db, but a stale edge.db-wal left behind
  # would be replayed by SQLite onto any edge.db recreated in the source
  # volume later — rename them alongside (judgment call; still rename,
  # never delete).
  for ext in -wal -shm; do
    if [ -f "${src_mp}/edge.db${ext}" ]; then
      mv "${src_mp}/edge.db${ext}" "${src_mp}/edge.db${ext}.migrated" \
        || fail "renaming ${SRC_VOL}/edge.db${ext} sidecar failed"
      note "renamed ${SRC_VOL}/edge.db${ext} -> edge.db${ext}.migrated"
    fi
  done
}

main() {
  preflight
  idempotency_check

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    note "dry run: pre-flight passed; nothing was modified"
    exit 0
  fi

  # Task 2.5 extension point (fail-closed abort): the rename is the LAST
  # step; any failure from here on exits with the source untouched. The trap
  # is on EXIT, not ERR, because fail() exits explicitly and `exit` does not
  # trigger the ERR trap.
  trap 'echo "ABORT: failure before the rename; source volume left intact (task 2.5)" >&2' EXIT

  checkpoint_copy_verify   # task 2.2
  preserve_ownership       # task 2.4
  rename_migrated_marker   # task 2.3 — last destructive-ish step (rename only)

  trap - EXIT
  note "migration complete"
}

main "$@"
