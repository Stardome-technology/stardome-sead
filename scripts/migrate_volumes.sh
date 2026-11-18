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
# Status: skeleton (task 2.1). The copy/verify, ownership-preservation and
# rename steps are marked extension points for tasks 2.2-2.5 and currently
# refuse to run rather than doing nothing silently.
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
  echo "  checkpoint WAL + copy + verify (task 2.2, D3):"
  echo "    for each of ${DB_FILES[*]}:"
  echo "      PRAGMA wal_checkpoint(TRUNCATE) on the source db"
  echo "      copy <db>, <db>-wal, <db>-shm to its destination volume"
  echo "      PRAGMA integrity_check + per-table row counts on the copy"
  echo "  preserve ownership 100:101 on the copies (task 2.4)"
  echo "  rename ${SRC_VOL}/edge.db -> edge.db.migrated (task 2.3, D2: rename, never delete)"
  echo "  abort before the rename on any verification failure (task 2.5, D4)"
  echo "  never remove any volume (D8); orphan ${PROJECT}_pin_data is documented, not touched"
}

# ---------------------------------------------------------------------------
# Extension points (tasks 2.2-2.5). Each refuses to run until implemented so
# the skeleton can never half-migrate.
# ---------------------------------------------------------------------------

checkpoint_copy_verify() {
  # TASK 2.2 extension point: for each database in ${DB_FILES[*]}:
  #   PRAGMA wal_checkpoint(TRUNCATE) on the source, copy db + -wal + -shm
  #   together into its destination volume, then PRAGMA integrity_check and
  #   per-table row counts on the copy vs the source. Any failure must abort
  #   before rename_migrated_marker() (task 2.5).
  fail "copy/verify step (task 2.2) is not implemented yet; refusing to run a real migration (--dry-run to validate pre-flight)"
}

preserve_ownership() {
  # TASK 2.4 extension point: chown 100:101 (syslog:syslog) on all copied
  # files, matching the production `user: "100:101"`.
  fail "ownership preservation (task 2.4) is not implemented yet"
}

rename_migrated_marker() {
  # TASK 2.3 extension point: rename ${SRC_VOL}/edge.db -> edge.db.migrated
  # (D2: rename, never delete). Must run ONLY after checkpoint_copy_verify
  # and preserve_ownership succeeded.
  fail "rename step (task 2.3) is not implemented yet"
}

main() {
  # Task 2.5 extension point (fail-closed abort): the rename is the LAST
  # step; any earlier failure exits here with the source untouched.
  trap 'echo "ABORT: failure before the rename; source volume left intact (task 2.5)" >&2' ERR

  preflight
  idempotency_check

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    note "dry run: pre-flight passed; nothing was modified"
    exit 0
  fi

  checkpoint_copy_verify   # task 2.2
  preserve_ownership       # task 2.4
  rename_migrated_marker   # task 2.3 — last destructive-ish step (rename only)

  trap - ERR
  note "migration complete"
}

main "$@"
