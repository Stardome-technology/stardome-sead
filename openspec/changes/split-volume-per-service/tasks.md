# Tasks: Per-Service Volumes, Migration and Backup

Specs: `per-service-volumes`. Design: `design.md`.

## 1. Compose — per-service volumes

- [ ] 1.1 Give each service its own volume in `compose.yaml`: `sead_core_data`, `edge_data`,
  `pin_data`, `sourcedata_data`, each mounted at `/data`.
- [ ] 1.2 Declare `edge_data` as `external: true` with a fixed `name:`, so Compose never creates or
  removes it.
- [ ] 1.3 Declare the other three as normal named volumes.
- [ ] 1.4 Update the hardening comment in `compose.production.yaml` that refers to `sead_data`, and
  the header comment in `compose.yaml` about the volume holding the XMSS indices.
- [ ] 1.5 Decide the orphan `stardome-sead_pin_data` volume: remove it in the migration, or document
  it as unused.

**Quality Gate:** `docker compose -f compose.yaml -f compose.production.yaml config` resolves; each
service shows a distinct volume; `edge_data` shows `external: true`; the CI compose check still passes.

## 2. Migration script

- [ ] 2.1 Write the migration script: pre-flight (stack stopped, source volume present, destination
  volumes present, free space), `--dry-run`, idempotency check.
- [ ] 2.2 For each database: `PRAGMA wal_checkpoint(TRUNCATE)`, copy `db` + `-wal` + `-shm`, then
  `PRAGMA integrity_check` on the copy and a per-table row count compared to the source.
- [ ] 2.3 After all copies verify, rename `sead_data/edge.db` to `sead_data/edge.db.migrated`.
- [ ] 2.4 Preserve ownership `100:101` on the copied files.
- [ ] 2.5 Fail closed: any verification failure aborts before the rename, leaving the source intact.

**Quality Gate:** run against a **copy** of the live volume: row counts identical per table for all
four databases, `integrity_check` `ok` on each, second run is a no-op, `--dry-run` modifies nothing,
and a deliberately truncated copy aborts before the rename.

## 3. Backup script

- [ ] 3.1 Write the backup script with an explicit database list (`sead.db`, `sourcedata.db`,
  `pin-service.db`) — never a glob, so `edge.db` cannot be included by accident.
- [ ] 3.2 Checkpoint each database before copying; run `PRAGMA integrity_check` on each copy.
- [ ] 3.3 Write to a host directory (`/var/backups/sead` by default, configurable), timestamped.
- [ ] 3.4 Refuse to run if `edge.db` would be included, as a guard against future edits.

**Quality Gate:** backup of the three databases succeeds with `integrity_check` `ok` on each; the
output contains no `edge.db`; the guard fires if `edge.db` is added to the list.

## 4. Documentation

- [ ] 4.1 README: update the volume section to the per-service layout; state that losing or restoring
  a stale `edge.db` requires an edge key rotation; warn against `docker compose down -v`.
- [ ] 4.2 New update runbook: reconcile local compose changes → pull → stop → create volumes → migrate
  (`--dry-run` first) → `up -d` → verify.
- [ ] 4.3 Document the `docker volume create` step required on fresh nodes because `edge_data` is
  external.
- [ ] 4.4 Document the backup: what it covers, what it excludes and why, where it writes.

**Quality Gate:** the runbook can be followed start to finish on a clean node and on an existing node;
no step assumes a systemd unit or an update script (there are none).

## 5. Verification on the lab edges

- [ ] 5.1 Run the migration on edge1 with `--dry-run`, review the plan, then for real.
- [ ] 5.2 Verify: row counts per table match, `integrity_check` `ok`, edge-service healthy, and the
  next signature uses an index greater than the last one before the migration.
- [ ] 5.3 Repeat on edge2.
- [ ] 5.4 Confirm `up` fails with a clear error on a node where the external volume is absent.

**Quality Gate:** both edges migrated with matching row counts and a healthy edge-service; the
missing-volume failure mode demonstrated.

## 6. Close-out

- [ ] 6.1 Record evidence: per-table row counts before/after, `integrity_check` output, the
  absent-volume error message.
- [ ] 6.2 Note the follow-up: whether backups should run on a schedule (no scheduler exists today).
