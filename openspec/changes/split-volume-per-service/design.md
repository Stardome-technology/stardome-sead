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

Files are owned `10001:10001` on the host, the image user that `scripts/image-user.env` declares
and every service runs as since the move to the v0.1.0 user.

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

### D7 — The update runbook verifies the working tree before pulling

**Re-verified 2026-11-17; the original premise of this decision was stale.** Both edges are at
`dcd5fa3` and `git status` shows `M compose.yaml` / `M compose.production.yaml`, which looks like
the hardening PR applied by hand. It is not: `git diff origin/main -- compose.yaml
compose.production.yaml` is **empty**. The local content is byte-identical to `origin/main`
because the hardening PR landed as #39 (`e9c1e15`). The dirty flag is a stale index entry, not
unmerged work.

So the runbook's first step is a **verification**, not a reconciliation:

```bash
git diff --quiet origin/main -- compose.yaml compose.production.yaml \
  && git checkout -- compose.yaml compose.production.yaml \
  || echo "STOP: local compose differs from origin/main — inspect before pulling"
```

If the diff is empty, the checkout clears the flag with no content change and the pull is clean.
If it is not empty, the operator stops and looks — which is the case the original decision was
written for, and it still applies if anyone ever hand-edits the compose files again.

Rationale: the original text told the operator to reconcile or discard local changes. On the
actual nodes there is nothing to reconcile, and telling someone to `git stash` work that does not
exist invites them to discard something else. Verify first, then act on what is actually there.

**Two related facts the runbook must state, both verified on both edges:**

- **The key files already exist.** `~/stardome-sead/keys/` holds `edge_sign.hex`, `org_sign.hex`,
  `org_pub.hex` at mode `0400`, owned `10001:10001`, and `.env` already points the
  three `EDGE_*_FILE` variables at them. The #37 secrets prerequisite is satisfied; the runbook
  verifies it rather than creating it.
- **`?? keys/` is expected and must not be cleaned.** `keys/` is gitignored on `origin/main` but
  the entry arrived after `dcd5fa3`, so the current checkout shows the directory as untracked.
  After the pull it becomes ignored. Deleting it destroys the edge signing key.

### D8 — The orphan `stardome-sead_pin_data` volume is documented, not removed

The migration does **not** remove the orphan volume; it is documented as unused. Rationale:

1. The migration's safety property is "leave old files recoverable-but-poisoned rather than
   deleted" (D2). A script that auto-deletes a volume contradicts that principle, even for a
   0-byte volume.
2. The volume holds only a 0-byte `pin-service.db` (Context fact 2) — worthless to preserve, but
   not worth a destructive step in a script whose whole design is non-destructive.
3. Removal is a one-line manual operator cleanup (`docker volume rm stardome-sead_pin_data`
   after the migration is verified); baking it into the migration adds risk for no benefit.
4. The real hazard is someone "restoring" from the 0-byte database — that is fixed by
   documentation, not deletion.

## Risks / Trade-offs

- **The migration touches the only copy of the key index.** Mitigation: D2 (rename, not delete), D3
  (checkpoint), D4 (verify before success), and a `--dry-run`.
- **`external: true` requires a manual `docker volume create` on fresh nodes.** That is the point (D1),
  but it must be in the install docs, or a first-time deployment fails confusingly.
- **Per-service volumes multiply the things to back up.** Mitigated by D5's explicit list and one
  script.
- **The orphan `pin_data` volume.** Decided: documented as unused, not removed by the migration
  (D8). Leaving it undocumented invites someone to "restore" from a 0-byte database — the
  documentation in D8 and the Migration section is the mitigation.

## Migration

1. Verify the working tree (D7) — `git diff --quiet origin/main -- compose.yaml compose.production.yaml`
   must be empty; clear the stale flag with `git checkout --`.
2. Confirm the three key files exist and are readable by 10001:10001 (D7).
3. `git pull`.
4. Stop the stack.
5. `docker volume create` the new per-service volumes (including the external `edge.db` one).
5. Run the migration script (`--dry-run` first).
6. `up -d`.
7. Verify: row counts per table match, `PRAGMA integrity_check` is `ok`, edge-service is healthy and
   its next signature uses an index greater than the last one before the migration.
8. Runbook note (D8): state that `stardome-sead_pin_data` is a stale orphan containing a 0-byte
   `pin-service.db`, must never be used as a restore source, and may be removed manually
   (`docker volume rm stardome-sead_pin_data`) after the migration is verified.

## Open Questions

- Does the backup need to run on a schedule (cron/systemd timer), or is manual invocation enough for
  now? There is no scheduler on the edges today. Recorded as a follow-up in
  `docs/backup-runbook.md` ("Follow-up: backup scheduling") — still an open decision, not resolved.
