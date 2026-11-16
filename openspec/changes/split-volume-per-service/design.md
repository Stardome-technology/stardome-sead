# Design: Split the Shared Volume Per Service

See `proposal.md` for the "why". Requirements live in `specs/`. This document covers how.

## Context

Live state on both lab edges (verified 2026-11-16):

```
stardome-sead_sead_data/_data/
  edge.db          4.7 MB   edge.db-wal   4.1 MB   edge.db-shm   32 KB
  sead.db          1.4 MB   sead.db-wal    58 KB
  pin-service.db     4 KB   pin-service.db-wal  2.1 MB
  sourcedata.db    (present, with -wal and -shm)
```

Files are owned `syslog:syslog` on the host (uid 100:101), matching `user: "100:101"` in the
production overlay.

Two facts that shape the design:

1. **The WAL is larger than the database.** `edge.db-wal` is 4.1 MB against a 4.7 MB `edge.db`. A copy
   that takes only `edge.db` loses committed transactions — including XMSS index advances.
2. **`stardome-sead_pin_data` is an orphan.** It exists on both edges with a 0-byte `pin-service.db`;
   the real one lives in `sead_data`. It is not declared in the current compose file.

## Goals / Non-Goals

**Goals**
- `edge.db` on a volume that no routine operation can delete.
- A migration that cannot silently produce a half-copied key index.
- A backup that cannot be restored into a key-index reuse.
- A failure mode where a missed migration stops the stack instead of starting it empty.

**Non-Goals**
- Changing any database schema or service behaviour.
- Automating the update (there is no systemd unit and no update script today; updates are manual).
- Touching `compose.relay.yaml`.

## Decisions

### D1 — `edge.db` gets its own volume, declared `external: true`

The volume is declared external so Compose will not create it. On a node that has not run the
migration, `up` fails with "external volume not found" **before** starting edge-service — which is the
desired outcome: an empty `edge.db` would make the edge sign from index 0, reusing spent leaves.

Rationale: `external: true` converts a silent, catastrophic failure (signing with reused indices) into
a loud, harmless one (the stack does not start).

### D2 — The migration renames the old `edge.db` rather than deleting it

After copying, the migration renames `sead_data/edge.db` to `sead_data/edge.db.migrated`. Rationale:
deleting it destroys the only recovery path if the copy is bad; leaving it in place means a rollback to
the old compose silently uses stale files. Renaming achieves both: the data is recoverable by hand, and
a rollback fails loudly because edge-service finds no `edge.db` at the expected path.

### D3 — The migration checkpoints the WAL before copying

`PRAGMA wal_checkpoint(TRUNCATE)` on each database before copying, then copy `db`, `-wal`, `-shm`
together. Rationale: the WAL holds committed transactions; copying only the main file loses them. A
checkpoint folds the WAL into the main file, making a single-file copy correct. Copying all three is
the belt-and-braces alternative; do both.

### D4 — The migration is idempotent and verifies before declaring success

Pre-flight: stack stopped, source volume present, destination volumes present, free space sufficient.
Post-copy: `PRAGMA integrity_check` on each copied database, and a row count per table compared against
the source. Only then does it rename the old files. Rationale: a migration that reports success on a
truncated copy is worse than one that fails.

A `--dry-run` prints the plan without touching anything, so the first run on a real node is verifiable.

### D5 — The backup excludes `edge.db` by construction, not by convention

The backup script enumerates the databases it backs up (`sead.db`, `sourcedata.db`,
`pin-service.db`) rather than globbing `*.db`. Rationale: a glob would silently include `edge.db` the
day someone adds a database, and the failure mode of restoring it is silent forgery. An explicit list
fails safe.

The script checkpoints each database before copying and runs `PRAGMA integrity_check` on the copy.

### D6 — Backup destination is a host directory, not a Docker volume

`/var/backups/sead` (configurable), outside the repo and outside Docker's volume tree. Rationale: a
Docker volume dies with `down -v` and is awkward to copy off the machine. A host directory can be
rsynced, snapshotted, or shipped to object storage.

### D7 — The update runbook starts by reconciling local compose changes

Both edges currently carry uncommitted modifications to `compose.yaml` and `compose.production.yaml`
(the hardening PR applied by hand). A `git pull` will conflict. The runbook's first step is to
reconcile or discard those local changes, then pull, then migrate with the stack stopped, then `up -d`.

Rationale: without this step the documented procedure fails at step one on the only two nodes that
exist.

## Risks / Trade-offs

- **The migration touches the only copy of the key index.** Mitigation: D2 (rename, not delete), D3
  (checkpoint), D4 (verify before success), and a `--dry-run`.
- **`external: true` requires a manual `docker volume create` on fresh nodes.** That is the point (D1),
  but it must be in the install docs, or a first-time deployment fails confusingly.
- **Per-service volumes multiply the things to back up.** Mitigated by D5's explicit list and one
  script.
- **The orphan `pin_data` volume.** Decide explicitly: remove it, or document it as unused. Leaving it
  undocumented invites someone to "restore" from a 0-byte database.

## Migration

1. Reconcile local compose changes (D7).
2. `git pull`.
3. Stop the stack.
4. `docker volume create` the new per-service volumes (including the external `edge.db` one).
5. Run the migration script (`--dry-run` first).
6. `up -d`.
7. Verify: row counts per table match, `PRAGMA integrity_check` is `ok`, edge-service is healthy and
   its next signature uses an index greater than the last one before the migration.

## Open Questions

- Should the orphan `pin_data` volume be removed by the migration, or left and documented?
- Does the backup need to run on a schedule (cron/systemd timer), or is manual invocation enough for
  now? There is no scheduler on the edges today.
